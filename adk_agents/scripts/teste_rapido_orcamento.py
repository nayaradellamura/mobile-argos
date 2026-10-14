"""Teste rapido, nao interativo, do handshake OrcamentoOficinaAgent <-> app.

Mesma ideia do `teste_rapido.py` (Firestore FALSO em memoria, sem precisar
de emulador/Java), mas exercitando especificamente o handshake novo entre
o Passo 2/3/4 do agente e a tela nativa de tabela editavel:

  1. Manda uma mensagem simulando o mecanico fechando a vistoria.
  2. Espera o agente chamar `salvar_rascunho_orcamento` e dizer a frase
     gatilho "liberei a tela de orcamento".
  3. Simula o app: grava `orcamentoItensFinais` direto no Firestore fake
     (2 itens: um dentro da faixa, um bem acima pra forcar negociacao).
  4. Manda uma mensagem de retomada e confere se o agente chama
     `carregar_orcamento_confirmado`, `verificar_faixa_preco`,
     `calcular_orcamento_total`, `salvar_estado_vistoria` e
     `enviar_laudo_cloud_function`.

Uso:
    .venv\\Scripts\\python.exe scripts\\teste_rapido_orcamento.py

ATENCAO — quota gratuita do Gemini API (AI Studio, gemini-2.5-flash):
5 requisicoes/minuto. Cada turno deste teste pode facilmente disparar
5-8+ chamadas ao modelo (cada tool call = 1 chamada, e o coordenador
ainda chama SugestorPecasAssociadas como sub-agente = mais chamadas).
Rodar os 2 turnos seguidos SEM esperar estoura a quota no meio do
Passo 2/3 (erro 429 RESOURCE_EXHAUSTED) e o teste fica incompleto — nao
e um bug de codigo, e limite de infra do tier gratuito. Se isso
acontecer, espere ~60s entre execucoes ou troque pra uma API key paga /
Vertex AI antes de rodar de novo.
"""

from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

ID_VISTORIA = "VIS-SIMULACAO-ORCAMENTO-0001"
ID_SINISTRO = "SIN-SIMULACAO-ORCAMENTO-0001"

STORE: dict[tuple[str, str], dict] = {
    ("sinistro", ID_SINISTRO): {
        "placa": "ABC1D23",
        "vehicle": "Fiat Argo 2022",
        "priority": "media",
        "claimType": "colisao",
        "credenciadoId": "credenciado-simulacao",
    },
    ("vistorias", ID_VISTORIA): {
        "idvistoria": ID_VISTORIA,
        "sinistroId": ID_SINISTRO,
        "status": "EM_ANDAMENTO",
        "tipoVistoria": "ORIGINAL",
        "placa": "ABC1D23",
        "veiculo": "Fiat Argo 2022",
        "cliente": "Cliente de Teste",
        "credenciado": "Oficina de Simulacao",
        "descricaoArtigos": "Colisao frontal em poste, baixa velocidade.",
        "observacoes": "",
        "images": [],
        "agentParameters": {
            "danos_externos": ["para-choque dianteiro", "farol dianteiro direito"],
            "ponto_impacto": "frontal",
            "severidade_geral": "moderada",
            "modelo_veiculo": "Fiat Argo 2022",
        },
    },
}


def _instalar_firestore_fake() -> None:
    """Fake Firestore com suporte a subcolecoes (path arbitrario), porque
    `consultar_preco_referencia` usa `tabelaPrecos/{modelo}/pecas/{peca}`
    (2 niveis) — um dublê de 1 nivel só (como o antigo `teste_rapido.py`
    usava) quebra com `AttributeError: no attribute 'collection'`.
    """
    from google.cloud import firestore

    class _FakeDocRef:
        def __init__(self, path: tuple[str, ...]) -> None:
            self._path = path

        def get(self) -> "_FakeDocRef":
            return self

        @property
        def exists(self) -> bool:
            return self._path in STORE

        def to_dict(self) -> dict:
            return dict(STORE.get(self._path, {}))

        def set(self, data: dict, merge: bool = False) -> None:
            if merge and self._path in STORE:
                STORE[self._path].update(data)
            else:
                STORE[self._path] = dict(data)
            print(f"    [fake-firestore] set({self._path}, merge={merge}) -> {data}")

        def collection(self, name: str) -> "_FakeCollection":
            return _FakeCollection(self._path + (name,))

    class _FakeCollection:
        def __init__(self, path: tuple[str, ...]) -> None:
            self._path = path

        def document(self, doc_id: str) -> _FakeDocRef:
            return _FakeDocRef(self._path + (doc_id,))

    class FakeFirestoreClient:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def collection(self, name: str) -> _FakeCollection:
            return _FakeCollection((name,))

    firestore.Client = FakeFirestoreClient  # type: ignore[assignment]
    print("[teste] usando Firestore FALSO em memoria (com suporte a subcolecoes).\n")


async def _rodar_turno(
    runner, session_id: str, texto: str, max_tentativas: int = 4
) -> list[str]:
    """Roda um turno, com retry simples pra quota do tier gratuito (5
    req/min). Seguro reexecutar o turno inteiro do zero: as tools
    chamadas aqui (carregar_contexto_vistoria, consultar_preco_referencia,
    salvar_rascunho_orcamento, carregar_orcamento_confirmado,
    verificar_faixa_preco, calcular_orcamento_total) são todas idempotentes
    ou só leitura.
    """
    import asyncio

    from google.genai import types

    for tentativa in range(1, max_tentativas + 1):
        print(f"\n[teste] enviando (tentativa {tentativa}): {texto!r}")
        content = types.Content(role="user", parts=[types.Part(text=texto)])
        tools_chamadas: list[str] = []

        try:
            async for event in runner.run_async(
                user_id="mecanico_teste",
                session_id=session_id,
                new_message=content,
            ):
                author = getattr(event, "author", "?")
                if not (event.content and event.content.parts):
                    continue
                for part in event.content.parts:
                    if getattr(part, "text", None):
                        print(f"  [{author}] disse: {part.text}")
                    if getattr(part, "function_call", None):
                        fc = part.function_call
                        tools_chamadas.append(fc.name)
                        print(f"  [{author}] chamou tool: {fc.name}({dict(fc.args or {})})")
                    if getattr(part, "function_response", None):
                        fr = part.function_response
                        print(f"  [{author}] tool respondeu: {fr.name} -> {fr.response}")
            return tools_chamadas
        except Exception as e:
            mensagem = str(e)
            eh_quota = "RESOURCE_EXHAUSTED" in mensagem or "429" in mensagem or "UNAVAILABLE" in mensagem
            if not eh_quota or tentativa == max_tentativas:
                raise
            espera = 40
            print(f"  [teste] rate limit/indisponibilidade (tentativa {tentativa}); esperando {espera}s e tentando de novo...")
            await asyncio.sleep(espera)

    return []


async def main() -> None:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        _instalar_firestore_fake()

    if not os.environ.get("GOOGLE_API_KEY"):
        env_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"
        )
        if os.path.exists(env_path):
            for line in open(env_path, encoding="utf-8"):
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip())

    if not os.environ.get("GOOGLE_API_KEY"):
        print("BLOQUEADO: GOOGLE_API_KEY nao encontrada (nem em env, nem em .env).", file=sys.stderr)
        sys.exit(1)

    os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "FALSE")
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "demo-argos")

    from google.adk.runners import InMemoryRunner

    from orcamento_team.agent import root_agent

    runner = InMemoryRunner(agent=root_agent, app_name="argos_teste_orcamento")
    session = await runner.session_service.create_session(
        app_name="argos_teste_orcamento",
        user_id="mecanico_teste",
        state={"id_vistoria": ID_VISTORIA},
    )

    print("=== TURNO 1: mecanico fecha a vistoria ===")
    tools_1 = await _rodar_turno(
        runner,
        session.id,
        f"Fechei a vistoria {ID_VISTORIA}, pode seguir pro orcamento.",
    )

    rascunho_salvo = "salvar_rascunho_orcamento" in tools_1
    print(f"\n[checagem] salvar_rascunho_orcamento chamado no turno 1: {rascunho_salvo}")

    vistoria_atual = STORE.get(("vistorias", ID_VISTORIA), {})
    print(f"[checagem] orcamentoRascunho gravado: {vistoria_atual.get('orcamentoRascunho')}")

    print("\n=== Simulando o app: gravando orcamentoItensFinais ===")
    STORE[("vistorias", ID_VISTORIA)]["orcamentoItensFinais"] = [
        {
            "peca": "para-choque dianteiro",
            "tipoIntervencao": "substituicao",
            "valorPeca": 460.0,
            "horasMaoObra": 3.0,
        },
        {
            "peca": "farol dianteiro direito",
            "tipoIntervencao": "substituicao",
            "valorPeca": 900.0,
            "horasMaoObra": 1.0,
        },
    ]
    print(f"  -> orcamentoItensFinais = {STORE[('vistorias', ID_VISTORIA)]['orcamentoItensFinais']}")

    print("\n=== TURNO 2: retomada apos envio da tabela ===")
    tools_2 = await _rodar_turno(runner, session.id, "enviei o orcamento")

    checagens = {
        "carregar_orcamento_confirmado": "carregar_orcamento_confirmado" in tools_2,
        "verificar_faixa_preco": "verificar_faixa_preco" in tools_2,
        "calcular_orcamento_total": "calcular_orcamento_total" in tools_2,
        "salvar_estado_vistoria": "salvar_estado_vistoria" in tools_2,
        "enviar_laudo_cloud_function": "enviar_laudo_cloud_function" in tools_2,
    }

    print("\n=== RESUMO ===")
    print(f"salvar_rascunho_orcamento (turno 1): {rascunho_salvo}")
    for nome, ok in checagens.items():
        print(f"{nome} (turno 2): {ok}")

    if rascunho_salvo and all(checagens.values()):
        print("\n[teste] PASSOU: handshake completo executado na ordem esperada.")
    else:
        print("\n[teste] INCOMPLETO: alguma tool esperada nao foi chamada neste turno.")


if __name__ == "__main__":
    asyncio.run(main())

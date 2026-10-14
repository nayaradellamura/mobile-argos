"""Teste rapido, nao interativo, do VistoriaPeritoDigitalAgent.

Envia uma unica mensagem simulando o relato de um mecanico e imprime a
resposta do agente + os eventos de chamada de tool, sem precisar do
`adk web` (util para validar a instalacao/config antes de testar via
navegador).

Se a maquina nao tiver Java 21+ (exigido pelo emulador real do
Firestore, ver `simular_local.ps1`), este script cai automaticamente
para um cliente Firestore FALSO em memoria (`--fake-firestore`, default
quando FIRESTORE_EMULATOR_HOST nao esta setado) - serve so pra validar a
conversa/instrucao do agente, nao a integracao real com Firestore.

Uso:
    .venv\\Scripts\\python.exe scripts\\teste_rapido.py
"""

from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

ID_VISTORIA = "VIS-SIMULACAO-0001"
ID_SINISTRO = "SIN-SIMULACAO-0001"
MENSAGEM_TESTE = (
    "Oi, bati a dianteira do carro num poste. O hodometro ta em 42500km. "
    "Bati de frente mesmo, bem na altura do para-choque."
)


def _usar_firestore_fake() -> bool:
    return not os.environ.get("FIRESTORE_EMULATOR_HOST")


def _instalar_firestore_fake() -> None:
    """Substitui google.cloud.firestore.Client por um dublê em memória,
    só para esta execução — nenhum arquivo de produção é alterado.
    """
    from google.cloud import firestore

    store: dict[tuple[str, str], dict] = {
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
            "descricaoArtigos": "",
            "observacoes": "",
            "images": [],
            "agentParameters": {},
        },
    }

    class _FakeDocRef:
        def __init__(self, key: tuple[str, str]) -> None:
            self._key = key

        def get(self) -> "_FakeDocRef":
            return self

        @property
        def exists(self) -> bool:
            return self._key in store

        def to_dict(self) -> dict:
            return dict(store.get(self._key, {}))

        def set(self, data: dict, merge: bool = False) -> None:
            if merge and self._key in store:
                store[self._key].update(data)
            else:
                store[self._key] = dict(data)
            print(f"    [fake-firestore] set({self._key}, merge={merge}) -> {data}")

    class _FakeCollection:
        def __init__(self, name: str) -> None:
            self._name = name

        def document(self, doc_id: str) -> _FakeDocRef:
            return _FakeDocRef((self._name, doc_id))

    class FakeFirestoreClient:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def collection(self, name: str) -> _FakeCollection:
            return _FakeCollection(name)

    firestore.Client = FakeFirestoreClient  # type: ignore[assignment]
    print("[teste] usando Firestore FALSO em memoria (sem emulador/Java 21 disponivel).\n")


async def main() -> None:
    if _usar_firestore_fake():
        _instalar_firestore_fake()

    from google.adk.runners import InMemoryRunner
    from google.genai import types

    from vistoria_team.agent import root_agent

    runner = InMemoryRunner(agent=root_agent, app_name="argos_teste")

    session = await runner.session_service.create_session(
        app_name="argos_teste",
        user_id="mecanico_teste",
    )

    print(f"[teste] enviando mensagem para {root_agent.name}...")
    print(f"[teste] mensagem: {MENSAGEM_TESTE!r}\n")

    content = types.Content(role="user", parts=[types.Part(text=MENSAGEM_TESTE)])

    async for event in runner.run_async(
        user_id="mecanico_teste",
        session_id=session.id,
        new_message=content,
    ):
        author = getattr(event, "author", "?")

        if event.content and event.content.parts:
            for part in event.content.parts:
                if getattr(part, "text", None):
                    print(f"[{author}] disse: {part.text}")
                if getattr(part, "function_call", None):
                    fc = part.function_call
                    print(f"[{author}] chamou tool: {fc.name}({dict(fc.args or {})})")
                if getattr(part, "function_response", None):
                    fr = part.function_response
                    print(f"[{author}] tool respondeu: {fr.name} -> {fr.response}")

    print("\n[teste] concluido sem excecoes.")


if __name__ == "__main__":
    asyncio.run(main())

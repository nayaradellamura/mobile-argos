"""Tools da retificação (vistoria devolvida pelo analista para ajustes).

A vistoria de retificação é um documento NOVO que o app cria a partir da
rejeitada (`vistoriaOrigemId`), só com os ajustes pedidos. Sem herdar nada,
o agente refazia a vistoria inteira e o laudo da retificação perdia as fotos,
os danos e o orçamento da primeira. Aqui:

- `carregar_contexto_retificacao` herda da original (uma vez só) o relato,
  os danos, o orçamento e as fotos — as fotos herdadas entram como já
  analisadas, para o analista de visão olhar só as novas — e devolve ao
  agente a lista de ajustes e o resumo do que já existe.
- `registrar_resposta_ajuste` guarda, por ajuste, o que foi feito. Vai para
  o laudo da retificação e para o analista.
"""

from __future__ import annotations

from google.cloud import firestore

from common.firestore_tools import _client

# Campos de agentParameters que fazem sentido continuar valendo na
# retificação. Status de passo e marcas de conclusão ficam de fora: a
# retificação tem o próprio andamento.
_CAMPOS_HERDADOS = (
    "hodometro",
    "dinamica_acidente",
    "ponto_impacto",
    "danos_externos",
    "danos_estruturais",
    "severidade_geral",
    "justificativa_severidade",
    "modelo_veiculo",
    "itens_orcamento",
    "valor_total_final",
)

_STATUS_VALIDOS = {"resolvido", "nao_aplicavel", "pendente"}


def _resumo_orcamento(agent_parameters: dict) -> dict:
    itens = agent_parameters.get("itens_orcamento") or []
    return {
        "itens": [
            {
                "peca": i.get("peca"),
                "quantidade": i.get("quantidade", 1),
                "valor_peca": i.get("valor_peca"),
                "tipo_servico": i.get("tipo_servico"),
                "horas_mao_obra": i.get("horas_mao_obra"),
                "valor_hora": i.get("valor_hora"),
            }
            for i in itens
            if isinstance(i, dict)
        ],
        "valor_total_final": agent_parameters.get("valor_total_final"),
    }


def carregar_contexto_retificacao(id_vistoria: str) -> dict:
    """Carrega a retificação e herda os dados da vistoria original.

    Chame no início da retificação, antes de falar com o mecânico. Pode ser
    chamada de novo (ao retomar a conversa): a herança só acontece uma vez.

    Args:
        id_vistoria: id da vistoria de retificação (`vistorias/{id}`).

    Returns:
        dict com `ajustes_necessarios` (texto do analista),
        `motivo_rejeicao`, `vistoria_original` (relato, danos, severidade),
        `orcamento_original` (itens e total), `fotos_herdadas`,
        `respostas_registradas` (ajustes já tratados nesta retificação) e
        `placa_veiculo`/`modelo_veiculo`.
    """
    db = _client()
    ref = db.collection("vistorias").document(id_vistoria)
    vistoria = ref.get().to_dict() or {}

    if str(vistoria.get("tipoVistoria", "")).upper() != "RETIFICACAO":
        return {"erro": "Esta vistoria não é uma retificação."}

    origem_id = str(vistoria.get("vistoriaOrigemId") or "").strip()
    original = {}
    if origem_id:
        original = db.collection("vistorias").document(origem_id).get().to_dict() or {}

    params_original = original.get("agentParameters") or {}
    params_atual = vistoria.get("agentParameters") or {}

    fotos_originais = [
        img
        for img in (original.get("images") or [])
        if isinstance(img, dict) and img.get("imageId")
    ]

    if original and not vistoria.get("retificacaoHerdada"):
        herdados = {
            campo: params_original[campo]
            for campo in _CAMPOS_HERDADOS
            if params_original.get(campo) not in (None, "", [])
            and params_atual.get(campo) in (None, "", [])
        }
        atualizacao = {
            "retificacaoHerdada": True,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        }
        if herdados:
            atualizacao["agentParameters"] = herdados
        if fotos_originais:
            atualizacao["images"] = firestore.ArrayUnion(
                [{**img, "herdadaDe": origem_id} for img in fotos_originais]
            )
            atualizacao["imagensAnalisadasIds"] = firestore.ArrayUnion(
                [img["imageId"] for img in fotos_originais]
            )
        for campo in ("orcamentoItensFinais", "orcamentoRascunho"):
            if original.get(campo) and not vistoria.get(campo):
                atualizacao[campo] = original[campo]

        ref.set(atualizacao, merge=True)
        params_atual = {**herdados, **params_atual}

    params = {**params_original, **params_atual}

    return {
        "id_vistoria": id_vistoria,
        "vistoria_origem_id": origem_id,
        "placa_veiculo": vistoria.get("placa", ""),
        "modelo_veiculo": vistoria.get("veiculo", ""),
        "ajustes_necessarios": vistoria.get("ajustesNecessarios")
        or original.get("ajustesNecessarios", ""),
        "motivo_rejeicao": original.get("motivoRejeicao", ""),
        "contexto_vistoria_anterior": vistoria.get("contextoVistoriaAnterior", ""),
        "vistoria_original": {
            "relato": params.get("dinamica_acidente") or original.get("descricaoArtigos", ""),
            "ponto_impacto": params.get("ponto_impacto"),
            "danos_externos": params.get("danos_externos"),
            "danos_estruturais": params.get("danos_estruturais"),
            "severidade_geral": params.get("severidade_geral"),
            "hodometro": params.get("hodometro"),
        },
        "orcamento_original": _resumo_orcamento(params),
        "fotos_herdadas": len(fotos_originais),
        "respostas_registradas": vistoria.get("respostasRetificacao") or {},
    }


def registrar_resposta_ajuste(
    id_vistoria: str, numero: int, ajuste: str, status: str, resposta: str
) -> dict:
    """Registra o que foi feito para um ajuste pedido pelo analista.

    Chame ao terminar cada ajuste da lista (e também quando ele não se
    aplicar). Uma chamada por ajuste; chamar de novo com o mesmo `numero`
    substitui o registro.

    Args:
        id_vistoria: id da vistoria de retificação.
        numero: posição do ajuste na lista (1, 2, 3...).
        ajuste: o ajuste pedido, em uma frase.
        status: "resolvido", "nao_aplicavel" ou "pendente".
        resposta: o que foi feito, em uma ou duas frases objetivas (ex.:
            "Enviadas 2 fotos da numeração do chassi, legíveis.").

    Returns:
        dict de confirmação.
    """
    status = str(status or "").strip().lower()
    if status not in _STATUS_VALIDOS:
        return {"erro": "status deve ser resolvido, nao_aplicavel ou pendente."}
    try:
        numero = int(numero)
    except (TypeError, ValueError):
        return {"erro": "numero deve ser um inteiro (1, 2, 3...)."}

    registro = {
        "numero": numero,
        "ajuste": str(ajuste or "").strip()[:300],
        "status": status,
        "resposta": str(resposta or "").strip()[:600],
    }

    _client().collection("vistorias").document(id_vistoria).set(
        {
            "respostasRetificacao": {str(numero): registro},
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    return {"id_vistoria": id_vistoria, "registrado": registro}

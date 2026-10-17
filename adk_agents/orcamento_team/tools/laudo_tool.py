"""Encerramento do fluxo: envia o pacote consolidado (vistoria + orçamento)
para a mesa de auditoria, equivalente ao
`${TOOL:Enviar_Laudo_CloudFunction}` do playbook original.

Para o MVP/TCC, "enviar para auditoria" é simplesmente a mudança de status
que já existe no app (`VistoriaChatSessionService.submitForOperationalAnalysis`
em Dart, status `EM_ANALISE_OPERACIONAL`) — não inventamos um novo
endpoint enquanto não houver um sistema de auditoria real para chamar.

Correção de produção: a primeira versão mudava só o status, e com isso o
chat NUNCA fechava na UI. O `watchCompletionState` do app
(`vistoria_chat_session_service.dart:35-50`) só considera a vistoria
concluída quando `status != EM_ANDAMENTO` **E** `laudo_analitico` (ou
`laudoAnalitico`) está preenchido. Sem esse campo o mecânico ficava preso
numa vistoria eternamente "em andamento". Esta versão também replica o
`_syncSinistroVistoriaStatus` por inteiro, e não só dois dos cinco campos.
"""

from __future__ import annotations

from google.cloud import firestore

_db: firestore.Client | None = None

_STATUS_EM_ANALISE = "EM_ANALISE_OPERACIONAL"
_TIPO_VISTORIA_PADRAO = "ORIGINAL"


def _client() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def enviar_laudo_cloud_function(id_vistoria: str, laudo_analitico: str) -> dict:
    """Marca a vistoria como enviada para análise operacional/auditoria.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        laudo_analitico: parágrafo curto (3-5 frases), em português técnico
            e impessoal, cobrindo dinâmica do acidente, ponto de impacto,
            peças afetadas com tipo de intervenção, severidade geral com
            justificativa, e valor total. É o que a mesa de auditoria lê —
            e é o campo que o app exige para dar a vistoria por concluída.

    Returns:
        dict de confirmação com o novo status.
    """
    laudo = str(laudo_analitico or "").strip()
    if not laudo:
        return {
            "erro": (
                "laudo_analitico está vazio. Escreva o parágrafo do laudo "
                "antes de enviar — sem ele o app não fecha a vistoria."
            )
        }

    db = _client()
    ref = db.collection("vistorias").document(id_vistoria)

    vistoria = ref.get().to_dict() or {}

    ref.set(
        {
            "status": _STATUS_EM_ANALISE,
            # `laudo_analitico` é o que `watchCompletionState` exige para dar a
            # vistoria por concluída; `laudo` é outro campo, lido pela LISTA de
            # vistorias (`linked_vistoria_info.dart:110`) para decidir entre o
            # chip "Laudo" e "Sem laudo". São dois campos distintos e ambos
            # precisam do texto, senão a vistoria fecha no chat mas aparece
            # como "Sem laudo" na listagem.
            "laudo_analitico": laudo,
            "laudo": laudo,
            "submittedAt": firestore.SERVER_TIMESTAMP,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    sinistro_id = str(vistoria.get("sinistroId") or "")

    if sinistro_id:
        # Espelha `_syncSinistroVistoriaStatus` (Dart) por completo — antes
        # só dois destes campos eram escritos, e a tela de sinistro ficava
        # com o tipo/origem da vistoria anterior.
        atualizacao = {
            "vistoriaAtualId": str(vistoria.get("idvistoria") or id_vistoria),
            "vistoriaAtualStatus": _STATUS_EM_ANALISE,
            "vistoriaAtualTipo": str(
                vistoria.get("tipoVistoria") or _TIPO_VISTORIA_PADRAO
            ),
            "ultimaVistoriaAt": firestore.SERVER_TIMESTAMP,
        }

        origem_id = str(vistoria.get("vistoriaOrigemId") or "")
        atualizacao["vistoriaAtualOrigemId"] = (
            origem_id if origem_id else firestore.DELETE_FIELD
        )

        db.collection("sinistro").document(sinistro_id).set(
            atualizacao, merge=True
        )

    return {
        "id_vistoria": id_vistoria,
        "status": _STATUS_EM_ANALISE,
        "laudo_analitico_salvo": True,
    }

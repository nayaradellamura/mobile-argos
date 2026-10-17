"""Valor da hora de mão de obra configurado pela própria oficina.

Fica em `credenciados/{id}.valoresHoraMaoObra`, um valor por tipo de
serviço — o mesmo campo que o app lê e grava no pop-up "Valor da hora" da
tabela de orçamento (`lib/services/valores_hora_service.dart`). Assim o
orçamento do chat guiado e o do envio em massa usam o mesmo valor.
"""

from __future__ import annotations

from google.cloud import firestore

from common.firestore_tools import _para_float

_db: firestore.Client | None = None

# Mesmas chaves de `kTiposServico` em lib/features/orcamento/orcamento_calculo.dart.
TIPOS_SERVICO = ("funilaria", "pintura", "mecanica", "eletrica")

_CAMPO = "valoresHoraMaoObra"


def _client() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def _credenciado_id_da_vistoria(db, id_vistoria: str) -> str:
    """A oficina dona do sinistro manda; a da vistoria é só fallback (mesma
    regra de `assertCanAccessVistoria` em functions/index.js)."""
    vistoria = db.collection("vistorias").document(id_vistoria).get().to_dict() or {}

    sinistro_id = str(vistoria.get("sinistroId") or "")
    if sinistro_id:
        sinistro = db.collection("sinistro").document(sinistro_id).get().to_dict() or {}
        credenciado_id = str(sinistro.get("credenciadoId") or "")
        if credenciado_id:
            return credenciado_id

    return str(vistoria.get("credenciadoId") or "")


def carregar_valores_hora_oficina(id_vistoria: str) -> dict:
    """Lê o valor da hora de mão de obra da oficina desta vistoria, por tipo
    de serviço (funilaria, pintura, mecanica, eletrica).

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.

    Returns:
        dict com `valores` (tipo -> R$/hora, só os configurados),
        `tipos_sem_valor` (tipos ainda sem valor) e `oficina_encontrada`.
        Se `oficina_encontrada` for false, não há onde salvar valores.
    """
    db = _client()
    credenciado_id = _credenciado_id_da_vistoria(db, id_vistoria)

    if not credenciado_id:
        return {
            "oficina_encontrada": False,
            "valores": {},
            "tipos_sem_valor": list(TIPOS_SERVICO),
        }

    dados = db.collection("credenciados").document(credenciado_id).get().to_dict() or {}
    brutos = dados.get(_CAMPO) or {}

    valores = {}
    for tipo in TIPOS_SERVICO:
        valor = _para_float(brutos.get(tipo)) if isinstance(brutos, dict) else 0.0
        if valor > 0:
            valores[tipo] = valor

    return {
        "oficina_encontrada": True,
        "valores": valores,
        "tipos_sem_valor": [t for t in TIPOS_SERVICO if t not in valores],
    }


def salvar_valor_hora_oficina(id_vistoria: str, tipo_servico: str, valor_hora: float) -> dict:
    """Salva o valor da hora de um tipo de serviço no cadastro da oficina
    desta vistoria. Vale para os próximos orçamentos também (no chat e no
    app). Só chame com um valor que o mecânico informou explicitamente.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        tipo_servico: "funilaria", "pintura", "mecanica" ou "eletrica".
        valor_hora: valor em reais por hora, maior que zero.

    Returns:
        dict com `salvo` (bool) e o valor gravado, ou `erro` explicando o
        problema (tipo inválido, valor inválido, oficina não encontrada).
    """
    tipo = str(tipo_servico or "").strip().lower()
    if tipo not in TIPOS_SERVICO:
        return {
            "salvo": False,
            "erro": f"tipo_servico inválido: use um destes: {', '.join(TIPOS_SERVICO)}.",
        }

    valor = _para_float(valor_hora)
    if valor <= 0:
        return {
            "salvo": False,
            "erro": "valor_hora precisa ser maior que zero. Pergunte o valor de novo.",
        }

    db = _client()
    credenciado_id = _credenciado_id_da_vistoria(db, id_vistoria)

    if not credenciado_id:
        return {
            "salvo": False,
            "erro": "Oficina desta vistoria não encontrada; use o valor só neste orçamento.",
        }

    # Merge aninhado: só o tipo informado muda, os demais valores ficam.
    db.collection("credenciados").document(credenciado_id).set(
        {
            _CAMPO: {tipo: valor},
            "valoresHoraAtualizadoEm": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"salvo": True, "tipo_servico": tipo, "valor_hora": valor}

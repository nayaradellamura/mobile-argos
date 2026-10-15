"""Leitura de um orçamento pronto a partir de foto (atalho opcional).

Quando o mecânico já tem o orçamento montado em outro lugar (papel, PDF ou
planilha na tela do computador), ele fotografa e o Gemini transcreve os
itens. O resultado entra no mesmo fluxo da lista de referência: o agente
mostra a lista no chat, o mecânico corrige o que precisar e confirma. Nada
é enviado sem essa conferência.

Usa as fotos que o app já sobe para `vistorias/{id}.images` (o mesmo
caminho das levas da vistoria): pega só as que ainda não foram analisadas,
manda para o Gemini com saída estruturada e marca essas fotos como
"de orçamento", para não entrarem depois como foto de dano.
"""

from __future__ import annotations

import asyncio
import json
import logging

from google import genai
from google.cloud import firestore
from google.genai import types

from common.config import modelo_visao
from vistoria_team.tools.fotos_tool import _baixar, _client

TIPOS_SERVICO = ("funilaria", "pintura", "mecanica", "eletrica")
MAX_FOTOS = 5

PROMPT_EXTRACAO = """\
Você recebe foto(s) de um orçamento de reparo de veículo feito por uma
oficina (papel, PDF ou planilha na tela). Transcreva os itens.

Regras:
- Um item por peça ou serviço. Não invente item, valor nem quantidade que
  não esteja legível na imagem.
- valor_peca: valor UNITÁRIO da peça em reais, número sem "R$" (ex.: 550.0).
  Se só houver o total da linha e a quantidade, divida. Serviço sem peça
  (ex.: alinhamento) tem valor_peca 0.
- horas_mao_obra: horas de mão de obra do item, se aparecer; senão null.
- valor_mao_obra: valor em reais da mão de obra do item, se aparecer em
  vez das horas; senão null.
- tipo_servico: um de funilaria, pintura, mecanica, eletrica (o que melhor
  descreve a mão de obra do item).
- tipo_intervencao: "troca", "reparo" ou "pintura".
- legivel: false se a imagem não for um orçamento ou estiver ilegível.
- total_documento: o total geral impresso no documento, se houver.
"""

_SCHEMA = {
    "type": "object",
    "properties": {
        "legivel": {"type": "boolean"},
        "itens": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "peca": {"type": "string"},
                    "tipo_intervencao": {"type": "string"},
                    "quantidade": {"type": "number"},
                    "valor_peca": {"type": "number"},
                    "horas_mao_obra": {"type": "number", "nullable": True},
                    "valor_mao_obra": {"type": "number", "nullable": True},
                    "tipo_servico": {"type": "string"},
                },
                "required": ["peca", "quantidade", "valor_peca", "tipo_servico"],
            },
        },
        "total_documento": {"type": "number", "nullable": True},
        "observacao": {"type": "string", "nullable": True},
    },
    "required": ["legivel", "itens"],
}

_genai: genai.Client | None = None


def _genai_client() -> genai.Client:
    global _genai
    if _genai is None:
        # Vertex/AI Studio vem das mesmas variáveis de ambiente do ADK.
        _genai = genai.Client()
    return _genai


def _numero(valor) -> float | None:
    if valor is None or isinstance(valor, bool):
        return None
    try:
        n = float(valor)
    except (TypeError, ValueError):
        return None
    return n if n == n and n not in (float("inf"), float("-inf")) else None


def normalizar_itens(bruto: dict) -> list[dict]:
    """Limpa o que o Gemini devolveu: descarta item sem peça, força tipos e
    valores válidos. Valores negativos ou absurdos viram 0 e o mecânico
    corrige na conferência."""
    itens = []
    for item in (bruto or {}).get("itens") or []:
        if not isinstance(item, dict):
            continue
        peca = str(item.get("peca") or "").strip()
        if not peca:
            continue

        quantidade = _numero(item.get("quantidade")) or 1
        quantidade = max(1, round(quantidade))

        valor_peca = _numero(item.get("valor_peca")) or 0.0
        valor_peca = valor_peca if 0 <= valor_peca < 1_000_000 else 0.0

        horas = _numero(item.get("horas_mao_obra"))
        horas = horas if horas is not None and 0 <= horas < 1000 else None

        valor_mao_obra = _numero(item.get("valor_mao_obra"))
        valor_mao_obra = (
            valor_mao_obra
            if valor_mao_obra is not None and 0 <= valor_mao_obra < 1_000_000
            else None
        )

        tipo = str(item.get("tipo_servico") or "").strip().lower()
        tipo = (
            tipo.replace("â", "a").replace("ê", "e").replace("é", "e")
            if tipo
            else ""
        )
        if tipo not in TIPOS_SERVICO:
            tipo = "funilaria"

        itens.append(
            {
                "peca": peca,
                "tipo_intervencao": str(item.get("tipo_intervencao") or "troca")
                .strip()
                .lower(),
                "quantidade": quantidade,
                "valor_peca": round(valor_peca, 2),
                "horas_mao_obra": horas,
                "valor_mao_obra": valor_mao_obra,
                "tipo_servico": tipo,
            }
        )
    return itens


async def _extrair(fotos: list[tuple[bytes, str]]) -> dict:
    partes = [types.Part.from_bytes(data=dados, mime_type=mime) for dados, mime in fotos]
    partes.append(types.Part(text=PROMPT_EXTRACAO))
    resposta = await _genai_client().aio.models.generate_content(
        model=modelo_visao(),
        contents=[types.Content(role="user", parts=partes)],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema=_SCHEMA,
            temperature=0,
        ),
    )
    return json.loads(resposta.text or "{}")


async def ler_orcamento_das_fotos(id_vistoria: str) -> dict:
    """Lê o orçamento pronto que o mecânico fotografou e devolve os itens.

    Chame depois que chegar "Fotos enviadas" na etapa de orçamento, quando o
    mecânico escolheu mandar foto do orçamento dele. Usa só as fotos novas da
    vistoria e as marca como foto de orçamento.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.

    Returns:
        dict com `itens` (peca, tipo_intervencao, quantidade, valor_peca,
        horas_mao_obra, valor_mao_obra, tipo_servico), `total_documento`
        (total impresso, só para conferência), `fotos_lidas` e `legivel`.
        Se `fotos_lidas` for 0 ou `legivel` for false, peça uma foto nova
        ou siga com a lista de referência.
    """
    db = _client()
    ref = db.collection("vistorias").document(id_vistoria)
    vistoria = ref.get().to_dict() or {}

    vistas = set(vistoria.get("imagensAnalisadasIds") or [])
    novas = [
        img
        for img in (vistoria.get("images") or [])
        if img.get("imageId") and img.get("imageId") not in vistas
    ][-MAX_FOTOS:]

    if not novas:
        return {"itens": [], "fotos_lidas": 0, "legivel": False, "total_documento": None}

    conteudos = await asyncio.gather(*(_baixar(img) for img in novas))
    fotos, ids = [], []
    for img, dados in zip(novas, conteudos):
        if dados:
            fotos.append((dados, img.get("contentType") or "image/jpeg"))
            ids.append(img["imageId"])

    if not fotos:
        return {"itens": [], "fotos_lidas": 0, "legivel": False, "total_documento": None}

    try:
        bruto = await _extrair(fotos)
    except Exception as e:  # modelo fora do ar, JSON inválido etc.
        logging.exception("leitura do orçamento por foto falhou: %s", e)
        return {
            "erro": "Não foi possível ler a foto agora.",
            "itens": [],
            "fotos_lidas": 0,
            "legivel": False,
            "total_documento": None,
        }

    itens = normalizar_itens(bruto)
    legivel = bool(bruto.get("legivel")) and bool(itens)

    # Fotos de orçamento não são foto de dano: tira da fila do analista de
    # danos e guarda o que foi lido para auditoria.
    ref.set(
        {
            "imagensAnalisadasIds": firestore.ArrayUnion(ids),
            "imagensOrcamentoIds": firestore.ArrayUnion(ids),
            "orcamentoImportado": {
                "origem": "foto",
                "imageIds": ids,
                "itens": itens,
                "totalDocumento": _numero(bruto.get("total_documento")),
                "legivel": legivel,
                "lidoEm": firestore.SERVER_TIMESTAMP,
            },
        },
        merge=True,
    )

    return {
        "itens": itens,
        "fotos_lidas": len(ids),
        "legivel": legivel,
        "total_documento": _numero(bruto.get("total_documento")),
        "observacao": bruto.get("observacao"),
    }

"""Ponte entre as fotos já salvas no Firestore/Storage (pelo app Flutter)
e a análise de visão computacional (`AnalistaDanosVisao`).

Decisão técnica registrada aqui (pendência antiga do README): usamos o
Artifact Service nativo do ADK, não uma referência `gs://` manual. O
coordenador baixa cada foto nova e chama `tool_context.save_artifact`;
como `AnalistaDanosVisao` é chamado via `AgentTool`, o `AgentTool` já
encaminha esses artefatos pro sub-agente através de um
`ForwardingArtifactService` (ver `google.adk.tools.agent_tool`) — o
sub-agente só precisa ter a tool `load_artifacts` (built-in do ADK) na
própria lista de tools pra "enxergar" o que foi salvo aqui. Isso funciona
igual em produção (com `--artifact_service_uri gs://<bucket>`) e local
(`InMemoryArtifactService`, default do `InMemoryRunner`/`adk web`).

Duas correções de produção em relação à primeira versão:

1. O download era `urllib.request.urlopen` SÍNCRONO, em laço serial, dentro
   de uma função `async`. Num servidor uvicorn (que é o que o `adk
   api_server` é) isso congela o event loop da instância inteira — todas as
   outras conversas naquela instância ficam paradas durante os downloads.
   Agora cada foto baixa em thread separada e todas em paralelo.

2. As fotos eram marcadas como analisadas AQUI, antes de `AnalistaDanosVisao`
   sequer rodar. Se o turno falhasse depois disso (timeout, erro do modelo,
   reciclagem da instância), aquelas fotos eram puladas para sempre e a
   vistoria seguia com um laudo "consistente" que nunca viu imagem nenhuma.
   A marcação virou a tool separada `marcar_fotos_analisadas`, chamada pelo
   agente só no fim do Passo 4.

Preferimos `storagePath` (download autenticado pela service account do Cloud
Run) ao campo `url`, porque a URL de download do Firebase carrega um token
que pode ser revogado/rotacionado — o `storagePath` não expira.
"""

from __future__ import annotations

import asyncio
import os
import urllib.request

from google.adk.tools import ToolContext
from google.cloud import firestore, storage
from google.genai import types

_db: firestore.Client | None = None
_gcs: storage.Client | None = None

_BUCKET_PADRAO = "fho-argos.firebasestorage.app"


def _client() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def _bucket() -> storage.Bucket:
    global _gcs
    if _gcs is None:
        _gcs = storage.Client()
    return _gcs.bucket(os.environ.get("ARGOS_STORAGE_BUCKET", _BUCKET_PADRAO))


def _baixar_sincrono(imagem: dict) -> bytes:
    """Roda sempre dentro de `asyncio.to_thread` — nunca chame direto."""
    storage_path = (imagem.get("storagePath") or "").strip()
    if storage_path:
        return _bucket().blob(storage_path).download_as_bytes()

    url = (imagem.get("url") or "").strip()
    if not url:
        raise ValueError("imagem sem storagePath nem url")

    with urllib.request.urlopen(url, timeout=20.0) as resp:
        return resp.read()


async def _baixar(imagem: dict) -> bytes | None:
    try:
        return await asyncio.to_thread(_baixar_sincrono, imagem)
    except Exception:
        # Não marca como processada — a próxima chamada tenta de novo.
        return None


async def carregar_fotos_para_analise(
    id_vistoria: str, tool_context: ToolContext
) -> dict:
    """Baixa as fotos novas (ainda não analisadas) de `vistorias/{id}.images`
    e salva cada uma como artefato do ADK, pronto pra `AnalistaDanosVisao`
    ler via `load_artifacts`.

    Chame ANTES de `AnalistaDanosVisao` em cada leva de fotos (Passo 4). Só
    baixa o que ainda não foi baixado nesta vistoria — chamadas repetidas
    não re-processam a mesma foto.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.

    Returns:
        dict com `artefatos_salvos` (nomes pra passar pro `load_artifacts`
        se precisar, mas normalmente nem é necessário citar o nome — o
        sub-agente lista os artefatos disponíveis sozinho), `quantidade`,
        `falhas` (fotos que não baixaram e serão tentadas de novo depois) e
        `image_ids_da_leva`, que você DEVE guardar para passar a
        `marcar_fotos_analisadas` no fim do Passo 4.
    """
    db = _client()
    vistoria_ref = db.collection("vistorias").document(id_vistoria)
    vistoria = vistoria_ref.get().to_dict() or {}

    imagens = vistoria.get("images") or []
    ja_processadas = set(vistoria.get("imagensAnalisadasIds") or [])
    novas = [
        img
        for img in imagens
        if img.get("imageId") and img.get("imageId") not in ja_processadas
    ]

    if not novas:
        return {
            "artefatos_salvos": [],
            "quantidade": 0,
            "falhas": 0,
            "image_ids_da_leva": [],
        }

    conteudos = await asyncio.gather(*(_baixar(img) for img in novas))

    artefatos_salvos: list[str] = []
    ids_da_leva: list[str] = []
    falhas = 0

    for imagem, dados in zip(novas, conteudos):
        if dados is None:
            falhas += 1
            continue

        image_id = imagem.get("imageId")
        content_type = imagem.get("contentType") or "image/jpeg"
        nome_artefato = f"vistoria_{id_vistoria}_{image_id}.jpg"

        try:
            await tool_context.save_artifact(
                nome_artefato,
                types.Part.from_bytes(data=dados, mime_type=content_type),
            )
        except Exception:
            falhas += 1
            continue

        artefatos_salvos.append(nome_artefato)
        ids_da_leva.append(image_id)

    # NÃO grava `imagensAnalisadasIds` aqui de propósito — ver docstring do
    # módulo. Quem marca é `marcar_fotos_analisadas`, depois da análise.
    return {
        "artefatos_salvos": artefatos_salvos,
        "quantidade": len(artefatos_salvos),
        "falhas": falhas,
        "image_ids_da_leva": ids_da_leva,
    }

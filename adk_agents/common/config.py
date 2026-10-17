"""Configuracao central de modelo.

O modelo vem de variavel de ambiente para poder ser trocado com um
`gcloud run services update --update-env-vars`, sem rebuild da imagem.

Padrao: `gemini-3.1-flash-lite` na conversa e `gemini-3.8-flash` so na
analise de fotos (ARGOS_MODEL_VISAO).

Em 2026-10-14 a conversa passou para o 3.8-flash e o chat ficou lento:
medido em 2026-10-16 nos logs do Cloud Run, cada chamada ao modelo levava
3-8s (o flash-lite leva ~1s), e um turno faz 2-3 chamadas — 10-17s por
mensagem. Voltou ao flash-lite no mesmo dia; evals: orcamento 4/4, vistoria
4/5 (o caso da piada no 1o turno responde sem chamar
carregar_contexto_vistoria antes).

TESTADO NO VERTEX DO fho-argos EM 2026-09-16, com o agente de verdade:
  - gemini-2.5-flash-lite   NAO USAR como coordenador. Ele NAO consegue emitir
                            tool call estruturada com este conjunto de tools:
                            o turno morre com finishReason MALFORMED_FUNCTION_CALL
                            e o modelo escreve a chamada como codigo Python em
                            texto ("print(default_api.carregar_contexto_vistoria(...))").
                            O erro e do modelo, nao do prompt — o state chegava certo.
  - gemini-3.1-flash-lite   OK. Tool call estruturada correta, ~5s no primeiro turno.
  - gemini-2.5-flash        OK (era o modelo original do projeto), mais caro.

ATENCAO: os modelos 3.x SO existem no endpoint `global` do Vertex — em
us-central1 a chamada volta 404. Por isso o servico roda com
GOOGLE_CLOUD_LOCATION=global. Se voltar para um modelo 2.5, pode voltar a
us-central1 (ou deixar em global, que atende os dois).

ARGOS_MODEL vale para os agentes que conversam; ARGOS_MODEL_VISAO permite dar
um modelo melhor so ao analista de fotos (o ponto onde precisao importa mais)
sem encarecer o resto.
"""

from __future__ import annotations

import os

_PADRAO = "gemini-3.1-flash-lite"
_PADRAO_VISAO = "gemini-3.8-flash"


def modelo_conversa() -> str:
    """Modelo dos agentes que falam com o mecanico e orquestram o fluxo."""
    return os.environ.get("ARGOS_MODEL", _PADRAO)


def modelo_visao() -> str:
    """Modelo do analista de danos por foto (onde a precisao importa mais)."""
    return os.environ.get("ARGOS_MODEL_VISAO", _PADRAO_VISAO)

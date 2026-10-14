"""Configuracao central de modelo.

O modelo vem de variavel de ambiente para poder ser trocado com um
`gcloud run services update --update-env-vars`, sem rebuild da imagem.

Padrao: `gemini-3.8-flash` (mesmo modelo das Cloud Functions). Antes era
`gemini-3.1-flash-lite`, o mais barato que passou no teste real abaixo —
o 3.8-flash ainda precisa ser validado com os evals (adk_agents/eval).

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

_PADRAO = "gemini-3.8-flash"


def modelo_conversa() -> str:
    """Modelo dos agentes que falam com o mecanico e orquestram o fluxo."""
    return os.environ.get("ARGOS_MODEL", _PADRAO)


def modelo_visao() -> str:
    """Modelo do analista de danos por foto. Cai no de conversa se nao setado."""
    return os.environ.get("ARGOS_MODEL_VISAO", modelo_conversa())

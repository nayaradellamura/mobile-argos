"""Callbacks compartilhados pelos dois times de agente.

Mora aqui, e não em `vistoria_team/agent.py`, porque `vistoria_team` já
importa `orcamento_team` — o caminho inverso fecharia um ciclo de import.
"""

from __future__ import annotations

import logging


def tratar_erro_de_tool(*, tool, args, tool_context, error):
    """Impede que uma tool quebrada mate o turno do chat.

    Sem nenhum callback registrado, o ADK re-levanta a exceção
    (`flows/llm_flows/functions.py`), a requisição vira 500 e o mecânico
    perde a conversa no meio — com o agravante de que o estado parcial já
    foi gravado no Firestore. Devolvendo um dict, o erro vira apenas mais um
    resultado de ferramenta e o agente segue conversando.

    A assinatura é por palavra-chave e os nomes são exatamente estes
    (`tool`, `args`, `tool_context`, `error`) — é assim que o ADK invoca o
    callback. Qualquer outro nome levanta TypeError na primeira falha de
    tool, justamente quando o tratamento deveria estar funcionando.
    """
    logging.exception("tool %s falhou: %s", getattr(tool, "name", tool), error)
    return {
        "erro": (
            f"A ferramenta {getattr(tool, 'name', 'desconhecida')} falhou. "
            "Avise o mecânico que deu um problema técnico nesse ponto e siga "
            "a conversa sem esse dado — não invente o resultado que ela "
            "deveria ter trazido."
        )
    }

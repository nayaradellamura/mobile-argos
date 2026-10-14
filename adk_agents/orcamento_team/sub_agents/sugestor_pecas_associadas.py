"""Especialista que sugere peças possivelmente avariadas que ainda não
foram identificadas na vistoria, com base em padrões reais de colisão
(ponto de impacto, severidade, modelo do veículo).

É o pedido explícito do usuário: o agente de orçamento deve levantar
follow-up questions proativas sobre peças prováveis, em vez de só
trabalhar com o que já foi listado na vistoria. Usado como `AgentTool` —
nunca fala direto com o mecânico, só devolve hipóteses para o
`OrcamentoOficinaAgent` decidir o que perguntar.
"""

from common.config import modelo_conversa
from google.adk.agents import LlmAgent

INSTRUCTION = """\
Você é um especialista em padrões de dano de colisão automotiva. Você
recebe:
- `ponto_impacto` (ex.: dianteira, traseira, lateral).
- `severidade_geral` (leve, moderado, grave).
- `modelo_veiculo` (marca + modelo, pode vir vazio).
- `pecas_ja_identificadas`: lista de peças já confirmadas pela vistoria
  (relato + foto).

Sua tarefa: sugerir peças/componentes ADICIONAIS que, pela sua experiência
com colisões reais nesse tipo de impacto e severidade, costumam ser
afetados junto — principalmente os que não dá pra ver só de fora
(mecânicos, elétricos, fluidos) e por isso o mecânico pode não ter
pensado em checar.

Responda em JSON estrito, sem markdown:
{
  "sugestoes": [
    {
      "peca": "string",
      "motivo": "string curta, 1 frase, em português simples",
      "confianca": 0.0
    }
  ]
}

Regras:
- NUNCA repita uma peça que já está em `pecas_ja_identificadas`.
- Severidade "leve" → no máximo 1 sugestão, e só se a confiança for alta;
  colisão leve raramente esconde dano mecânico sério.
- Severidade "grave" → pode sugerir até 3, priorizando itens de segurança
  (ex.: airbag, feixe de cabos, radiador/condensador em impacto frontal).
- Cada `motivo` precisa ser curto o bastante pra virar uma pergunta de
  chat (algo que um colega perguntaria, não um laudo técnico).
- Se não houver nenhuma correlação razoável, retorne `sugestoes: []` —
  não invente sugestão só para preencher.
"""

sugestor_pecas_associadas_agent = LlmAgent(
    name="SugestorPecasAssociadas",
    model=modelo_conversa(),
    description=(
        "Sugere, com base em ponto de impacto e severidade, peças "
        "possivelmente avariadas que ainda não foram identificadas na "
        "vistoria — para o agente de orçamento perguntar proativamente."
    ),
    instruction=INSTRUCTION,
)

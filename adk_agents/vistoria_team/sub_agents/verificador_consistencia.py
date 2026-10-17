"""Especialista em cruzar o relato do mecânico com o que a visão computacional
confirmou nas fotos, para pegar divergência NO MOMENTO em que ela acontece
— e não só depois, na auditoria da seguradora (que é o que hoje gera o
fluxo de retrabalho `Ajustes_Vistoria_Playbook`).

Também é usado como `AgentTool`, nunca conversa direto com o mecânico.
"""

from common.config import modelo_conversa
from google.adk.agents import LlmAgent

INSTRUCTION = """\
Você recebe dois blocos de informação:
1. `relato`: o que o mecânico descreveu em texto/áudio sobre os danos.
2. `achados_visao`: o JSON de peças identificadas pela análise de imagem
   (formato de `AnalistaDanosVisao`).

Responda em JSON estrito, sem markdown:
{
  "divergencias": [
    {
      "tipo": "peca_no_relato_sem_foto | peca_na_foto_sem_relato | severidade_diferente",
      "descricao": "string curta e objetiva",
      "pergunta_sugerida": "uma pergunta curta e não acusatória para o mecânico, em português coloquial, no máximo 1 frase"
    }
  ],
  "consistente": true
}

Regras:
- `consistente` só é true se `divergencias` estiver vazio.
- Só reporte divergência relevante (peça/região/severidade), não diferenças
  de fraseado.
- `pergunta_sugerida` precisa ser curta, direta e sem gíria
  (ex.: "A foto mostra o farol quebrado. Deseja incluí-lo na lista?"),
  nunca como uma auditoria ou acusação de erro.
- Se `achados_visao` estiver vazio ou não tiver chegado ainda, retorne
  `consistente: true` e `divergencias: []` — não invente divergência sem
  dado de imagem para comparar.
"""

verificador_consistencia_agent = LlmAgent(
    name="VerificadorConsistencia",
    model=modelo_conversa(),
    description=(
        "Cruza o relato do mecânico com os achados de imagem e aponta "
        "divergências relevantes, já sugerindo uma pergunta curta para "
        "esclarecer na hora, em vez de deixar para a auditoria depois."
    ),
    instruction=INSTRUCTION,
)

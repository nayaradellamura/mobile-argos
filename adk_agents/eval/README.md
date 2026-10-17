# Avaliação dos agentes ADK (evals)

Avaliação comportamental do `OrcamentoOficinaAgent` e do
`VistoriaPeritoDigitalAgent` com o framework de avaliação do Google ADK
(`google-adk` 2.8, formato `EvalSet`). Complementa os testes unitários de
`adk_agents/tests/` (que rodam no CI, sem LLM): aqui o agente roda de
verdade contra o Gemini, então **não roda no CI**.

## O que é avaliado

| Arquivo | Casos | Turnos |
| --- | --- | --- |
| `orcamento_team/eval/orcamento_basico.test.json` | 4 | 11 |
| `vistoria_team/eval/vistoria_basico.test.json` | 5 | 6 |

Métricas (`test_config.json` em cada pasta):

- `tool_trajectory_avg_score` (limiar 1.0, `match_type: IN_ORDER`): as
  chamadas de ferramenta esperadas precisam acontecer, na ordem, com os
  mesmos argumentos — chamadas extras são permitidas. Só entram aqui as
  chamadas com argumentos determinísticos (ex.:
  `carregar_orcamento_confirmado(id_vistoria=...)`).
- `rubric_based_tool_use_quality_v1` (limiar 0.8, juiz `gemini-2.5-flash`):
  regras de uso de ferramenta que a trajetória não expressa, ex.: "chama
  `verificar_faixa_preco` depois de `carregar_orcamento_confirmado`", "NÃO
  chama `enviar_laudo_cloud_function` sem um 'sim' explícito".
- `rubric_based_final_response_quality_v1` (limiar 0.8): tom de voz (sem
  gírias como "rapaz", "show", "beleza", "fechou"), no máximo 3 frases, e as
  frases-gatilho que o app usa ("liberei a câmera", "liberei a tela de
  orçamento").

Rubricas globais ficam no `test_config.json`; as específicas de cada turno
ficam no próprio `.test.json` (campo `rubrics` de cada invocação).

Cenários principais:

- **Orçamento**: transição vistoria → orçamento (carrega contexto, sugere no
  máximo 2 peças, libera a tela); retomada após `"enviei o orçamento"`
  (carrega a tabela, verifica a faixa e negocia só o item fora da faixa);
  total calculado pela ferramenta (R$ 2.272,00 / R$ 1.352,00); confirmação
  obrigatória antes do envio, incluindo resposta ambígua e pedido de
  correção; tom de voz diante de gírias do usuário.
- **Vistoria**: primeiro turno chama `carregar_contexto_vistoria` com o id
  da sessão; usa o relato já existente; libera a câmera com a frase literal
  e não analisa fotos antes de recebê-las; retificação foca nos ajustes
  pendentes; não pede o id da vistoria; tom de voz.

Fica de fora a análise de fotos (`carregar_fotos_para_analise` →
`AnalistaDanosVisao` → `VerificadorConsistencia`), porque ela precisa de
fotos reais no Storage.

## Pré-requisitos

1. Dependências de avaliação do ADK (não estão no `requirements.txt`):

   ```powershell
   cd adk_agents
   .venv\Scripts\python.exe -m pip install "google-adk[eval]"
   ```

2. `adk_agents/.env` com `GOOGLE_API_KEY` (AI Studio) e
   `GOOGLE_GENAI_USE_VERTEXAI=FALSE`, igual à simulação local (ver
   `.env.example`). A cota gratuita do `gemini-2.5-flash` é baixa: cada caso
   faz várias chamadas ao modelo e o juiz das rubricas faz outras 3 por
   turno. Se aparecer `429 RESOURCE_EXHAUSTED`, use uma chave paga, Vertex AI
   ou `--runs 1`.

3. Emulador do Firestore (porta 8080, configurado em `firebase.json`) — as
   ferramentas gravam no banco, então **nunca** rode contra o projeto real:

   ```powershell
   # na raiz do repositório, num terminal separado
   firebase emulators:start --only firestore
   ```

## Como rodar

```powershell
cd adk_agents
$env:FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080"
$env:GOOGLE_CLOUD_PROJECT = "demo-argos"

# 1) Seed das vistorias de avaliação (VIS-EVAL-*). Rode de novo antes de
#    cada execução: os agentes alteram os documentos.
.venv\Scripts\python.exe eval\seed_eval.py

# 2a) Pelo script (usa AgentEvaluator; 2 execuções por caso por padrão)
.venv\Scripts\python.exe eval\run_evals.py
.venv\Scripts\python.exe eval\run_evals.py orcamento_team --runs 1

# 2b) Ou pela CLI do ADK
.venv\Scripts\adk.exe eval orcamento_team orcamento_team\eval\orcamento_basico.test.json `
  --config_file_path orcamento_team\eval\test_config.json --print_detailed_results
.venv\Scripts\adk.exe eval vistoria_team vistoria_team\eval\vistoria_basico.test.json `
  --config_file_path vistoria_team\eval\test_config.json --print_detailed_results
```

Também dá para abrir os eval sets no `adk web` (aba *Eval*) a partir de
`adk_agents/`, com as mesmas variáveis de ambiente.

O script termina com código 1 se algum caso ficar abaixo do limiar e
imprime, por métrica, a pontuação de cada turno.

## Notas

- Cada caso começa numa sessão nova com `state.id_vistoria` fixado
  (`session_input`), do mesmo jeito que o app abre a sessão.
- Os valores de referência de preço são gravados pelo seed em
  `tabelaPrecos/popular_compacto/pecas/*`, para os totais e a checagem de
  faixa serem determinísticos.
- Resultados de LLM variam entre execuções; por isso `num_runs` é 2 e os
  juízes usam 3 amostras. Para a banca, registre a saída de uma execução
  completa em vez de uma única tentativa.

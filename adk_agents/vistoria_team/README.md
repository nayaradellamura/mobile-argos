# VistoriaPeritoDigitalAgent (time ADK)

Primeiro pedaço do redesenho do agente conversacional do Argos em Google
ADK. Escopo: **só a etapa de vistoria** — o orçamento fica para a próxima
rodada (ver skill `nova-captura-em-lote`).

## Por que um time e não um agente só

| Papel | Tipo | Por quê |
|---|---|---|
| `VistoriaPeritoDigitalAgent` (`agent.py`) | `LlmAgent` coordenador | É a única "voz" que o mecânico vê — persona curta e coloquial. |
| `AnalistaDanosVisao` | `LlmAgent` usado via `AgentTool` | Raciocínio de visão computacional é uma tarefa fechada (input: fotos+relato, output: JSON) — não precisa de personalidade nem de manter a conversa. |
| `VerificadorConsistencia` | `LlmAgent` usado via `AgentTool` | Mesma lógica: cruzar dois JSONs e apontar divergência é uma tarefa de raciocínio isolada, testável separadamente do fluxo de conversa. |

Usar `AgentTool` (em vez de `sub_agents` com transferência) para os dois
especialistas é proposital: o coordenador **não perde o controle da
conversa** para consultar visão/consistência — ele chama, recebe a
resposta, e decide o que fazer, exatamente como uma função. Transferência
via `sub_agents` fica reservada para uma mudança real de fase da conversa
(ex.: vistoria → orçamento, quando isso for implementado).

## O que muda de propósito em relação ao playbook `Vistoria_Perito_Digital` original

- **Consistência em tempo real:** o playbook original só validava o relato
  contra um manual (texto), e qualquer furo só aparecia depois, na
  auditoria da seguradora (fluxo `Ajustes_Vistoria_Playbook`). Aqui, toda
  leva de foto passa por `AnalistaDanosVisao` + `VerificadorConsistencia`
  antes do agente seguir em frente — a pergunta de esclarecimento acontece
  na hora, com o mecânico ainda na oficina.
- **Linguagem:** o playbook original tinha falas fixas e mais longas
  ("Explique o motivo de forma técnica...", frases de várias linhas). Aqui
  a instrução pede explicitamente tom de colega de oficina e no máximo
  2-3 frases por mensagem.
- **Severidade com justificativa curta:** mantém o requisito de
  explicabilidade (XAI) do TCC, mas sem virar um relatório longo no chat —
  o relatório detalhado fica nos campos salvos (`salvar_estado_vistoria`),
  não na conversa.

## O que foi mantido do original (por ser conhecimento de domínio real)

- A "trava de estado" para fotos (avisar, parar de falar, só continuar com
  a confirmação de envio) — já validada no app, ver
  `especialista-flutter-firebase-argos`.
- Os campos de negócio (`hodometro`, `dinamica_acidente`, `ponto_impacto`,
  `danos_externos`, `danos_estruturais`) e a distinção dano externo x
  estrutural.
- A regra de nunca inventar dano e preservar a incerteza do relato.

## Pendências / decisões em aberto

- `consultar_manual_sinistros` está com uma base mínima embutida
  (`tools/manual_sinistros_tool.py`) — trocar por Vertex AI Search/RAG
  quando o manual real da seguradora parceira estiver disponível.
  **Pesquisado em 2026-09-01:** não existe manual técnico peça-a-peça
  público (Audatex/Solera são proprietários) — mas incorporamos a
  **Resolução CONTRAN 810/2020** (classificação de dano em pequena/
  média/grande monta, critério estrutural x superficial), que é uma
  norma federal pública e citável. Não substitui um manual real da
  seguradora, mas é uma base mais defensável que achismo puro pro TCC.
- **Resolvido em 2026-09-01:** `AnalistaDanosVisao` recebe as fotos via o
  Artifact Service nativo do ADK, não uma referência `gs://` manual. O
  coordenador chama a tool nova `carregar_fotos_para_analise`
  (`tools/fotos_tool.py`) antes de acionar `AnalistaDanosVisao` — ela
  baixa cada foto nova de `vistoria['images']` e salva via
  `tool_context.save_artifact`; o `AgentTool` encaminha isso pro
  sub-agente automaticamente (`ForwardingArtifactService`), que só
  precisa da tool built-in `load_artifacts` (já adicionada) pra "ver" as
  imagens. Funciona igual local (`InMemoryArtifactService`, default do
  `InMemoryRunner`/`adk web`) e em produção
  (`--artifact_service_uri gs://<bucket>`) — não precisa mudar nada nesse
  código quando o Cloud Run entrar. Ainda não testado com fotos reais
  (só revisão de código + docs do ADK instalado), ver pendência de teste
  local abaixo.
- Testar localmente com `adk web` antes de qualquer troca do que a Cloud
  Function `sendArgosMessage`/`sendArgosAudioMessage` chama hoje.

## Handoff para o orçamento

Ao final do Passo 5, este agente transfere a conversa (via `sub_agents`)
para o `OrcamentoOficinaAgent` (`adk_agents/orcamento_team`) — ver o
README daquele pacote para o desenho da etapa de orçamento (captura em
lote + sugestão proativa de peças).

# OrcamentoOficinaAgent (time ADK)

Segundo pedaço do redesenho do agente conversacional do Argos, contínuo ao
`vistoria_team`. Resolve os dois problemas identificados nesta rodada de
design:

1. **Gargalo de UX** apontado pelo orientador do TCC: o playbook original
   perguntava peça por peça, sem teto — inviável em sinistros com 50+
   itens.
2. **Follow-up proativo**: o agente deveria sugerir peças possivelmente
   avariadas que o mecânico não pensou em checar, não só trabalhar com o
   que já foi relatado.

## Papéis

| Papel | Tipo | Por quê |
|---|---|---|
| `OrcamentoOficinaAgent` (`agent.py`) | `LlmAgent` coordenador | Continua a mesma persona do time de vistoria; só entra na conversa pra sugerir peças e negociar exceções de valor. |
| `SugestorPecasAssociadas` | `LlmAgent` via `AgentTool` | Reasoning aberto (conhecimento geral de padrões de colisão) — não é uma tabela fixa, por isso é um agente e não só uma tool determinística. Sempre devolve confiança + motivo curto, nunca afirma como fato. |
| `consultar_preco_referencia` / `verificar_faixa_preco` / `calcular_orcamento_total` | `FunctionTool` (determinísticas) | Preço e soma são fatos verificáveis, não devem depender do LLM "lembrar certo" — daí serem tools de código, não raciocínio. |
| `enviar_laudo_cloud_function` | `FunctionTool` | Transição de status (`EM_ANALISE_OPERACIONAL`), mesmo efeito que `VistoriaChatSessionService.submitForOperationalAnalysis` já tem em Dart. |

## Fluxo (ver `agent.py` para o texto completo da instrução)

1. Carrega o que a vistoria já salvou (danos, ponto de impacto,
   severidade) — silencioso.
2. Chama `SugestorPecasAssociadas` — silencioso.
3. Uma única mensagem de transição + no máximo 2 sugestões proativas
   (se houver), em tom curto de colega.
4. Pré-preenche preço de referência de cada peça confirmada.
5. Libera a tela nativa de tabela (trava de estado, mesmo padrão da
   câmera) — ver skill `nova-captura-em-lote` para o desenho da tela e do
   schema Firestore `tabelaPrecos`.
6. Só volta a falar para negociar itens fora da faixa de preço esperada.
7. Fecha com `calcular_orcamento_total` (nunca soma de cabeça), salva o
   estado e dispara o envio para auditoria.

## Handshake com o app (Passo 2→Passo 4)

- Passo 2 grava o rascunho pré-preenchido em `vistorias/{id}.orcamentoRascunho`
  via `salvar_rascunho_orcamento` (tool em `common/firestore_tools.py`) —
  é esse campo que a tela nativa (`OrcamentoTablePage` no Flutter) lê para
  pré-preencher a tabela antes do mecânico ver.
- Passo 3 precisa dizer literalmente "liberei a tela de orçamento" — é o
  gatilho que `ai_chat_page.dart` usa (`_isOrcamentoReleaseText`) para abrir
  a tela automaticamente, mesmo padrão do gatilho de fotos.
- O app grava a lista final em `vistorias/{id}.orcamentoItensFinais` numa
  única escrita e manda uma mensagem de retomada; Passo 4 lê essa lista
  via `carregar_orcamento_confirmado`.

## Teste local do handshake

`adk_agents/scripts/teste_rapido_orcamento.py` exercita os 2 turnos do
handshake (Passo 0-2 → app grava `orcamentoItensFinais` → Passo 4) contra
um Firestore fake em memória, sem precisar do emulador. Validado em
2026-09-01 até onde a quota gratuita do Gemini API permitiu (5 req/min —
ver aviso no topo do script): confirmado que `carregar_contexto_vistoria`
e `consultar_preco_referencia` disparam corretamente no Passo 0-2. O
fluxo completo até `carregar_orcamento_confirmado`/`calcular_orcamento_total`
ainda não foi validado ponta-a-ponta numa única execução por causa do
rate limit — rodar de novo com uma API key com quota maior (ou
throttle de ~60s entre turnos) para fechar essa validação.

## Pendências / decisões em aberto

- **Revisado em 2026-09-01** com validação de domínio (persona
  `especialista-sinistros`): `tabelaPrecos` agora é **segmentada por
  categoria de porte de veículo** (`popular_compacto`,
  `medio_suv_compacto`, `suv_grande_picape` — ver `_categoria_por_modelo`
  em `tools/precos_tool.py`), não mais um único "modelo genérico". Peça
  de reposição varia demais por porte no Brasil pra uma tabela única ser
  defensável. Valores de para-choque/farol ancorados em anúncios reais
  pesquisados; o resto segue proporção de domínio entre categorias — ver
  fontes e raciocínio completo no cabeçalho de
  `adk_agents/scripts/seed_tabela_precos.py`. Ainda são estimativas pro
  TCC, não uma tabela de mercado auditada — o próximo passo de
  robustez seria cotação manual pontual de 5-6 peças-âncora por
  categoria em concessionária/loja real. Rode o seed contra o emulador
  antes de testar a captura em lote, senão `consultar_preco_referencia`
  cai no fallback menor embutido em `tools/precos_tool.py`.
- `airbag do motorista` está na tabela, mas o valor é uma referência
  grosseira (não inclui central/sensores/volante completo) — a
  instruction do Passo 1 já restringe a sugestão proativa a
  `severidade_geral: "grave"`.
- `SugestorPecasAssociadas` depende do conhecimento geral do modelo sobre
  colisões — vale validar as sugestões com `especialista-sinistros` antes
  de confiar cegamente nelas em produção; para o TCC, documentar isso como
  uma limitação conhecida (é heurística assistida por IA, não uma tabela
  de correlação validada estatisticamente).
- `_VALOR_HORA_MAO_OBRA` em `precos_tool.py` está fixo — na prática varia
  por credenciado/convênio; ajustar para vir do cadastro do credenciado
  quando isso existir.

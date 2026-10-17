# Argos

![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/plataforma-Android-3DDC84?logo=android&logoColor=white)
![Firebase](https://img.shields.io/badge/backend-Firebase-FFCA28?logo=firebase&logoColor=white)
![TCC](https://img.shields.io/badge/projeto-TCC%20FHO-6f42c1)

Vistorias automotivas inteligentes para oficinas credenciadas. Este repositório reúne o **app mobile** (Flutter) do ecossistema **Argos**, usado por mecânicos para coletar evidências de sinistros com apoio de IA, e o **backend** que ele usa: Cloud Functions, o agente conversacional em Google ADK e o serviço que gera o laudo técnico e o orçamento em PDF.

Documentação técnica:

- [docs/ARQUITETURA.md](docs/ARQUITETURA.md): componentes, fluxos (passo a passo e em massa), modelo de dados, cálculo do orçamento, estratégia offline e limitações conhecidas.
- [docs/DEPLOY.md](docs/DEPLOY.md): comandos de implantação de cada parte e checklist completo.

## Sobre o projeto

O Argos é o Trabalho de Conclusão de Curso do grupo *"Triagem Inteligente de Sinistros Automotivos em Ambiente Cloud-Native"* (Sistemas de Informação, FHO — Centro Universitário Hermínio Ometto).

**O problema:** no fluxo tradicional de FNOL (First Notice of Loss) das seguradoras, o próprio segurado tira as fotos do sinistro. O resultado costuma ser baixa qualidade e fácil de fraudar — o clássico *garbage in, garbage out*.

**A proposta:** inverter o modelo para **B2B**. A seguradora atribui o sinistro a uma **oficina credenciada**, e é o mecânico quem faz a coleta técnica das evidências — guiado por um agente de IA multimodal (Gemini) que cruza fotos com a narração falada do mecânico para identificar danos que a câmera sozinha não pega (problemas estruturais, por exemplo), e gera um laudo técnico estruturado e explicável (XAI). A classificação de severidade segue as categorias da **Resolução CONTRAN nº 810/2020** (pequena/média/grande monta).

### Arquitetura do ecossistema

O TCC é dividido em três partes. O painel web fica em outro repositório; o app e o backend estão aqui.

| Parte | Onde vive | O que faz |
|---|---|---|
| Painel web | repositório separado (Next.js) | seguradora simula o FNOL, despacha vistorias, acompanha o Kanban de sinistros, revisa e aprova laudos |
| **App mobile** | `lib/` (Flutter, Android) | check-in da vistoria, coleta de evidências (guiada por IA ou tudo de uma vez), tabela de orçamento, acompanhamento dos sinistros atribuídos |
| **Backend serverless** | `functions/` (Cloud Functions) | ponte entre o app e o agente, transcrição de áudio, notificações push, gatilhos de geração de PDF, expiração de vistorias, alertas no Telegram |
| **Agente de IA** | `adk_agents/` (Google ADK no Cloud Run) | conduz a vistoria (fotos, análise de danos, consistência com o relato) e o orçamento |
| **Geração de laudo** | `services/laudo-service/` (Cloud Run) | gera o laudo técnico e o orçamento aprovado (PDF) a partir das evidências, usando Gemini |

Detalhes e diagramas em [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

### Fluxo principal no app

1. Login com e-mail/senha ou Google.
2. Conclusão do perfil e vinculação com a oficina credenciada.
3. Listagem dos sinistros atribuídos ao mecânico.
4. Check-in da vistoria.
5. Coleta das evidências em dois modos: **passo a passo** (chat guiado por IA, foto a foto) ou **enviar tudo de uma vez** (fotos, áudios, texto e orçamento soltos, sem conversa). Funciona offline — o que for coletado sem rede sincroniza sozinho quando ela voltar.
6. Revisão do orçamento numa tabela: peças × quantidade + horas × valor da hora da oficina, por tipo de serviço.
7. Processamento das evidências e geração do laudo técnico pelo `services/laudo-service`.
8. Se a seguradora rejeitar o laudo, o mecânico recebe uma **retificação** (correção pontual, sempre pelo modo passo a passo).

## Baixe o app para testar

Não precisa instalar nada de Flutter pra só experimentar o app no celular — o CI já gera um APK assinado a cada build.

1. Acesse a aba [**Actions**](../../actions/workflows/shorebird-release.yml) do repositório (precisa estar logado no GitHub, mesmo o repo sendo público — é assim que o GitHub libera download de artefato).
2. Abra a execução mais recente com o ícone verde (✓) de sucesso.
3. Em **Artifacts**, baixe `argos-release-apk-shorebird` e extraia o `.zip` — dentro está o `app-release.apk`.
4. Transfira o APK pro celular e instale (o Android vai pedir pra liberar "instalar de fontes desconhecidas" na primeira vez).

> Esse é o build que recebe atualizações automáticas depois de instalado (via Shorebird, OTA) — não precisa reinstalar a cada correção pequena, o app se atualiza sozinho ao abrir.

## Rodando localmente (para dev)

### App Flutter

Pré-requisitos: [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ e um dispositivo/emulador Android.

```bash
git clone https://github.com/nayaradellamura/mobile-argos.git argos_app
cd argos_app
flutter pub get
flutter run
```

A configuração do Firebase (`google-services.json`, `firebase_options.dart`) já está versionada no repositório — não precisa criar projeto Firebase próprio pra rodar localmente.

> **Build de release no Windows:** builds `--release` (e por consequência `shorebird patch`/`shorebird release`) podem falhar em alguns ambientes Windows com JDK moderno (`Unable to establish loopback connection`). Se isso acontecer, use os workflows do GitHub Actions (`build-apk`, `shorebird-release`, `shorebird-patch` em `.github/workflows/`) — eles rodam em runner Linux e não têm esse problema. `flutter run` em modo debug funciona normalmente no Windows.

### Cloud Functions (`functions/`)

Pré-requisitos: Node 22 e Firebase CLI (`npm install -g firebase-tools`).

```bash
cd functions
npm ci
cp .env.example .env      # preencha os parâmetros (ver comentários no arquivo)
cd ..
firebase emulators:start --only functions,firestore
```

Os segredos (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `MONITORING_WEBHOOK_TOKEN`) não vão no `.env`: em produção ficam no Secret Manager e, no emulador, em `functions/.secret.local`.

### laudo-service (`services/laudo-service/`)

Pré-requisitos: Node 22, Chromium (ou deixar o Puppeteer baixar o dele) e `gcloud auth application-default login` com acesso ao projeto.

```bash
cd services/laudo-service
cp .env.example .env
npm install
npm start                 # sobe em :8080
```

Exemplos de chamada e detalhes em [services/laudo-service/README.md](services/laudo-service/README.md).

### Agentes ADK (`adk_agents/`)

Pré-requisitos: Python 3.11+, Firebase CLI (para o emulador do Firestore) e uma chave gratuita do Google AI Studio em `adk_agents/.env` (`GOOGLE_API_KEY`).

```powershell
powershell -ExecutionPolicy Bypass -File adk_agents\scripts\simular_local.ps1
```

O script cria o venv em `adk_agents/.venv`, sobe o emulador do Firestore, cria uma vistoria de exemplo e abre o `adk web`. Detalhes de cada time de agentes em `adk_agents/vistoria_team/README.md` e `adk_agents/orcamento_team/README.md`.

### Variáveis de ambiente

| Parte | Modelo | Observação |
|---|---|---|
| Cloud Functions | [functions/.env.example](functions/.env.example) | URLs do agente e do laudo-service, fila do Cloud Tasks e service account do invoker; segredos no Secret Manager |
| laudo-service | [services/laudo-service/.env.example](services/laudo-service/.env.example) | projeto, região, bucket e modelo Gemini; em produção vão como variáveis do Cloud Run |
| Agentes ADK | `adk_agents/.env` (só local) | usado apenas na simulação local; em produção o `deploy_cloud_run.ps1` configura Vertex AI e não envia o `.env` para a imagem |

Nenhum `.env` real deve ser versionado (o `.gitignore` já cobre esses arquivos).

## Testes

```bash
# App Flutter
flutter analyze
flutter test

# laudo-service (node:test)
cd services/laudo-service
npm test                  # equivale a: node --test

# Agentes ADK (a partir de adk_agents/, com o venv ativado)
cd adk_agents
python -m pytest          # ou: python -m unittest discover
```

Os scripts `adk_agents/scripts/teste_rapido.py` e `teste_rapido_orcamento.py` são roteiros manuais contra o Gemini (sujeitos à quota gratuita do AI Studio), não testes automatizados.

## Deploy

Ordem recomendada (comandos completos em [docs/DEPLOY.md](docs/DEPLOY.md)):

1. **laudo-service** no Cloud Run (`gcloud run deploy laudo-service --source .`) e a fila `laudo-tecnico` do Cloud Tasks.
2. **Agentes ADK** no Cloud Run (`adk_agents/scripts/deploy_cloud_run.ps1`, com `-ArtifactServiceUri gs://...` para as fotos não se perderem quando a instância reciclar).
3. **Cloud Functions** (`firebase deploy --only functions`), com as URLs dos dois serviços acima em `functions/.env`.
4. **App** via Shorebird: patch (só código Dart) ou release (mudança nativa), pelos workflows do GitHub Actions.

A ordem importa na primeira implantação, porque as Functions precisam das URLs dos serviços. Nas seguintes, implante só o que mudou.

### Checklist de deploy

- [ ] `flutter analyze`, `flutter test` e os testes do laudo-service e dos agentes passando
- [ ] `functions/.env` com as URLs atuais de `argos-adk` e `laudo-service`
- [ ] Fila `laudo-tecnico` criada com `--max-attempts=5` e backoff
- [ ] Bucket de artefatos do ADK criado, com permissão para a service account do `argos-adk`
- [ ] Service account das Functions com `roles/run.invoker` no `argos-adk` e permissão de enfileirar no Cloud Tasks
- [ ] TTL ativo em `_processedEvents.expireAt`
- [ ] Segredos do Telegram e do webhook do Cloud Monitoring configurados
- [ ] `tabelaPrecos` populada em produção
- [ ] Regras do Firestore aplicadas no projeto `fho-argos`: leitura de `tabelaPrecos` por usuários autenticados e escrita de `valoresHoraMaoObra` pelos funcionários da oficina (as regras ficam fora deste repositório)
- [ ] Vistoria de teste nos dois modos até o laudo ficar `pronto`

A versão completa está em [docs/DEPLOY.md](docs/DEPLOY.md#8-checklist-de-deploy).

## Estrutura do projeto

- `lib/`: código-fonte do app Flutter
- `test/`: testes do app Flutter
- `android/`: projeto Android nativo
- `assets/`: imagens e ícones do app
- `functions/`: Firebase Cloud Functions (backend serverless)
- `services/laudo-service/`: serviço Cloud Run que gera o laudo técnico e o orçamento em PDF
- `adk_agents/`: agentes de IA em Google ADK (`vistoria_team`, `orcamento_team`, código comum e scripts de simulação, seed e deploy)
- `docs/`: arquitetura e deploy
- `.github/workflows/`: pipelines de build/release/patch (CI)
- `firebase.json`: configuração do projeto Firebase
- `shorebird.yaml`: configuração das atualizações OTA (Shorebird)
- `pubspec.yaml`: dependências Flutter

## Plataforma ativa

- Android

As pastas de outras plataformas Flutter podem ser regeneradas no futuro com `flutter create .`, caso o projeto volte a precisar de iOS, Web ou Desktop.

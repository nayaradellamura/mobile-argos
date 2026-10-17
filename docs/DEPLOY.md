# Deploy do Argos

Passo a passo para implantar todas as partes deste repositório no projeto `fho-argos` (região `us-central1`). A visão geral da arquitetura está em [ARQUITETURA.md](ARQUITETURA.md).

Ordem recomendada na primeira vez:

1. [Preparação do projeto](#1-preparação-do-projeto) (uma vez)
2. [laudo-service](#2-laudo-service-cloud-run) (Cloud Run) e [fila do Cloud Tasks](#3-fila-do-cloud-tasks)
3. [Agente ADK](#4-agente-adk-cloud-run-argos-adk) (Cloud Run `argos-adk`)
4. [Cloud Functions](#5-cloud-functions) (precisam das URLs dos dois serviços acima)
5. [App via Shorebird](#6-app-android-shorebird)

Nas atualizações do dia a dia, implante só a parte que mudou. A exceção é uma mudança de contrato entre as partes (campo novo no Firestore, rota nova): nesse caso, implante primeiro quem lê o campo novo e por último quem passa a gravá-lo (normalmente o app).

Convenções usadas nos comandos:

```bash
PROJECT=fho-argos
REGION=us-central1
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format="value(projectNumber)")
# Service account padrão do Compute: é a identidade de runtime do Cloud Run e
# das Cloud Functions de 2ª geração quando nenhuma outra foi configurada.
DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
```

> Os comandos estão em sintaxe bash (Git Bash, Cloud Shell, Linux). No PowerShell, troque `\` por `` ` `` no fim das linhas e defina as variáveis com `$PROJECT = "fho-argos"`.

---

## 1. Preparação do projeto

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project $PROJECT

gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  cloudtasks.googleapis.com \
  cloudscheduler.googleapis.com \
  eventarc.googleapis.com \
  secretmanager.googleapis.com \
  aiplatform.googleapis.com \
  firestore.googleapis.com \
  storage.googleapis.com \
  --project=$PROJECT

npm install -g firebase-tools
firebase login
```

## 2. laudo-service (Cloud Run)

Detalhes e execução local em [services/laudo-service/README.md](../services/laudo-service/README.md). Variáveis de ambiente: [services/laudo-service/.env.example](../services/laudo-service/.env.example).

**2.1. Service account usada pelo Cloud Tasks para chamar o serviço (uma vez):**

```bash
gcloud iam service-accounts create laudo-invoker \
  --display-name="Cloud Tasks -> laudo-service" \
  --project=$PROJECT
```

**2.2. Build e deploy** (a partir de `services/laudo-service/`; o Cloud Build usa o `Dockerfile` da pasta):

```bash
cd services/laudo-service
gcloud run deploy laudo-service \
  --source . \
  --project=$PROJECT \
  --region=$REGION \
  --no-allow-unauthenticated \
  --memory=2Gi \
  --cpu=2 \
  --timeout=300 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$PROJECT,GOOGLE_CLOUD_LOCATION=$REGION,ARGOS_STORAGE_BUCKET=fho-argos.firebasestorage.app,LAUDO_GEMINI_MODEL=gemini-2.5-flash"
cd ../..
```

> Antes do `--source .`, confira que não existe um `.env` local dentro de `services/laudo-service/`: a pasta não tem `.gcloudignore`, e o `Dockerfile` faz `COPY . .`. Se existir, apague-o ou crie um `.gcloudignore` com `.env` e `node_modules/`.

**2.3. Permissões (uma vez):**

```bash
# Cloud Tasks (via laudo-invoker) pode invocar o serviço privado
gcloud run services add-iam-policy-binding laudo-service \
  --project=$PROJECT --region=$REGION \
  --member="serviceAccount:laudo-invoker@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# Identidade de runtime do laudo-service: Firestore, Storage e Vertex AI
for ROLE in roles/datastore.user roles/storage.objectAdmin roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$DEFAULT_SA" --role="$ROLE"
done
```

**2.4. URL base do serviço** (vai para `functions/.env` no passo 5):

```bash
gcloud run services describe laudo-service --project=$PROJECT --region=$REGION --format="value(status.url)"
```

## 3. Fila do Cloud Tasks

As Functions enfileiram as tarefas em `laudo-tecnico`. O `laudo-service` responde 500 quando a falha é dele (Gemini, Puppeteer, Storage), e a fila tenta de novo; 400 é erro do chamador e não é repetido.

**Criar (uma vez):**

```bash
gcloud tasks queues create laudo-tecnico \
  --project=$PROJECT \
  --location=$REGION \
  --max-attempts=5 \
  --min-backoff=30s \
  --max-backoff=600s \
  --max-doublings=4 \
  --max-retry-duration=3600s \
  --max-concurrent-dispatches=5 \
  --max-dispatches-per-second=1
```

Com esses valores, as novas tentativas ficam em cerca de 30 s, 60 s, 120 s e 240 s depois da primeira falha, dentro do limite de 1 hora. O limite de 5 envios simultâneos protege a cota do Gemini e a memória do Cloud Run (Puppeteer).

**Se a fila já existe** (criada sem essas opções):

```bash
gcloud tasks queues update laudo-tecnico \
  --project=$PROJECT --location=$REGION \
  --max-attempts=5 --min-backoff=30s --max-backoff=600s \
  --max-doublings=4 --max-retry-duration=3600s \
  --max-concurrent-dispatches=5 --max-dispatches-per-second=1
```

**Permissões para as Functions enfileirarem e assinarem o token OIDC como `laudo-invoker` (uma vez):**

```bash
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$DEFAULT_SA" \
  --role="roles/cloudtasks.enqueuer"

gcloud iam service-accounts add-iam-policy-binding \
  laudo-invoker@$PROJECT.iam.gserviceaccount.com \
  --project=$PROJECT \
  --member="serviceAccount:$DEFAULT_SA" \
  --role="roles/iam.serviceAccountUser"
```

> As tarefas têm nome determinístico (`laudo-{sinistroId}-{vistoriaId}`). O Cloud Tasks reserva o nome de uma tarefa por um tempo depois que ela termina ou é apagada. Por isso, para reprocessar manualmente um PDF que ficou com `status: "erro"`, crie a tarefa com outro nome (por exemplo, com sufixo `-retry1`).

## 4. Agente ADK (Cloud Run `argos-adk`)

O deploy usa `adk_agents/scripts/deploy_cloud_run.ps1` (PowerShell), que roda `gcloud run deploy --source` com o `Dockerfile` da raiz de `adk_agents/`. **Não use `adk deploy cloud_run`**: ele trata a pasta como um agente só e o serviço sobe sem o app `vistoria_team` (o motivo está comentado no `Dockerfile`). O `.gcloudignore` mantém `.env`, `.venv`, testes e avaliações fora da imagem, e o `Dockerfile` ainda define `ADK_DISABLE_LOAD_DOTENV=1`.

O script reproduz a configuração da revisão em produção: Vertex AI no endpoint `global` (os modelos 3.x só existem nele), service account `argos-adk@fho-argos.iam.gserviceaccount.com`, sem acesso anônimo, até 3 instâncias.

Por padrão, o ADK guarda **sessões e artefatos (fotos) na memória** da instância. Se ela reciclar no meio de uma vistoria, as fotos ainda não analisadas se perdem. O `Dockerfile` liga o armazenamento persistente quando as variáveis abaixo existem:

| Parâmetro do script | Variável no serviço | Uso |
|---|---|---|
| `-Model` | `ARGOS_MODEL` | Modelo dos agentes que conversam. Padrão `gemini-3.8-flash` |
| `-ModelVisao` | `ARGOS_MODEL_VISAO` | Modelo só do analista de fotos (opcional) |
| `-ArtifactServiceUri gs://<bucket>` | `ARTIFACT_SERVICE_URI` | **Recomendado em produção.** Fotos sobrevivem à troca de instância |
| `-SessionServiceUri <uri>` | `SESSION_SERVICE_URI` | Sessões persistentes (ex.: `agentengine://<id>`). Sem isso, as Functions reconstroem a conversa a partir de `chatmessages` |

O modelo pode ser trocado sem rebuild: `gcloud run services update argos-adk --region=us-central1 --update-env-vars=ARGOS_MODEL=<modelo>`. Os testes de modelo feitos no projeto estão comentados em `adk_agents/common/config.py`.

### 4.1. Uma vez: bucket de artefatos

```bash
ADK_BUCKET=fho-argos-adk-artifacts

gcloud storage buckets create gs://$ADK_BUCKET \
  --project=$PROJECT \
  --location=$REGION \
  --uniform-bucket-level-access \
  --public-access-prevention

# As fotos já estão no bucket do Firebase; aqui é só cópia de trabalho do
# agente. Apagar depois de 30 dias reduz custo e exposição de dados (LGPD).
cat > /tmp/adk-lifecycle.json <<'EOF'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 30}}]}
EOF
gcloud storage buckets update gs://$ADK_BUCKET --lifecycle-file=/tmp/adk-lifecycle.json
```

### 4.2. Uma vez: permissões da identidade de runtime do `argos-adk`

```bash
# Descobrir a SA de runtime (vazio = service account padrão do Compute)
gcloud run services describe argos-adk --project=$PROJECT --region=$REGION \
  --format="value(spec.template.spec.serviceAccountName)"
ADK_SA=$DEFAULT_SA   # ou a SA retornada acima

# Ler e gravar objetos no bucket de artefatos
gcloud storage buckets add-iam-policy-binding gs://$ADK_BUCKET \
  --member="serviceAccount:$ADK_SA" \
  --role="roles/storage.objectUser"

# Gemini no Vertex AI e Agent Engine Sessions (se usar -SessionServiceUri agentengine://)
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$ADK_SA" --role="roles/aiplatform.user"

# Firestore (tools do agente)
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$ADK_SA" --role="roles/datastore.user"
```

> No primeiro deploy o serviço ainda não existe; rode o `describe` depois dele ou assuma a SA padrão do Compute.

### 4.3. Opcional: instância do Agent Engine para sessões

Só é necessário se for usar sessões no Agent Engine. A instância guarda apenas sessões; o agente continua rodando no Cloud Run.

```powershell
adk_agents\.venv\Scripts\pip install "google-cloud-aiplatform[agent-engines]>=1.148.1,<2"
adk_agents\.venv\Scripts\python -c "import vertexai; c = vertexai.Client(project='fho-argos', location='us-central1'); e = c.agent_engines.create(); print(e.api_resource.name)"
```

A saída tem o formato `projects/<número>/locations/us-central1/reasoningEngines/<ID>`. Use em `-SessionServiceUri agentengine://<ID>`.

### 4.4. Deploy

```powershell
# Igual à produção atual (tudo em memória), com o modelo novo
powershell -ExecutionPolicy Bypass -File adk_agents\scripts\deploy_cloud_run.ps1

# Recomendado: fotos no GCS
powershell -ExecutionPolicy Bypass -File adk_agents\scripts\deploy_cloud_run.ps1 `
  -ArtifactServiceUri gs://fho-argos-adk-artifacts

# Voltar para a revisão anterior, se algo der errado
gcloud run services update-traffic argos-adk --region=us-central1 --to-revisions=<REVISAO>=100
```

Depois do deploy, rode as avaliações dos agentes (`adk_agents/eval/README.md`) para validar o modelo.

### 4.5. Depois do deploy (uma vez por serviço novo)

```bash
# URL do agente -> ARGOS_ADK_SERVICE_URL em functions/.env
gcloud run services describe argos-adk --project=$PROJECT --region=$REGION --format="value(status.url)"

# SA das Functions pode invocar o agente (serviço privado)
FUNCTIONS_SA=$(gcloud functions describe sendArgosMessage --gen2 --project=$PROJECT --region=$REGION \
  --format="value(serviceConfig.serviceAccountEmail)")
gcloud run services add-iam-policy-binding argos-adk \
  --project=$PROJECT --region=$REGION \
  --member="serviceAccount:$FUNCTIONS_SA" \
  --role="roles/run.invoker"
```

### 4.6. Tabela de preços de referência

O agente e o app consultam `tabelaPrecos`. Sem ela, o agente usa uma tabela de reserva com 5 peças.

```powershell
adk_agents\.venv\Scripts\python adk_agents\scripts\seed_tabela_precos.py --real
# o script pede para digitar "confirmo" antes de gravar em produção
```

## 5. Cloud Functions

**5.1. Parâmetros** (`defineString`): copie [functions/.env.example](../functions/.env.example) para `functions/.env` e preencha:

| Variável | Valor |
|---|---|
| `ARGOS_ADK_SERVICE_URL` | URL do `argos-adk` (passo 4.5) |
| `LAUDO_SERVICE_URL` | `<URL do laudo-service>/gerar-laudo` |
| `ORCAMENTO_SERVICE_URL` | `<URL do laudo-service>/gerar-orcamento-aprovado` |
| `LAUDO_TASKS_QUEUE` | `laudo-tecnico` |
| `LAUDO_TASKS_LOCATION` | `us-central1` |
| `LAUDO_INVOKER_SERVICE_ACCOUNT` | `laudo-invoker@fho-argos.iam.gserviceaccount.com` |
| `GEMINI_REVIEW_MODEL` (opcional) | modelo da transcrição de áudio (padrão `gemini-3.8-flash`, endpoint `global`) |

**5.2. Segredos** (`defineSecret`, Secret Manager; uma vez, ou quando trocar o valor):

```bash
firebase functions:secrets:set TELEGRAM_BOT_TOKEN --project $PROJECT
firebase functions:secrets:set TELEGRAM_CHAT_ID --project $PROJECT
firebase functions:secrets:set MONITORING_WEBHOOK_TOKEN --project $PROJECT
```

**5.3. Deploy:**

```bash
cd functions && npm ci && cd ..
firebase deploy --only functions --project $PROJECT
```

Para implantar uma função só: `firebase deploy --only functions:sendArgosMessage --project $PROJECT`.

**5.4. TTL de `_processedEvents` (uma vez):** a coleção guarda os IDs de eventos já processados por `notifySinistroChanges`, com `expireAt` em 24 horas. Sem a política de TTL, os documentos nunca são apagados.

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=_processedEvents \
  --enable-ttl \
  --project=$PROJECT
```

A exclusão pelo TTL não é imediata (normalmente ocorre em até 24 horas depois do `expireAt`). Isso não afeta a deduplicação.

**5.5. Índice composto:** `expireStaleVistorias` consulta `vistorias` com `status ==` e `agentBusinessExpiresAt <=`. Se o índice não existir, a primeira execução falha e o log da função traz o link para criá-lo no console. Os índices também não estão versionados neste repositório.

**5.6. Alertas no Telegram (uma vez):** crie no Cloud Monitoring um canal de notificação do tipo *Webhook with token authentication* apontando para a URL da função `telegramAlertRelay`, com `?token=<MONITORING_WEBHOOK_TOKEN>`. Depois associe o canal às políticas de alerta desejadas.

## 6. App Android (Shorebird)

Os builds de release devem sair dos workflows do GitHub Actions (`.github/workflows/`), porque `flutter build --release` pode falhar em alguns ambientes Windows (`Unable to establish loopback connection`).

- **Release** (nova versão nativa, gera APK com o motor do Shorebird): aumente `version` no `pubspec.yaml` e rode o workflow `shorebird-release` (Actions → *Run workflow*). Equivalente local:

  ```bash
  shorebird release android --artifact apk -- --no-tree-shake-icons
  ```

- **Patch** (só código Dart, sem mudar dependência nativa nem assets): rode o workflow `shorebird-patch` informando a versão do release (ex.: `1.0.1+5` ou `latest`). Equivalente local:

  ```bash
  shorebird patch android --release-version=<versão> -- --no-tree-shake-icons
  ```

  A flag `--no-tree-shake-icons` precisa ser igual no release e no patch; caso contrário, o Shorebird recusa o patch por mudança de asset.

- Segredos do repositório usados pelos workflows: `SHOREBIRD_TOKEN`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`.

## 7. Regras do Firestore (fora deste repositório)

> **As regras do Firestore e do Storage ficam fora deste repositório; aplique-as no projeto `fho-argos`** (console do Firebase ou o repositório que as versiona). O `firebase.json` daqui não tem seção `firestore`, então `firebase deploy` a partir deste repositório não altera regras.

Itens que o app e o orçamento por oficina exigem:

1. **`tabelaPrecos` legível por qualquer usuário autenticado** (somente leitura; a escrita é feita pelo script de seed com credencial administrativa):

   ```
   match /tabelaPrecos/{categoria}/pecas/{peca} {
     allow read: if request.auth != null;
     allow write: if false;
   }
   ```

2. **`credenciados/{id}.valoresHoraMaoObra` gravável pelos funcionários da própria oficina.** O app grava apenas `valoresHoraMaoObra` e `valoresHoraAtualizadoEm`, e os mecânicos da oficina estão em `funcionariosUids`. A regra deve permitir essa atualização sem liberar os demais campos do credenciado:

   ```
   match /credenciados/{credenciadoId} {
     allow read: if request.auth != null
       && request.auth.uid in resource.data.funcionariosUids;
     allow update: if request.auth != null
       && request.auth.uid in resource.data.funcionariosUids
       && request.resource.data.diff(resource.data).affectedKeys()
            .hasOnly(['valoresHoraMaoObra', 'valoresHoraAtualizadoEm']);
   }
   ```

   Atenção: a tela de perfil também faz `arrayUnion` do próprio uid em `funcionariosUids` ao vincular o mecânico à oficina (`lib/features/profile/profile_page.dart`). Se essa vinculação continuar sendo feita pelo app, a regra precisa de uma condição separada para ela, definida conforme a política de cadastro da seguradora. Confira também que as regras atuais de leitura de `credenciados` (usadas por `session_context_service.dart`) continuam valendo, combinando estes trechos com o que já existe no projeto.

3. Os demais acessos usados pelo app (`sinistro`, `vistorias`, `users`, `userDevices`, `counters`, `sinistro/{id}/viewers`) já precisam estar cobertos pelas regras atuais do projeto. Revise-os junto com as mudanças acima.

## 8. Checklist de deploy

Antes:

- [ ] `flutter analyze` e `flutter test` sem falhas
- [ ] Testes do `laudo-service` (`npm test`) e do `adk_agents` sem falhas
- [ ] `functions/.env` preenchido e coerente com as URLs atuais dos serviços
- [ ] Nenhum `.env` com chave real dentro das pastas enviadas por `--source`

Infraestrutura (uma vez por projeto):

- [ ] APIs habilitadas (passo 1)
- [ ] `laudo-invoker` criada, com `roles/run.invoker` no `laudo-service`
- [ ] Fila `laudo-tecnico` com `--max-attempts=5` e backoff configurado
- [ ] SA das Functions com `roles/cloudtasks.enqueuer` e `roles/iam.serviceAccountUser` em `laudo-invoker`
- [ ] Bucket `gs://fho-argos-adk-artifacts` com regra de ciclo de vida e `roles/storage.objectUser` para a SA do `argos-adk`
- [ ] SA do `argos-adk` com `roles/aiplatform.user` e `roles/datastore.user`
- [ ] SA das Functions com `roles/run.invoker` no `argos-adk`
- [ ] TTL em `_processedEvents.expireAt`
- [ ] Segredos `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` e `MONITORING_WEBHOOK_TOKEN`
- [ ] `tabelaPrecos` populada (`seed_tabela_precos.py --real`)
- [ ] Regras do Firestore da seção 7 aplicadas no projeto `fho-argos`

Implantação (na ordem):

- [ ] `laudo-service` (`gcloud run deploy`) e verificação do `GET /` (`laudo-service ok`)
- [ ] `argos-adk` (`deploy_cloud_run.ps1`, de preferência com `-ArtifactServiceUri`) e avaliações dos agentes
- [ ] Cloud Functions (`firebase deploy --only functions`)
- [ ] App: `shorebird-patch` (só Dart) ou `shorebird-release` (mudança nativa, com versão nova no `pubspec.yaml`)

Depois:

- [ ] Vistoria de teste no modo guiado até `EM_ANALISE_OPERACIONAL`, com `laudoTecnico.status = pronto` no sinistro
- [ ] Vistoria de teste no modo em massa, incluindo um envio feito offline
- [ ] Logs sem erro: `firebase functions:log`, e os logs do `laudo-service` e do `argos-adk` no Cloud Run
- [ ] Alerta de teste chegando no Telegram

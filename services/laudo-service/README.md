# laudo-service

Gera o **laudo técnico em PDF** de uma vistoria: recebe `{sinistroId, vistoriaId}`,
busca os dados no Firestore (sinistro + vistoria, mesma fonte que o app mobile
já lê), manda fotos + transcrição da conversa pro Gemini sintetizar os achados,
renderiza um PDF com a identidade visual do Argos e sobe pro Firebase Storage.

Disparado automaticamente por `functions/index.js` (`onVistoriaEnterAnaliseOperacional`)
sempre que uma vistoria entra em `EM_ANALISE_OPERACIONAL` — via Cloud Tasks, não
chamada direta, pra sobreviver a cold start/timeout do Cloud Run.

## Fluxo

```
mobile grava vistoriaAtualStatus = EM_ANALISE_OPERACIONAL
        │
        ▼
Cloud Function (Firestore trigger em sinistro/{id})
        │  enfileira no Cloud Tasks
        ▼
laudo-service (Cloud Run) — POST /gerar-laudo
        │  1. lê sinistro + vistoria no Firestore
        │  2. Gemini 2.5 Flash (multimodal: fotos + transcrição) → achados em JSON
        │  3. Handlebars + Puppeteer → PDF com a marca Argos
        │  4. sobe o PDF no Storage, grava a URL de volta no sinistro
        ▼
sinistro.laudoTecnico = { status: "pronto", url, ... }
```

## Rodando local

Precisa de um Chromium instalado (o Dockerfile usa o do `apt`; localmente, ou
deixa o Puppeteer baixar o dele — remova `PUPPETEER_SKIP_DOWNLOAD` do seu
ambiente — ou aponte `PUPPETEER_EXECUTABLE_PATH` pro Chrome/Chromium que já
tiver instalado).

```bash
cp .env.example .env   # ajuste os valores
npm install
npm start               # sobe em :8080

curl -X POST http://localhost:8080/gerar-laudo \
  -H "Content-Type: application/json" \
  -d '{"sinistroId":"ARG-2026-0001","vistoriaId":"<id-real-de-uma-vistoria>"}'
```

Precisa estar autenticado no gcloud com acesso ao projeto (`gcloud auth
application-default login`) pra falar com Firestore/Storage/Vertex AI local.

## Deploy — passo a passo (rodar uma vez)

Todos os comandos assumem `--project=fho-argos`.

**1. Criar a service account que o Cloud Tasks vai usar pra invocar o serviço:**
```bash
gcloud iam service-accounts create laudo-invoker \
  --display-name="Cloud Tasks -> laudo-service" \
  --project=fho-argos
```

**2. Implantar o serviço** (build automático a partir da pasta, igual o
`argos-adk` já faz):
```bash
gcloud run deploy laudo-service \
  --source . \
  --project=fho-argos \
  --region=us-central1 \
  --no-allow-unauthenticated \
  --memory=2Gi \
  --cpu=2 \
  --timeout=300 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=fho-argos,GOOGLE_CLOUD_LOCATION=us-central1,ARGOS_STORAGE_BUCKET=fho-argos.firebasestorage.app"
```

**3. Dar permissão pra service account invocar o serviço:**
```bash
gcloud run services add-iam-policy-binding laudo-service \
  --project=fho-argos \
  --region=us-central1 \
  --member="serviceAccount:laudo-invoker@fho-argos.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

**4. Dar permissão pro serviço ler/escrever Firestore e Storage** (a identidade
de runtime do Cloud Run — por padrão a service account default do Compute —
precisa disso; se ainda não tiver, ou se preferir uma SA dedicada):
```bash
gcloud projects add-iam-policy-binding fho-argos \
  --member="serviceAccount:<SA-DE-RUNTIME-DO-CLOUD-RUN>" \
  --role="roles/datastore.user"
gcloud projects add-iam-policy-binding fho-argos \
  --member="serviceAccount:<SA-DE-RUNTIME-DO-CLOUD-RUN>" \
  --role="roles/storage.objectAdmin"
gcloud projects add-iam-policy-binding fho-argos \
  --member="serviceAccount:<SA-DE-RUNTIME-DO-CLOUD-RUN>" \
  --role="roles/aiplatform.user"
```

**5. Criar a fila do Cloud Tasks:**
```bash
gcloud tasks queues create laudo-tecnico \
  --project=fho-argos \
  --location=us-central1
```

**6. Dar permissão pra Cloud Functions enfileirar tarefas e "vestir" a
service account do invoker:**
```bash
gcloud projects add-iam-policy-binding fho-argos \
  --member="serviceAccount:<SA-DE-RUNTIME-DAS-CLOUD-FUNCTIONS>" \
  --role="roles/cloudtasks.enqueuer"
gcloud iam service-accounts add-iam-policy-binding \
  laudo-invoker@fho-argos.iam.gserviceaccount.com \
  --project=fho-argos \
  --member="serviceAccount:<SA-DE-RUNTIME-DAS-CLOUD-FUNCTIONS>" \
  --role="roles/iam.serviceAccountUser"
```

**7. Configurar as functions** — copie `functions/.env.example` pra
`functions/.env` e preencha `LAUDO_SERVICE_URL` (pegue com o comando no
próprio `.env.example`), `LAUDO_TASKS_QUEUE`, `LAUDO_TASKS_LOCATION` e
`LAUDO_INVOKER_SERVICE_ACCOUNT`. Depois `firebase deploy --only functions`.

## Design do PDF

Usa `assets/argos_icon.png` (o ícone do app) como logo — funcional, mas é o
ícone quadrado do app, não uma logo com fundo transparente. Se/quando tiver
uma versão vetorial da marca, troca esse arquivo e some.

Cores: `#0057C0` (azul de marca do app) pro cabeçalho e títulos de seção;
verde/laranja/vermelho pro selo de severidade, mapeado em
`lib/pdf.js#SEVERITY_COLORS` pelas 3 categorias da Resolução CONTRAN 810/2020.

## O que ainda falta (próximos passos, não implementado nesta primeira versão)

- **Link no dashboard web**: o `web-argos` ainda não tem um botão/link pra
  `sinistro.laudoTecnico.url` na tela de detalhe do sinistro — é só embutir o
  campo que já existe.
- **Retry manual**: se `laudoTecnico.status` ficar `"erro"`, hoje não tem botão
  de "gerar de novo" em lugar nenhum — só reprocessa se o trigger disparar de
  novo (o que não acontece sozinho, porque o `vistoriaAtualStatus` já está em
  `EM_ANALISE_OPERACIONAL` e não muda). Um endpoint/botão de retry manual é
  natural de adicionar depois.
- **Compressão de fotos**: se uma vistoria tiver muitas fotos grandes, o PDF
  final fica pesado (imagens são embutidas na resolução original via URL). Dá
  pra redimensionar antes de embutir, se virar problema na prática.

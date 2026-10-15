# Deploy dos agentes ADK do Argos no Cloud Run (servico argos-adk).
#
# Usa o Dockerfile da raiz de adk_agents/ via `gcloud run deploy --source`.
# NAO use `adk deploy cloud_run`: ele trata a pasta como 1 agente so e o
# servico sobe sem o app `vistoria_team` (ver comentario no Dockerfile).
#
# A configuracao abaixo espelha a revisao que esta em producao
# (argos-adk-00007-nrz): Vertex AI no endpoint global, service account
# dedicada, .env desligado dentro do container.
#
# Persistencia (opcional, recomendada para producao):
#   -ArtifactServiceUri gs://<bucket>   fotos da vistoria sobrevivem a troca
#                                       de instancia do Cloud Run.
#   -SessionServiceUri <uri>            sessoes do agente persistentes
#                                       (ex.: agentengine://<id>).
# Sem elas, tudo fica em memoria: se a instancia reciclar no meio de uma
# vistoria, a sessao e as fotos ainda nao analisadas se perdem.
#
# Uso:
#   .\scripts\deploy_cloud_run.ps1
#   .\scripts\deploy_cloud_run.ps1 -ArtifactServiceUri gs://fho-argos-adk-artifacts
#   .\scripts\deploy_cloud_run.ps1 -Model gemini-3.1-flash-lite   # rollback de modelo

param(
    [string]$Project = "fho-argos",
    [string]$Region = "us-central1",
    [string]$ServiceName = "argos-adk",
    [string]$ServiceAccount = "argos-adk@fho-argos.iam.gserviceaccount.com",
    [string]$Model = "gemini-3.8-flash",
    [string]$ModelVisao = "",
    [string]$StorageBucket = "fho-argos.firebasestorage.app",
    [string]$ArtifactServiceUri = "",
    [string]$SessionServiceUri = "",
    [int]$MaxInstances = 3
)

$ErrorActionPreference = "Stop"

if ($ArtifactServiceUri -and -not $ArtifactServiceUri.StartsWith("gs://")) {
    throw "ArtifactServiceUri precisa comecar com gs://"
}

$root = Split-Path -Parent $PSScriptRoot

$envVars = @(
    "GOOGLE_GENAI_USE_VERTEXAI=TRUE",
    "GOOGLE_CLOUD_PROJECT=$Project",
    # Modelos 3.x so existem no endpoint global do Vertex (us-central1 da 404).
    "GOOGLE_CLOUD_LOCATION=global",
    "ADK_DISABLE_LOAD_DOTENV=1",
    "ARGOS_STORAGE_BUCKET=$StorageBucket",
    "ARGOS_MODEL=$Model"
)
if ($ModelVisao) { $envVars += "ARGOS_MODEL_VISAO=$ModelVisao" }
if ($ArtifactServiceUri) { $envVars += "ARTIFACT_SERVICE_URI=$ArtifactServiceUri" }
if ($SessionServiceUri) { $envVars += "SESSION_SERVICE_URI=$SessionServiceUri" }

if (-not $ArtifactServiceUri) {
    Write-Warning "Sem -ArtifactServiceUri: fotos da vistoria ficam em memoria."
}
if (-not $SessionServiceUri) {
    Write-Warning "Sem -SessionServiceUri: sessoes do agente ficam em memoria."
}

# Revisao que estava no ar antes deste deploy, para o comando de rollback.
$revisaoAnterior = gcloud run services describe $ServiceName `
    --project $Project --region $Region `
    --format "value(status.traffic[0].revisionName)" 2>$null

Write-Host "Deploy de $ServiceName ($Region) com modelo $Model..."

# --no-allow-unauthenticated: so a Cloud Function (com identidade propria)
# chama o agente.
gcloud run deploy $ServiceName `
    --source $root `
    --project $Project `
    --region $Region `
    --service-account $ServiceAccount `
    --no-allow-unauthenticated `
    --max-instances $MaxInstances `
    --cpu-boost `
    --set-env-vars ($envVars -join ",")

if ($LASTEXITCODE -ne 0) { throw "gcloud run deploy falhou (codigo $LASTEXITCODE)." }

if ($revisaoAnterior) {
    Write-Host "Deploy concluido. Para voltar a revisao anterior:"
    Write-Host "  gcloud run services update-traffic $ServiceName --project $Project --region $Region --to-revisions $revisaoAnterior=100"
} else {
    Write-Host "Deploy concluido. Revisoes anteriores: gcloud run revisions list --service $ServiceName --project $Project --region $Region"
}

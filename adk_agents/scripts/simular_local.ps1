# Simula o time de agentes ADK do Argos localmente, sem custo:
#   - Firestore rodando no EMULADOR (nao toca o projeto real fho-argos).
#   - Modelo via Gemini API gratuita (Google AI Studio), nao Vertex AI.
#   - adk web sobe o backend (API + UI padrao) pra testar
#     VistoriaPeritoDigitalAgent e OrcamentoOficinaAgent na mao.
#   - ui_teste/ sobe junto: uma UI de chat parecida com o app real
#     (mesmas cores/bolhas do ai_chat_page.dart), com botoes que simulam
#     a captura de foto por leva (identificacao/externos/estruturais) e
#     mandam a foto de verdade + a mensagem de confirmacao que o agente
#     espera - http://127.0.0.1:5540.
#
# Pre-requisitos:
#   - Python 3.10+ instalado e no PATH.
#   - Firebase CLI instalado (npm install -g firebase-tools).
#   - Uma GOOGLE_API_KEY gratuita: https://aistudio.google.com/apikey
#
# Uso:
#   1. Copie adk_agents\.env.example para adk_agents\.env e preencha
#      GOOGLE_API_KEY.
#   2. Rode este script a partir de qualquer diretorio:
#        powershell -ExecutionPolicy Bypass -File adk_agents\scripts\simular_local.ps1
#   3. Abra http://127.0.0.1:5540 para a UI parecida com o app (recomendado
#      para testar a experiencia do mecanico), ou http://127.0.0.1:8000
#      para a UI padrao do ADK (melhor pra depurar eventos/chamadas de tool
#      cru). Os botoes de foto na UI de teste ja mandam a mensagem de
#      confirmacao que o agente espera, ex. "Fotos de identificacao
#      enviadas com sucesso.".
#   4. Na UI padrao do ADK, escolha vistoria_team ou orcamento_team no
#      dropdown; na UI de teste, troque o time em Configuracoes (icone
#      de engrenagem). Pro orcamento (antes da tela de tabela existir),
#      descreva os itens em texto mesmo - o agente vai chamar as tools
#      com o que voce descrever.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$adkAgentsDir = Split-Path -Parent $scriptDir
$uiDir = Join-Path $adkAgentsDir "ui_teste"
$uiPort = 5540

Write-Host "== Simulacao local do time de agentes Argos ==" -ForegroundColor Cyan

# 1) Carregar .env (se existir) sem sobrescrever variaveis ja setadas na sessao
$envFile = Join-Path $adkAgentsDir ".env"
if (Test-Path $envFile) {
    Write-Host "Carregando $envFile"
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $parts = $line.Split("=", 2)
        if ($parts.Length -ne 2) { return }
        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (-not (Test-Path "env:$key") -or [string]::IsNullOrEmpty((Get-Item "env:$key" -ErrorAction SilentlyContinue).Value)) {
            Set-Item -Path "env:$key" -Value $value
        }
    }
} else {
    Write-Host "Aviso: $envFile nao existe. Copie .env.example para .env e preencha GOOGLE_API_KEY." -ForegroundColor Yellow
}

if ([string]::IsNullOrEmpty($env:GOOGLE_API_KEY)) {
    Write-Host "ERRO: GOOGLE_API_KEY nao esta definida." -ForegroundColor Red
    Write-Host "Gere uma chave gratuita em https://aistudio.google.com/apikey e coloque em adk_agents\.env" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrEmpty($env:GOOGLE_GENAI_USE_VERTEXAI)) {
    $env:GOOGLE_GENAI_USE_VERTEXAI = "FALSE"
}
if ([string]::IsNullOrEmpty($env:GOOGLE_CLOUD_PROJECT)) {
    $env:GOOGLE_CLOUD_PROJECT = "demo-argos"
}

# 2) Ambiente Python
$venvDir = Join-Path $adkAgentsDir ".venv"
if (-not (Test-Path $venvDir)) {
    Write-Host "Criando virtualenv em $venvDir"
    python -m venv $venvDir
}

$venvPython = Join-Path $venvDir "Scripts\python.exe"
$venvActivate = Join-Path $venvDir "Scripts\Activate.ps1"

Write-Host "Instalando dependencias (google-adk, google-cloud-firestore)..."
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet -r (Join-Path $adkAgentsDir "requirements.txt")

# 3) Emulador do Firestore (nao usa o projeto real fho-argos)
$firebaseCmd = Get-Command firebase -ErrorAction SilentlyContinue
if (-not $firebaseCmd) {
    Write-Host "ERRO: Firebase CLI nao encontrado. Instale com: npm install -g firebase-tools" -ForegroundColor Red
    exit 1
}

$logOut = Join-Path $env:TEMP "argos_firestore_emulator.out.log"
$logErr = Join-Path $env:TEMP "argos_firestore_emulator.err.log"

Write-Host "Subindo emulador do Firestore (log em $logOut)..."
$repoRoot = Split-Path -Parent $adkAgentsDir
$emulatorProcess = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "firebase emulators:start --only firestore" `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr

$env:FIRESTORE_EMULATOR_HOST = "localhost:8080"

Write-Host "Aguardando o emulador subir na porta 8080..."
$pronto = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $teste = Test-NetConnection -ComputerName "localhost" -Port 8080 -WarningAction SilentlyContinue
    if ($teste.TcpTestSucceeded) {
        $pronto = $true
        break
    }
}

if (-not $pronto) {
    Write-Host "ERRO: emulador nao respondeu na porta 8080. Veja $logOut / $logErr" -ForegroundColor Red
    Stop-Process -Id $emulatorProcess.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Emulador no ar." -ForegroundColor Green

# 3.5) Servidor estatico para a UI de chat parecida com o app (ui_teste/)
$uiLogOut = Join-Path $env:TEMP "argos_ui_teste.out.log"
$uiLogErr = Join-Path $env:TEMP "argos_ui_teste.err.log"
Write-Host "Subindo UI de teste parecida com o app em http://127.0.0.1:$uiPort (log em $uiLogOut)..."
$uiProcess = Start-Process -FilePath $venvPython `
    -ArgumentList "-m", "http.server", "$uiPort", "--directory", "`"$uiDir`"", "--bind", "127.0.0.1" `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $uiLogOut -RedirectStandardError $uiLogErr

try {
    # 4) Seed de uma vistoria de exemplo
    Write-Host "Criando vistoria de exemplo (VIS-SIMULACAO-0001)..."
    & $venvPython (Join-Path $scriptDir "seed_emulador.py")

    # 5) Sobe o backend do ADK (API + UI padrao) com CORS liberado para a UI de teste
    Write-Host ""
    Write-Host "Abrindo 'adk web' - deixe esta janela aberta durante o teste." -ForegroundColor Cyan
    Write-Host "UI parecida com o app: http://127.0.0.1:$uiPort" -ForegroundColor Cyan
    Write-Host "UI padrao do ADK (debug de eventos/tools): http://127.0.0.1:8000" -ForegroundColor Cyan
    Write-Host "Ctrl+C aqui encerra a simulacao e derruba o emulador." -ForegroundColor Cyan
    Write-Host ""

    $venvAdk = Join-Path $venvDir "Scripts\adk.exe"
    if (-not (Test-Path $venvAdk)) {
        Write-Host "ERRO: comando 'adk' nao encontrado em $venvAdk (verifique se google-adk instalou corretamente)." -ForegroundColor Red
        exit 1
    }

    Push-Location $adkAgentsDir
    & $venvAdk web --allow_origins "http://127.0.0.1:$uiPort" --allow_origins "http://localhost:$uiPort" .
    Pop-Location
}
finally {
    Write-Host "Encerrando UI de teste..."
    Stop-Process -Id $uiProcess.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Encerrando emulador do Firestore..."
    Stop-Process -Id $emulatorProcess.Id -Force -ErrorAction SilentlyContinue
}

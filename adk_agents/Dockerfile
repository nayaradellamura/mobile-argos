FROM python:3.11-slim

WORKDIR /app

RUN adduser --disabled-password --gecos "" myuser
USER myuser
ENV PATH="/home/myuser/.local/bin:$PATH"

# Cinto de segurança: mesmo que um .env escape do .gcloudignore, o ADK não
# carrega nenhum dele dentro do container. Sem isso, o FIRESTORE_EMULATOR_HOST
# do .env local aponta TODAS as tools de Firestore para um emulador que não
# existe em produção.
ENV ADK_DISABLE_LOAD_DOTENV=1
ENV PYTHONUNBUFFERED=1

COPY --chown=myuser:myuser requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# O projeto inteiro vira o agents_dir. É isso que mantém `common/`,
# `vistoria_team/` e `orcamento_team/` como pacotes IRMÃOS — exatamente o
# layout que `adk web .` usa localmente —, então os imports absolutos
# (`from common.firestore_tools import ...`) continuam funcionando sem
# nenhuma alteração de código.
#
# Não use `adk deploy cloud_run` aqui: ele assume 1 pasta = 1 agente e
# copiaria este projeto para /app/agents/adk_agents/, onde o loader do ADK
# não enxerga `vistoria_team` (ver cli_deploy.py:816,206,216 e
# agent_loader.py:50-51). O resultado seria um serviço com ZERO apps.
COPY --chown=myuser:myuser . /app/agents/

EXPOSE 8080

# --host=0.0.0.0 é OBRIGATÓRIO: o default do ADK é 127.0.0.1, o uvicorn faria
# bind em loopback, o Cloud Run nunca conseguiria abrir conexão e a revisão
# jamais ficaria pronta.
#
# --trace_to_cloud NÃO entra aqui de propósito: `fast_api.py:314-316` faz
# `from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter` sem
# try/except no boot. Esse pacote não é dependência do google-adk, então com a
# flag ligada e sem instalá-lo o container morre ao subir. Para ligar tracing,
# acrescente `opentelemetry-exporter-gcp-trace` ao requirements.txt e
# `--trace_to_cloud` ao comando abaixo — nessa ordem.
#
# As flags de serviço só entram no comando quando a env var correspondente
# está setada (sintaxe ${VAR:+...}), então o mesmo Dockerfile serve para o
# smoke test sem bucket e para produção com artifacts no GCS.
CMD ["sh", "-c", "exec adk api_server --host=0.0.0.0 --port=${PORT:-8080} ${ARTIFACT_SERVICE_URI:+--artifact_service_uri=$ARTIFACT_SERVICE_URI} ${SESSION_SERVICE_URI:+--session_service_uri=$SESSION_SERVICE_URI} /app/agents"]

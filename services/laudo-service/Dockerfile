# Puppeteer no Cloud Run: usa o Chromium do apt (mais leve/confiavel que o
# Chromium que o pacote puppeteer baixaria sozinho) e roda sem sandbox de
# processo, porque o proprio Cloud Run ja isola o container (gVisor).
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    fonts-noto-color-emoji \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    NODE_ENV=production

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY . .

# Cloud Run injeta $PORT; o index.js escuta nele (default 8080 localmente).
CMD ["node", "index.js"]

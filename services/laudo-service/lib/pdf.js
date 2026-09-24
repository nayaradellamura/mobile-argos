const fs = require("fs");
const path = require("path");
const Handlebars = require("handlebars");
const puppeteer = require("puppeteer");

const TEMPLATE_PATH = path.join(__dirname, "..", "templates", "laudo.html");
const LOGO_PATH = path.join(__dirname, "..", "assets", "argos_icon.png");

const SEVERITY_COLORS = {
  "pequena monta": "#2e9e5b",
  "média monta": "#d97706",
  "media monta": "#d97706",
  "grande monta": "#d9364a",
};

Handlebars.registerHelper("severityColor", (classificacao) => {
  const key = String(classificacao || "").toLowerCase().trim();
  return SEVERITY_COLORS[key] || "#667685";
});

Handlebars.registerHelper("eq", (a, b) => a === b);

let cachedTemplate = null;
let cachedLogoDataUri = null;

function getTemplate() {
  if (!cachedTemplate) {
    const source = fs.readFileSync(TEMPLATE_PATH, "utf8");
    cachedTemplate = Handlebars.compile(source);
  }
  return cachedTemplate;
}

function getLogoDataUri() {
  if (!cachedLogoDataUri) {
    const bytes = fs.readFileSync(LOGO_PATH);
    cachedLogoDataUri = `data:image/png;base64,${bytes.toString("base64")}`;
  }
  return cachedLogoDataUri;
}

/**
 * Renderiza o HTML (contexto da vistoria + achados do Gemini) e converte pra
 * PDF via Chromium headless. Retorna um Buffer pronto pra subir no Storage.
 */
async function renderLaudoPdf({ context, achados }) {
  const template = getTemplate();

  const html = template({
    ...context,
    ...achados,
    dataEmissao: new Date().toLocaleString("pt-BR", {
      timeZone: "America/Sao_Paulo",
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }),
    logoDataUri: getLogoDataUri(),
  });

  const browser = await puppeteer.launch({
    headless: true,
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || undefined,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
  });

  try {
    const page = await browser.newPage();
    await page.setContent(html, { waitUntil: "networkidle0", timeout: 60_000 });

    // Margem só na faixa do cabeçalho (espaço pra numeração de página) — o
    // resto do espaçamento visual (esquerda/direita/rodapé) fica por conta
    // do padding do .page no próprio HTML, não da margem do PDF.
    const pdfBuffer = await page.pdf({
      format: "A4",
      printBackground: true,
      margin: { top: "1cm", bottom: "0", left: "0", right: "0" },
      displayHeaderFooter: true,
      headerTemplate: `
        <div style="width:100%; font-family:Arial,Helvetica,sans-serif; font-size:9px; color:#8a97a3; padding:0 40px; box-sizing:border-box; display:flex; justify-content:flex-end;">
          <span class="pageNumber"></span>
        </div>
      `,
      footerTemplate: `<div></div>`,
    });

    return pdfBuffer;
  } finally {
    await browser.close();
  }
}

module.exports = { renderLaudoPdf };

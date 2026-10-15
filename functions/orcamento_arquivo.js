// Leitura de orçamento pronto (foto, print, PDF, planilha ou CSV) com o
// Gemini — usado pelo botão "Importar orçamento" da tabela de orçamento do
// app. É um atalho opcional: os itens voltam para a tabela e o mecânico
// confere e corrige antes de salvar; nada é gravado como orçamento aqui.
//
// Imagem e PDF vão direto para o Gemini (ele lê os dois). CSV vai como
// texto. XLSX é convertido em texto (uma linha por linha da planilha) antes,
// porque o Gemini não lê o formato do Excel.

const ExcelJS = require("exceljs");

const TIPOS_SERVICO = ["funilaria", "pintura", "mecanica", "eletrica"];
const MAX_BYTES = 15 * 1024 * 1024;
const MAX_LINHAS_PLANILHA = 400;

const MIME_IMAGEM = new Set(["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"]);
const MIME_PDF = "application/pdf";
const MIME_CSV = new Set(["text/csv", "text/plain", "application/csv", "text/comma-separated-values"]);
const MIME_XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

const PROMPT = `
Você recebe um orçamento de reparo de veículo feito por uma oficina (foto,
print, PDF ou planilha). Transcreva os itens.

Regras:
- Um item por peça ou serviço. Não invente item, valor nem quantidade que
  não esteja no documento.
- valorPeca: valor UNITÁRIO da peça em reais, número sem "R$" (ex.: 550.0).
  Se só houver o total da linha e a quantidade, divida. Serviço sem peça
  (ex.: alinhamento, pintura) tem valorPeca 0.
- Mão de obra: se vier em horas (ex.: "2,0 h", "1,5h", "1h30", coluna
  "MO (h)"), preencha horasMaoObra (1h30 = 1.5) e deixe valorMaoObra null.
  Se vier em reais (ex.: "R$ 420,00"), preencha valorMaoObra e deixe
  horasMaoObra null. Sem mão de obra no item: os dois null.
- Números no formato brasileiro: vírgula é decimal e ponto é milhar
  ("1.234,50" = 1234.5).
- tipoServico: um de funilaria, pintura, mecanica, eletrica.
- tipoIntervencao: "substituicao", "reparo" ou "pintura".
- legivel: false se o documento não for um orçamento ou estiver ilegível.
- totalDocumento: o total geral do documento, se houver.
`.trim();

const SCHEMA = {
  type: "object",
  properties: {
    legivel: { type: "boolean" },
    itens: {
      type: "array",
      items: {
        type: "object",
        properties: {
          peca: { type: "string" },
          tipoIntervencao: { type: "string" },
          quantidade: { type: "number" },
          valorPeca: { type: "number" },
          horasMaoObra: { type: "number", nullable: true },
          valorMaoObra: { type: "number", nullable: true },
          tipoServico: { type: "string" },
        },
        required: ["peca", "quantidade", "valorPeca", "tipoServico"],
      },
    },
    totalDocumento: { type: "number", nullable: true },
  },
  required: ["legivel", "itens"],
};

function tipoDoArquivo(mimeType, nomeArquivo) {
  const mime = String(mimeType || "").toLowerCase();
  const ext = String(nomeArquivo || "").toLowerCase().split(".").pop();

  if (MIME_IMAGEM.has(mime) || ["jpg", "jpeg", "png", "webp", "heic"].includes(ext)) {
    return "imagem";
  }
  if (mime === MIME_PDF || ext === "pdf") return "pdf";
  if (mime === MIME_XLSX || ext === "xlsx") return "xlsx";
  if (MIME_CSV.has(mime) || ext === "csv" || ext === "txt") return "csv";
  if (ext === "xls") return "xls";
  return null;
}

function numero(valor) {
  if (valor === null || valor === undefined || typeof valor === "boolean") return null;
  const n = Number(valor);
  return Number.isFinite(n) ? n : null;
}

function normalizarTipo(tipo) {
  const t = String(tipo || "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");
  return TIPOS_SERVICO.includes(t) ? t : "funilaria";
}

function normalizarIntervencao(tipo) {
  const t = String(tipo || "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");
  if (t.startsWith("rep")) return "reparo";
  if (t.startsWith("pint")) return "pintura";
  return "substituicao";
}

// Limpa o que o Gemini devolveu. Valor absurdo vira 0/null: o mecânico
// corrige na tabela.
function normalizarItens(bruto) {
  const itens = [];
  for (const item of (bruto && Array.isArray(bruto.itens) ? bruto.itens : [])) {
    if (!item || typeof item !== "object") continue;
    const peca = String(item.peca || "").trim();
    if (!peca) continue;

    const quantidade = Math.max(1, Math.round(numero(item.quantidade) || 1));
    let valorPeca = numero(item.valorPeca) || 0;
    if (valorPeca < 0 || valorPeca >= 1e6) valorPeca = 0;

    let horas = numero(item.horasMaoObra);
    if (horas !== null && (horas < 0 || horas >= 1000)) horas = null;

    let valorMaoObra = numero(item.valorMaoObra);
    if (valorMaoObra !== null && (valorMaoObra < 0 || valorMaoObra >= 1e6)) valorMaoObra = null;

    itens.push({
      peca: peca.slice(0, 120),
      tipoIntervencao: normalizarIntervencao(item.tipoIntervencao),
      quantidade,
      valorPeca: Math.round(valorPeca * 100) / 100,
      horasMaoObra: horas,
      valorMaoObra,
      tipoServico: normalizarTipo(item.tipoServico),
    });
  }
  return itens.slice(0, 200);
}

function celulaTexto(valor) {
  if (valor === null || valor === undefined) return "";
  if (typeof valor === "object") {
    if (valor.result !== undefined) return celulaTexto(valor.result);
    if (valor.text !== undefined) return String(valor.text);
    if (Array.isArray(valor.richText)) return valor.richText.map((r) => r.text).join("");
    if (valor instanceof Date) return valor.toISOString().slice(0, 10);
  }
  return String(valor).replace(/[\r\n;]+/g, " ").trim();
}

// XLSX -> texto "a;b;c" por linha, todas as abas, com teto de linhas.
async function planilhaParaTexto(buffer) {
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(buffer);

  const blocos = [];
  let total = 0;
  workbook.eachSheet((sheet) => {
    const linhas = [];
    sheet.eachRow({ includeEmpty: false }, (row) => {
      if (total >= MAX_LINHAS_PLANILHA) return;
      const valores = Array.isArray(row.values) ? row.values.slice(1) : [];
      const linha = valores.map(celulaTexto).join(";").replace(/;+$/, "");
      if (linha.replace(/;/g, "").trim()) {
        linhas.push(linha);
        total += 1;
      }
    });
    if (linhas.length) blocos.push(`# Aba: ${sheet.name}\n${linhas.join("\n")}`);
  });
  return blocos.join("\n\n");
}

async function montarParte(tipo, buffer, mimeType) {
  if (tipo === "imagem") {
    return { inlineData: { mimeType: mimeType || "image/jpeg", data: buffer.toString("base64") } };
  }
  if (tipo === "pdf") {
    return { inlineData: { mimeType: MIME_PDF, data: buffer.toString("base64") } };
  }
  if (tipo === "csv") {
    return { text: `Conteúdo do arquivo CSV:\n${buffer.toString("utf8").slice(0, 200000)}` };
  }
  if (tipo === "xlsx") {
    return { text: `Conteúdo da planilha (colunas separadas por ;):\n${await planilhaParaTexto(buffer)}` };
  }
  throw new Error(`tipo de arquivo não suportado: ${tipo}`);
}

async function extrairOrcamento({ client, model, tipo, buffer, mimeType }) {
  const parte = await montarParte(tipo, buffer, mimeType);
  const result = await client.models.generateContent({
    model,
    contents: [{ role: "user", parts: [parte, { text: PROMPT }] }],
    config: {
      temperature: 0,
      maxOutputTokens: 8192,
      responseMimeType: "application/json",
      responseSchema: SCHEMA,
    },
  });

  const texto = typeof result.text === "string" ? result.text : "";
  const bruto = JSON.parse(texto || "{}");
  const itens = normalizarItens(bruto);

  return {
    itens,
    legivel: Boolean(bruto.legivel) && itens.length > 0,
    totalDocumento: numero(bruto.totalDocumento),
  };
}

module.exports = {
  MAX_BYTES,
  tipoDoArquivo,
  normalizarItens,
  planilhaParaTexto,
  montarParte,
  extrairOrcamento,
};

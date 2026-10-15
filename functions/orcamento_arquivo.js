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
print, manuscrito, PDF ou planilha). Transcreva os itens.

Regras:
- Um item por peça. Não invente item, valor nem quantidade que não esteja
  no documento.
- valorPeca: valor UNITÁRIO da peça em reais, número sem "R$" (ex.: 550.0).
  Se só houver o total da linha e a quantidade, divida.
- Números no formato brasileiro: vírgula é decimal e ponto é milhar
  ("1.234,50" = 1234.5).

Mão de obra (leia com atenção, ela costuma vir separada das peças):
- Muitos orçamentos têm a mão de obra em outra tabela ou seção ("Mão de
  obra mecânica", "Serviços", "M.O."), com tempo, valor da hora e valor
  total por serviço. Associe cada serviço à peça correspondente pela
  descrição ("Substituir amortecedor" -> peça "Amortecedor dianteiro") e
  preencha no item da peça:
  - horasMaoObra: o tempo ("1h" = 1, "0,5h" = 0.5, "1h30" = 1.5);
  - valorHora: o valor da hora informado para esse serviço;
  - valorMaoObra: o valor total da mão de obra desse serviço.
  Se o mesmo serviço tiver tempo E valor, preencha os três.
- Serviço sem peça correspondente (ex.: pintura, alinhamento, funilaria
  geral) vira um item próprio com valorPeca 0 e a mão de obra dele.
- Mão de obra informada só como um valor total para o orçamento inteiro
  (ex.: "Mão de obra: 700,00") vira UM item com peca "Mão de obra" (ou a
  descrição do serviço, se houver), valorPeca 0 e valorMaoObra = esse valor.
- Sem informação de mão de obra: horasMaoObra, valorHora e valorMaoObra
  null.

- tipoServico: um de funilaria, pintura, mecanica, eletrica (o tipo da mão
  de obra do item; use a seção do documento quando houver, ex.: "Mão de
  obra elétrica" -> eletrica).
- tipoIntervencao: "substituicao", "reparo" ou "pintura".
- legivel: false se o documento não for um orçamento ou estiver ilegível.
- totalDocumento: o total final a pagar do documento (depois de descontos),
  se houver.
- observacao: descontos, taxas ou qualquer coisa que o mecânico precise
  conferir, em uma frase; senão null.
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
          valorHora: { type: "number", nullable: true },
          valorMaoObra: { type: "number", nullable: true },
          tipoServico: { type: "string" },
        },
        required: ["peca", "quantidade", "valorPeca", "tipoServico"],
      },
    },
    totalDocumento: { type: "number", nullable: true },
    observacao: { type: "string", nullable: true },
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

    let valorHora = numero(item.valorHora);
    if (valorHora !== null && (valorHora <= 0 || valorHora >= 1e5)) valorHora = null;
    // Dois dos três (tempo, valor da hora, valor total) bastam: deduz o
    // terceiro, para a tabela calcular horas x valor da hora.
    if (valorHora === null && horas && valorMaoObra) {
      valorHora = Math.round((valorMaoObra / horas) * 100) / 100;
    }
    if (horas === null && valorHora && valorMaoObra) {
      horas = Math.round((valorMaoObra / valorHora) * 100) / 100;
    }

    itens.push({
      peca: peca.slice(0, 120),
      tipoIntervencao: normalizarIntervencao(item.tipoIntervencao),
      quantidade,
      valorPeca: Math.round(valorPeca * 100) / 100,
      horasMaoObra: horas,
      valorHora,
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

  const observacao = String(bruto.observacao || "").trim();

  return {
    itens,
    legivel: Boolean(bruto.legivel) && itens.length > 0,
    totalDocumento: numero(bruto.totalDocumento),
    observacao: observacao ? observacao.slice(0, 300) : null,
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

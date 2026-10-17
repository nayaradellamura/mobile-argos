// Testes de lib de leitura de orçamento por arquivo (orcamento_arquivo.js).
// Rodar: `npm test` dentro de functions/. O Gemini é substituído por um dublê.
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const ExcelJS = require("exceljs");

const {
  tipoDoArquivo,
  normalizarItens,
  planilhaParaTexto,
  montarParte,
  extrairOrcamento,
} = require("../orcamento_arquivo");

describe("tipoDoArquivo", () => {
  test("reconhece pelo mime ou pela extensão", () => {
    assert.equal(tipoDoArquivo("image/jpeg", "x.jpg"), "imagem");
    assert.equal(tipoDoArquivo("", "foto.PNG"), "imagem");
    assert.equal(tipoDoArquivo("application/pdf", ""), "pdf");
    assert.equal(tipoDoArquivo("", "orc.pdf"), "pdf");
    assert.equal(tipoDoArquivo("application/octet-stream", "orc.xlsx"), "xlsx");
    assert.equal(tipoDoArquivo("text/csv", ""), "csv");
    assert.equal(tipoDoArquivo("", "orc.csv"), "csv");
    assert.equal(tipoDoArquivo("", "antigo.xls"), "xls");
    assert.equal(tipoDoArquivo("application/zip", "x.zip"), null);
  });
});

describe("normalizarItens", () => {
  test("limpa tipos e valores", () => {
    const itens = normalizarItens({
      itens: [
        { peca: " Farol ", quantidade: 0, valorPeca: "890", horasMaoObra: 0.5, tipoServico: "Elétrica", tipoIntervencao: "Troca" },
        { peca: "", valorPeca: 10 },
        { peca: "Pintura", quantidade: 1, valorPeca: -3, valorMaoObra: 350, tipoServico: "lataria", tipoIntervencao: "Pintura" },
      ],
    });
    assert.equal(itens.length, 2);
    assert.deepEqual(itens[0], {
      peca: "Farol",
      tipoIntervencao: "substituicao",
      quantidade: 1,
      valorPeca: 890,
      horasMaoObra: 0.5,
      valorHora: null,
      valorMaoObra: null,
      tipoServico: "eletrica",
    });
    assert.equal(itens[1].valorPeca, 0);
    assert.equal(itens[1].valorMaoObra, 350);
    assert.equal(itens[1].tipoServico, "funilaria");
    assert.equal(itens[1].tipoIntervencao, "pintura");
  });

  test("deduz horas ou valor da hora a partir dos outros dois", () => {
    const [semHoras, semValorHora] = normalizarItens({
      itens: [
        { peca: "Amortecedor", quantidade: 2, valorPeca: 387.53, valorHora: 36.96, valorMaoObra: 36.96, tipoServico: "mecanica" },
        { peca: "Filtro", quantidade: 1, valorPeca: 61.66, horasMaoObra: 0.5, valorMaoObra: 18.48, tipoServico: "mecanica" },
      ],
    });
    assert.equal(semHoras.horasMaoObra, 1);
    assert.equal(semValorHora.valorHora, 36.96);
  });

  test("entrada vazia", () => {
    assert.deepEqual(normalizarItens(null), []);
    assert.deepEqual(normalizarItens({}), []);
  });
});

async function xlsxDeTeste() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet("Orçamento");
  ws.addRow(["Qtd", "Peça", "Unitário", "Horas"]);
  ws.addRow([1, "Para-choque dianteiro", 620, 1.5]);
  ws.addRow([2, "Suporte do para-choque", 45, null]);
  ws.addRow([]);
  ws.addRow(["", "TOTAL", { formula: "C2+C3*2", result: 710 }]);
  return Buffer.from(await wb.xlsx.writeBuffer());
}

describe("planilhaParaTexto", () => {
  test("converte linhas e fórmulas, pula linha vazia", async () => {
    const texto = await planilhaParaTexto(await xlsxDeTeste());
    const linhas = texto.split("\n");
    assert.equal(linhas[0], "# Aba: Orçamento");
    assert.equal(linhas[1], "Qtd;Peça;Unitário;Horas");
    assert.equal(linhas[2], "1;Para-choque dianteiro;620;1.5");
    assert.equal(linhas[3], "2;Suporte do para-choque;45");
    assert.equal(linhas[4], ";TOTAL;710");
    assert.equal(linhas.length, 5);
  });
});

describe("montarParte", () => {
  test("imagem e pdf vão como inlineData; csv como texto", async () => {
    const buf = Buffer.from("abc");
    assert.equal((await montarParte("imagem", buf, "image/png")).inlineData.mimeType, "image/png");
    assert.equal((await montarParte("pdf", buf)).inlineData.mimeType, "application/pdf");
    assert.match((await montarParte("csv", Buffer.from("a;b"))).text, /a;b/);
  });
});

describe("extrairOrcamento", () => {
  test("usa a resposta estruturada do modelo", async () => {
    let chamada;
    const client = {
      models: {
        generateContent: async (req) => {
          chamada = req;
          return {
            text: JSON.stringify({
              legivel: true,
              itens: [{ peca: "Farol", quantidade: 1, valorPeca: 890, tipoServico: "eletrica" }],
              totalDocumento: 935,
            }),
          };
        },
      },
    };
    const r = await extrairOrcamento({ client, model: "m", tipo: "xlsx", buffer: await xlsxDeTeste() });
    assert.equal(r.legivel, true);
    assert.equal(r.totalDocumento, 935);
    assert.equal(r.itens[0].peca, "Farol");
    assert.equal(chamada.config.responseMimeType, "application/json");
    assert.match(chamada.contents[0].parts[0].text, /Para-choque dianteiro/);
  });

  test("legivel false quando não vem item", async () => {
    const client = { models: { generateContent: async () => ({ text: '{"legivel": true, "itens": []}' }) } };
    const r = await extrairOrcamento({ client, model: "m", tipo: "csv", buffer: Buffer.from("x") });
    assert.equal(r.legivel, false);
  });
});

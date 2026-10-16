// Testes do orçamento no relatório do cliente (lib/data.js): separação de
// peças e serviços, mão de obra em valor total, horas e opções do mecânico.
//
// Rodar: `npm test` (ou `node --test`) dentro de services/laudo-service.
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");

const loadOriginal = Module._load;
Module._load = function (request, ...rest) {
  if (request === "firebase-admin") {
    return { firestore: () => { throw new Error("firebase-admin indisponível nos testes"); } };
  }
  return loadOriginal.call(this, request, ...rest);
};
const {
  buildOrcamentoCampo,
  orcamentoRelatorio,
  opcoesRelatorio,
  nomeLegivel,
  VALIDADE_PADRAO_DIAS,
} = require("../lib/data");
Module._load = loadOriginal;

const item = (peca, extra = {}) => ({
  peca,
  quantidade: 1,
  valorPeca: 0,
  tipoServico: "mecanica",
  horasMaoObra: 0,
  valorHora: 90,
  ...extra,
});

describe("orcamentoRelatorio", () => {
  test("separa peças de serviços e soma a mão de obra em valor total", () => {
    const campo = buildOrcamentoCampo({
      vistoria: {
        orcamentoItensFinais: [
          item("Pastilhas", { valorPeca: 112 }),
          item("Polimento faróis", { horasMaoObra: 1, valorHora: 100, maoObraEmValor: true }),
          item("Mão de obra", { horasMaoObra: 1, valorHora: 300, maoObraEmValor: true }),
        ],
      },
      agentParameters: {},
    });

    const r = orcamentoRelatorio(campo);

    assert.deepEqual(r.pecas.map((p) => p.nome), ["Pastilhas"]);
    assert.deepEqual(r.servicos.map((s) => s.nome), ["Polimento faróis", "Mão de obra"]);
    assert.equal(r.pecasComMaoObra, false);
    assert.equal(r.totalPecas, 112);
    assert.equal(r.totalMaoObra, 400);
    assert.equal(r.total, 512);
    // Mão de obra em valor não mostra "1 h × R$ 300".
    assert.equal(r.servicos[1].detalheHoras, "");
  });

  test("mostra as horas quando a oficina cobra por hora", () => {
    const campo = buildOrcamentoCampo({
      vistoria: {
        orcamentoItensFinais: [item("Para-choque", { valorPeca: 550, horasMaoObra: 1.2, valorHora: 90 })],
      },
      agentParameters: {},
    });

    const r = orcamentoRelatorio(campo);

    assert.equal(r.pecasComMaoObra, true);
    assert.equal(r.pecas[0].detalheHoras, "1,2 h × R$ 90,00");
    assert.equal(r.total, 550 + 108);
  });

  test("agentParameters com mao_obra_em_valor vira serviço sem horas", () => {
    const campo = buildOrcamentoCampo({
      vistoria: {},
      agentParameters: {
        itens_orcamento: [
          { peca: "Mão de obra", valor_peca: 0, horas_mao_obra: 1, valor_hora: 250, mao_obra_em_valor: true },
        ],
      },
    });

    const r = orcamentoRelatorio(campo);

    assert.equal(r.servicos[0].detalheHoras, "");
    assert.equal(r.total, 250);
  });
});

describe("nomeLegivel", () => {
  test("nome todo em maiúsculas vira só a primeira maiúscula", () => {
    assert.equal(nomeLegivel("LAMPADA LANTERNA D"), "Lampada lanterna d");
    assert.equal(nomeLegivel("FLUIDO FREIO DOT 4"), "Fluido freio dot 4");
  });

  test("nome já escrito normalmente fica como está", () => {
    assert.equal(nomeLegivel("Fluido freio DOT 4"), "Fluido freio DOT 4");
    assert.equal(nomeLegivel("ABS"), "ABS");
  });
});

describe("opcoesRelatorio", () => {
  test("sem opções: todas as fotos e validade padrão", () => {
    assert.deepEqual(opcoesRelatorio({}), { fotosExcluidas: [], validadeDias: VALIDADE_PADRAO_DIAS });
  });

  test("lê fotos tiradas e validade escolhidas no app", () => {
    const r = opcoesRelatorio({ relatorioCliente: { fotosExcluidas: ["a.jpg", ""], validadeDias: 30 } });
    assert.deepEqual(r, { fotosExcluidas: ["a.jpg"], validadeDias: 30 });
  });

  test("validade fora de 1-180 dias cai no padrão", () => {
    assert.equal(opcoesRelatorio({ relatorioCliente: { validadeDias: 0 } }).validadeDias, VALIDADE_PADRAO_DIAS);
    assert.equal(opcoesRelatorio({ relatorioCliente: { validadeDias: 999 } }).validadeDias, VALIDADE_PADRAO_DIAS);
  });
});

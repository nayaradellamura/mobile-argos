// Testes de buildOrcamentoCampo (lib/data.js): de onde vem o orçamento de
// campo que vai para o laudo e como o total é recalculado.
//
// Rodar: `npm test` (ou `node --test`) dentro de services/laudo-service.
// Não precisa de `npm install`: o firebase-admin (importado no topo do
// data.js, mas só usado em loadLaudoContext) é substituído por um stub.
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");

// Stub do firebase-admin: intercepta só esse módulo, o resto carrega normal.
const loadOriginal = Module._load;
Module._load = function (request, ...rest) {
  if (request === "firebase-admin") {
    return { firestore: () => { throw new Error("firebase-admin indisponível nos testes"); } };
  }
  return loadOriginal.call(this, request, ...rest);
};
const { buildOrcamentoCampo, normalizarItem, fotosDeDano, dadosRetificacao, VALOR_HORA_LEGADO } = require("../lib/data");
Module._load = loadOriginal;

const itemTabela = (peca, extra = {}) => ({
  peca,
  quantidade: 1,
  valorPeca: 100,
  tipoServico: "funilaria",
  horasMaoObra: 1,
  valorHora: 120,
  ...extra,
});

describe("normalizarItem", () => {
  test("recalcula totais a partir dos campos base", () => {
    const item = normalizarItem({
      peca: "  Farol  ",
      quantidade: 2,
      valorPeca: 300,
      tipoServico: "eletrica",
      horasMaoObra: 1.5,
      valorHora: 100,
    });

    assert.deepEqual(item, {
      peca: "Farol",
      quantidade: 2,
      valorPeca: 300,
      valorPecas: 600,
      tipoServico: "eletrica",
      horasMaoObra: 1.5,
      valorHora: 100,
      valorMaoObra: 150,
      valorTotal: 750,
    });
  });

  test("valorHora ausente usa o valor legado (R$ 90)", () => {
    assert.equal(VALOR_HORA_LEGADO, 90);
    const item = normalizarItem({ peca: "Capô", valorPeca: 0, horasMaoObra: 2 });
    assert.equal(item.valorHora, 90);
    assert.equal(item.valorMaoObra, 180);
    assert.equal(item.valorTotal, 180);
  });

  test("valorHora 0 explícito é respeitado (não cai no legado)", () => {
    const item = normalizarItem({ peca: "X", valorPeca: 10, horasMaoObra: 3, valorHora: 0 });
    assert.equal(item.valorHora, 0);
    assert.equal(item.valorTotal, 10);
  });

  test("quantidade ausente, 0, negativa ou inválida vira 1", () => {
    for (const quantidade of [undefined, null, 0, -2, "abc"]) {
      assert.equal(normalizarItem({ peca: "X", quantidade }).quantidade, 1, `quantidade=${quantidade}`);
    }
    assert.equal(normalizarItem({ peca: "X", quantidade: "3" }).quantidade, 3);
    assert.equal(normalizarItem({ peca: "X", quantidade: 2.6 }).quantidade, 3);
  });

  test("ignora total pronto vindo da fonte (sempre recalcula)", () => {
    const item = normalizarItem({ peca: "X", valorPeca: 50, horasMaoObra: 0, valorTotal: 99999 });
    assert.equal(item.valorTotal, 50);
  });
});

describe("buildOrcamentoCampo — prioridade das fontes", () => {
  const agentParameters = {
    itens_orcamento: [
      { peca: "Do agente", quantidade: 1, valor_peca: 10, tipo_servico: "pintura", horas_mao_obra: 1, valor_hora: 50 },
    ],
  };
  const rascunho = [
    itemTabela("Do rascunho mecânico", { origem: "mecanico" }),
    itemTabela("Do rascunho vistoria", { origem: "vistoria" }),
  ];

  test("1) orcamentoItensFinais tem prioridade sobre todas as outras", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoItensFinais: [itemTabela("Da tabela final")], orcamentoRascunho: rascunho },
      agentParameters,
    });

    assert.deepEqual(campo.itens.map((i) => i.peca), ["Da tabela final"]);
  });

  test("2) sem itens finais, usa só o rascunho com origem 'mecanico'", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoItensFinais: [], orcamentoRascunho: rascunho },
      agentParameters,
    });

    assert.deepEqual(campo.itens.map((i) => i.peca), ["Do rascunho mecânico"]);
  });

  test("3) sem tabela nem rascunho do mecânico, cai em agentParameters (snake_case)", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoRascunho: [itemTabela("Só vistoria", { origem: "vistoria" })] },
      agentParameters,
    });

    assert.equal(campo.itens.length, 1);
    assert.deepEqual(campo.itens[0], {
      peca: "Do agente",
      quantidade: 1,
      valorPeca: 10,
      valorPecas: 10,
      tipoServico: "pintura",
      horasMaoObra: 1,
      valorHora: 50,
      valorMaoObra: 50,
      valorTotal: 60,
    });
  });

  test("itens finais inválidos (sem peça) liberam a próxima fonte", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoItensFinais: [{ peca: "" }, null, "lixo"], orcamentoRascunho: rascunho },
      agentParameters,
    });

    assert.deepEqual(campo.itens.map((i) => i.peca), ["Do rascunho mecânico"]);
  });

  test("nenhuma fonte: orçamento vazio com totais zerados", () => {
    const campo = buildOrcamentoCampo({ vistoria: {}, agentParameters: {} });
    assert.deepEqual(campo, { itens: [], valorPecas: 0, valorMaoObra: 0, valorTotal: 0 });
  });
});

describe("buildOrcamentoCampo — itens e totais", () => {
  test("peças duplicadas são mantidas (ex.: dois faróis em linhas separadas)", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoItensFinais: [itemTabela("Farol"), itemTabela("Farol")] },
      agentParameters: {},
    });

    assert.equal(campo.itens.length, 2);
    assert.equal(campo.valorTotal, 2 * (100 + 120));
  });

  test("quantidade multiplica só a peça, não a mão de obra", () => {
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoItensFinais: [itemTabela("Pneu", { quantidade: 4, valorPeca: 500, horasMaoObra: 1, valorHora: 80 })] },
      agentParameters: {},
    });

    assert.equal(campo.valorPecas, 2000);
    assert.equal(campo.valorMaoObra, 80);
    assert.equal(campo.valorTotal, 2080);
  });

  test("item legado sem valorHora usa R$ 90 junto com itens novos", () => {
    const legado = { peca: "Para-lama", quantidade: 1, valorPeca: 200, horasMaoObra: 2 };
    const campo = buildOrcamentoCampo({
      vistoria: { orcamentoRascunho: [{ ...legado, origem: "mecanico" }, itemTabela("Porta", { origem: "mecanico" })] },
      agentParameters: {},
    });

    assert.equal(campo.itens[0].valorHora, 90);
    assert.equal(campo.itens[1].valorHora, 120);
    assert.equal(campo.valorPecas, 200 + 100);
    assert.equal(campo.valorMaoObra, 2 * 90 + 1 * 120);
    assert.equal(campo.valorTotal, campo.valorPecas + campo.valorMaoObra);
  });

  test("agentParameters legado sem valor_hora também usa R$ 90", () => {
    const campo = buildOrcamentoCampo({
      vistoria: {},
      agentParameters: { itens_orcamento: [{ peca: "Grade", valor_peca: 150, horas_mao_obra: 1 }] },
    });

    assert.equal(campo.valorTotal, 150 + 90);
  });
});

describe("fotosDeDano", () => {
  test("tira do laudo as fotos de orçamento pronto", () => {
    const vistoria = {
      images: [{ imageId: "a" }, { imageId: "orc" }, { imageId: "b" }],
      imagensOrcamentoIds: ["orc"],
    };
    assert.deepEqual(fotosDeDano(vistoria).map((i) => i.imageId), ["a", "b"]);
  });

  test("sem campo de orçamento, mantém todas", () => {
    assert.equal(fotosDeDano({ images: [{ imageId: "a" }] }).length, 1);
    assert.deepEqual(fotosDeDano({}), []);
  });
});

describe("dadosRetificacao", () => {
  test("só para retificação, com respostas em ordem", () => {
    assert.equal(dadosRetificacao({ tipoVistoria: "ORIGINAL" }), null);

    const r = dadosRetificacao({
      tipoVistoria: "RETIFICACAO",
      vistoriaOrigemId: "VIS-1",
      ajustesNecessarios: "Foto do chassi; hodômetro",
      respostasRetificacao: {
        2: { numero: 2, ajuste: "Hodômetro", status: "nao_aplicavel", resposta: "Já informado." },
        1: { numero: 1, ajuste: "Foto do chassi", status: "resolvido", resposta: "Foto legível." },
      },
    });
    assert.equal(r.vistoriaOrigemId, "VIS-1");
    assert.deepEqual(r.respostas.map((x) => x.numero), [1, 2]);
    assert.equal(r.respostas[0].statusLabel, "Resolvido");
    assert.equal(r.respostas[1].statusLabel, "Não se aplica");
  });
});

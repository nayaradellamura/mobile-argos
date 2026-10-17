// Testes da preparação do texto para fala (fala_argos.js).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { textoParaFala, MAX_CARACTERES } = require("../fala_argos");

test("tira marcação e junta linhas com pausa", () => {
  assert.equal(
    textoParaFala("**Total**: R$1.244,00\n\n1. Farol\n- Para-choque"),
    "Total: R$ 1.244,00. 1. Farol. Para-choque"
  );
});

test("limita o tamanho e trata vazio", () => {
  assert.equal(textoParaFala("a".repeat(MAX_CARACTERES + 50)).length, MAX_CARACTERES);
  assert.equal(textoParaFala(null), "");
});

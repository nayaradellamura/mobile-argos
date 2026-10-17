"""Testes unitários das tools determinísticas de preço/orçamento
(`orcamento_team/tools/precos_tool.py`).

O Firestore é sempre mockado (patch de `_client`), então os testes rodam sem
credenciais, sem emulador e sem Gemini.

Rodar (de dentro de adk_agents/):
    .venv/Scripts/python.exe -m unittest discover -s tests -t . -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from orcamento_team.tools import precos_tool
from orcamento_team.tools.precos_tool import (
    _categoria_por_modelo,
    calcular_orcamento_total,
    consultar_preco_referencia,
    verificar_faixa_preco,
)


def _firestore_fake(tabela: dict[tuple[str, str], dict]) -> MagicMock:
    """Cliente Firestore falso: `tabela[(categoria, peca)]` vira o documento
    `tabelaPrecos/{categoria}/pecas/{peca}`; o resto não existe."""
    db = MagicMock()

    def documento(categoria: str, peca: str) -> MagicMock:
        snap = MagicMock()
        dados = tabela.get((categoria, peca))
        snap.exists = dados is not None
        snap.to_dict.return_value = dados
        ref = MagicMock()
        ref.get.return_value = snap
        return ref

    def colecao_raiz(nome: str) -> MagicMock:
        assert nome == "tabelaPrecos"
        raiz = MagicMock()

        def doc_categoria(categoria: str) -> MagicMock:
            cat = MagicMock()

            def colecao_pecas(sub: str) -> MagicMock:
                assert sub == "pecas"
                pecas = MagicMock()
                pecas.document.side_effect = lambda peca: documento(categoria, peca)
                return pecas

            cat.collection.side_effect = colecao_pecas
            return cat

        raiz.document.side_effect = doc_categoria
        return raiz

    db.collection.side_effect = colecao_raiz
    return db


class CalcularOrcamentoTotalTest(unittest.TestCase):
    def test_soma_pecas_vezes_quantidade_mais_mao_de_obra(self):
        resultado = calcular_orcamento_total(
            [
                {"peca": "Farol", "quantidade": 2, "valor_peca": 400, "horas_mao_obra": 1, "valor_hora": 120},
                {"peca": "Capô", "quantidade": 1, "valor_peca": 900, "horas_mao_obra": 2.5, "valor_hora": 100},
            ]
        )

        self.assertEqual(resultado["valor_total_pecas"], 800 + 900)
        self.assertEqual(resultado["valor_total_mao_obra"], 120 + 250)
        self.assertEqual(resultado["valor_total_final"], 1700 + 370)
        self.assertEqual(len(resultado["detalhamento"]), 2)
        self.assertEqual(
            resultado["detalhamento"][0],
            {
                "peca": "Farol",
                "quantidade": 2,
                "valor_peca": 800,
                "valor_hora": 120.0,
                "horas_mao_obra": 1.0,
                "valor_mao_obra": 120,
                "valor_item_total": 920,
            },
        )

    def test_quantidade_ausente_ou_zero_vale_1(self):
        for quantidade in (None, 0):
            with self.subTest(quantidade=quantidade):
                resultado = calcular_orcamento_total(
                    [{"peca": "X", "quantidade": quantidade, "valor_peca": 50, "horas_mao_obra": 0, "valor_hora": 100}]
                )
                self.assertEqual(resultado["detalhamento"][0]["quantidade"], 1)
                self.assertEqual(resultado["valor_total_final"], 50)

    def test_quantidade_negativa_vale_1(self):
        resultado = calcular_orcamento_total([{"peca": "X", "quantidade": -3, "valor_peca": 10, "valor_hora": 100}])
        self.assertEqual(resultado["valor_total_pecas"], 10)

    def test_item_legado_sem_valor_hora_usa_90(self):
        resultado = calcular_orcamento_total([{"peca": "Para-lama", "valor_peca": 300, "horas_mao_obra": 2}])

        self.assertEqual(resultado["detalhamento"][0]["valor_hora"], 90.0)
        self.assertEqual(resultado["valor_total_mao_obra"], 180)
        self.assertEqual(resultado["valor_total_final"], 480)

    def test_valor_hora_zero_explicito_nao_cai_no_legado(self):
        resultado = calcular_orcamento_total([{"peca": "X", "valor_peca": 10, "horas_mao_obra": 3, "valor_hora": 0}])
        self.assertEqual(resultado["valor_total_mao_obra"], 0)

    def test_valores_ausentes_valem_zero(self):
        resultado = calcular_orcamento_total([{"peca": "Só mão de obra", "horas_mao_obra": 1, "valor_hora": 150}])
        self.assertEqual(resultado["valor_total_pecas"], 0)
        self.assertEqual(resultado["valor_total_final"], 150)

    def test_arredonda_para_centavos(self):
        resultado = calcular_orcamento_total(
            [{"peca": "X", "quantidade": 3, "valor_peca": 0.1, "horas_mao_obra": 0.333, "valor_hora": 100}]
        )
        self.assertEqual(resultado["valor_total_pecas"], 0.3)
        self.assertEqual(resultado["valor_total_mao_obra"], 33.3)
        self.assertEqual(resultado["valor_total_final"], 33.6)

    def test_lista_vazia(self):
        self.assertEqual(
            calcular_orcamento_total([]),
            {"valor_total_pecas": 0, "valor_total_mao_obra": 0, "valor_total_final": 0, "detalhamento": []},
        )


class CategoriaPorModeloTest(unittest.TestCase):
    def test_categorias(self):
        casos = {
            "Chevrolet Onix": "popular_compacto",
            "VW Up!": "popular_compacto",
            "Toyota Corolla XEi": "medio_suv_compacto",
            "Honda HR-V": "medio_suv_compacto",
            "Toyota Hilux SRV": "suv_grande_picape",
            "Mitsubishi Pajero Sport": "suv_grande_picape",
            "  COROLLA  ": "medio_suv_compacto",
            "": "popular_compacto",
            "Fusca 1975": "popular_compacto",
        }
        for modelo, esperado in casos.items():
            with self.subTest(modelo=modelo):
                self.assertEqual(_categoria_por_modelo(modelo), esperado)


class ConsultarPrecoReferenciaTest(unittest.TestCase):
    def setUp(self):
        self.db = _firestore_fake(
            {
                ("medio_suv_compacto", "farol"): {"valorPeca": 1200.0, "horasMaoObra": 0.6},
                ("popular_compacto", "porta dianteira"): {"valorPeca": 0, "horasMaoObra": 2.0},
            }
        )
        patcher = patch.object(precos_tool, "_client", return_value=self.db)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_usa_tabela_da_categoria_do_modelo(self):
        resultado = consultar_preco_referencia("  Farol ", "Toyota Corolla")

        self.assertEqual(
            resultado,
            {
                "peca": "  Farol ",
                "valor_peca_sugerido": 1200.0,
                "horas_mao_obra_sugeridas": 0.6,
                "fonte": "tabela_referencia",
            },
        )
        self.db.collection.assert_called_once_with("tabelaPrecos")

    def test_sem_documento_usa_fallback_mvp(self):
        resultado = consultar_preco_referencia("Farol direito", "Chevrolet Onix")

        self.assertEqual(resultado["fonte"], "fallback_mvp")
        self.assertEqual(resultado["valor_peca_sugerido"], 550.0)
        self.assertEqual(resultado["horas_mao_obra_sugeridas"], 0.4)

    def test_sem_referencia_nenhuma(self):
        resultado = consultar_preco_referencia("Antena", "Chevrolet Onix")

        self.assertEqual(resultado["fonte"], "sem_referencia")
        self.assertIsNone(resultado["valor_peca_sugerido"])
        self.assertIsNone(resultado["horas_mao_obra_sugeridas"])


class VerificarFaixaPrecoTest(unittest.TestCase):
    def setUp(self):
        db = _firestore_fake(
            {
                ("popular_compacto", "para-choque dianteiro"): {"valorPeca": 500.0, "horasMaoObra": 1.2},
                ("popular_compacto", "porta dianteira"): {"valorPeca": 0, "horasMaoObra": 2.0},
            }
        )
        patcher = patch.object(precos_tool, "_client", return_value=db)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_dentro_da_faixa_ate_20_por_cento(self):
        resultado = verificar_faixa_preco("Para-choque dianteiro", 600.0, "Fiat Argo")

        self.assertTrue(resultado["dentro_da_faixa"])
        self.assertEqual(resultado["valor_esperado"], 500.0)
        self.assertEqual(resultado["diferenca_percentual"], 20.0)

    def test_acima_de_20_por_cento_fica_fora_da_faixa(self):
        resultado = verificar_faixa_preco("Para-choque dianteiro", 650.0, "Fiat Argo")

        self.assertFalse(resultado["dentro_da_faixa"])
        self.assertEqual(resultado["diferenca_percentual"], 30.0)

    def test_abaixo_da_referencia_e_aceito(self):
        # Só valor ACIMA da referência motiva negociação.
        resultado = verificar_faixa_preco("Para-choque dianteiro", 250.0, "Fiat Argo")

        self.assertTrue(resultado["dentro_da_faixa"])
        self.assertEqual(resultado["diferenca_percentual"], -50.0)

    def test_sem_referencia_nao_bloqueia(self):
        resultado = verificar_faixa_preco("Antena", 9999.0, "Fiat Argo")

        self.assertEqual(
            resultado,
            {"peca": "Antena", "dentro_da_faixa": True, "valor_esperado": None, "diferenca_percentual": None},
        )

    def test_referencia_zero_nao_divide_por_zero(self):
        resultado = verificar_faixa_preco("Porta dianteira", 800.0, "Fiat Argo")

        self.assertTrue(resultado["dentro_da_faixa"])
        self.assertIsNone(resultado["valor_esperado"])

    def test_usa_fallback_quando_nao_ha_documento(self):
        # "paralama" não está no fake -> fallback do MVP (R$ 320).
        resultado = verificar_faixa_preco("Paralama traseiro", 400.0, "Fiat Argo")

        self.assertEqual(resultado["valor_esperado"], 320.0)
        self.assertFalse(resultado["dentro_da_faixa"])  # 25% acima


if __name__ == "__main__":
    unittest.main()

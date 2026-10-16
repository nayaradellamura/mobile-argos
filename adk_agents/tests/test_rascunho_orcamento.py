"""Formato do rascunho de orçamento que a tabela do app lê."""

from __future__ import annotations

import unittest

from common.firestore_tools import _item_rascunho
from orcamento_team.tools.precos_tool import calcular_orcamento_total


class ItemRascunhoTest(unittest.TestCase):
    def test_mao_obra_em_valor_usa_convencao_da_tabela(self):
        item = _item_rascunho(
            {
                "peca": "Mão de obra",
                "valor_peca": 0,
                "horas_mao_obra": 1,
                "valor_hora": 300,
                "mao_obra_em_valor": True,
            }
        )

        self.assertTrue(item["maoObraEmValor"])
        # "mecanico" faria o laudo-service usar só esta linha como orçamento.
        self.assertEqual(item["origem"], "vistoria")
        self.assertEqual(item["horasMaoObra"], 1.0)
        self.assertEqual(item["valorHora"], 300.0)
        self.assertEqual(item["valorMaoObra"], 300.0)

    def test_item_sem_horas_e_valido(self):
        item = _item_rascunho(
            {"peca": "Lâmpada de ré", "valor_peca": 12, "horas_mao_obra": 0}
        )

        self.assertEqual(item["horasMaoObra"], 0.0)
        self.assertNotIn("maoObraEmValor", item)

    def test_total_com_mao_obra_em_valor(self):
        total = calcular_orcamento_total(
            [
                {"peca": "Pastilhas", "valor_peca": 112, "horas_mao_obra": 0},
                {"peca": "Fluido DOT 4", "valor_peca": 35, "horas_mao_obra": 0},
                {
                    "peca": "Mão de obra",
                    "valor_peca": 0,
                    "horas_mao_obra": 1,
                    "valor_hora": 300,
                },
            ]
        )

        self.assertEqual(total["valor_total_final"], 447.0)
        self.assertEqual(total["valor_total_mao_obra"], 300.0)


if __name__ == "__main__":
    unittest.main()

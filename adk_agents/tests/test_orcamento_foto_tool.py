"""Testes da leitura de orçamento por foto
(`orcamento_team/tools/orcamento_foto_tool.py`), com Firestore, download e
Gemini substituídos por dublês.

Rodar (de dentro de adk_agents/):
    .venv/Scripts/python.exe -m unittest discover -s tests -t . -v
"""

from __future__ import annotations

import asyncio
import unittest
from unittest.mock import patch

from orcamento_team.tools import orcamento_foto_tool
from orcamento_team.tools.orcamento_foto_tool import (
    ler_orcamento_das_fotos,
    normalizar_itens,
)


class NormalizarItensTest(unittest.TestCase):
    def test_item_completo(self):
        itens = normalizar_itens(
            {
                "itens": [
                    {
                        "peca": " Para-choque dianteiro ",
                        "tipo_intervencao": "Troca",
                        "quantidade": 1,
                        "valor_peca": 550,
                        "horas_mao_obra": 1.2,
                        "valor_mao_obra": None,
                        "tipo_servico": "funilaria",
                    }
                ]
            }
        )
        self.assertEqual(
            itens,
            [
                {
                    "peca": "Para-choque dianteiro",
                    "tipo_intervencao": "troca",
                    "quantidade": 1,
                    "valor_peca": 550.0,
                    "horas_mao_obra": 1.2,
                    "valor_mao_obra": None,
                    "tipo_servico": "funilaria",
                }
            ],
        )

    def test_descarta_item_sem_peca(self):
        self.assertEqual(normalizar_itens({"itens": [{"peca": " ", "valor_peca": 10}]}), [])

    def test_valores_invalidos_viram_padrao(self):
        (item,) = normalizar_itens(
            {
                "itens": [
                    {
                        "peca": "Farol",
                        "quantidade": 0,
                        "valor_peca": -5,
                        "horas_mao_obra": 5000,
                        "tipo_servico": "Elétrica",
                    }
                ]
            }
        )
        self.assertEqual(item["quantidade"], 1)
        self.assertEqual(item["valor_peca"], 0.0)
        self.assertIsNone(item["horas_mao_obra"])
        self.assertEqual(item["tipo_servico"], "eletrica")

    def test_tipo_desconhecido_vira_funilaria(self):
        (item,) = normalizar_itens(
            {"itens": [{"peca": "Capô", "quantidade": 2.4, "valor_peca": "900", "tipo_servico": "lataria"}]}
        )
        self.assertEqual(item["tipo_servico"], "funilaria")
        self.assertEqual(item["quantidade"], 2)
        self.assertEqual(item["valor_peca"], 900.0)

    def test_entrada_vazia(self):
        self.assertEqual(normalizar_itens({}), [])
        self.assertEqual(normalizar_itens(None), [])


class _Ref:
    def __init__(self, dados):
        self.dados = dados
        self.gravado = None

    def get(self):
        return type("Snap", (), {"to_dict": lambda _self: self.dados})()

    def set(self, dados, merge=False):
        self.gravado = dados


class _Db:
    def __init__(self, ref):
        self.ref = ref

    def collection(self, _nome):
        return self

    def document(self, _id):
        return self.ref


def _rodar(coro):
    return asyncio.run(coro)


class LerOrcamentoDasFotosTest(unittest.TestCase):
    def _vistoria(self):
        return {
            "images": [
                {"imageId": "dano1"},
                {"imageId": "orc1", "contentType": "image/jpeg"},
            ],
            "imagensAnalisadasIds": ["dano1"],
        }

    def test_le_so_fotos_novas_e_marca_como_orcamento(self):
        ref = _Ref(self._vistoria())
        baixadas = []

        async def baixar(img):
            baixadas.append(img["imageId"])
            return b"jpg"

        async def extrair(fotos):
            self.assertEqual(len(fotos), 1)
            return {
                "legivel": True,
                "itens": [{"peca": "Farol", "quantidade": 1, "valor_peca": 600, "tipo_servico": "eletrica"}],
                "total_documento": 650,
            }

        with patch.object(orcamento_foto_tool, "_client", return_value=_Db(ref)), \
             patch.object(orcamento_foto_tool, "_baixar", side_effect=baixar), \
             patch.object(orcamento_foto_tool, "_extrair", side_effect=extrair):
            resultado = _rodar(ler_orcamento_das_fotos("VIS-1"))

        self.assertEqual(baixadas, ["orc1"])
        self.assertTrue(resultado["legivel"])
        self.assertEqual(resultado["fotos_lidas"], 1)
        self.assertEqual(resultado["itens"][0]["peca"], "Farol")
        self.assertEqual(resultado["total_documento"], 650.0)
        self.assertIn("imagensOrcamentoIds", ref.gravado)
        self.assertIn("imagensAnalisadasIds", ref.gravado)
        self.assertEqual(ref.gravado["orcamentoImportado"]["imageIds"], ["orc1"])

    def test_sem_foto_nova_nao_chama_o_modelo(self):
        ref = _Ref({"images": [{"imageId": "a"}], "imagensAnalisadasIds": ["a"]})

        async def extrair(_fotos):
            raise AssertionError("não deveria chamar o modelo")

        with patch.object(orcamento_foto_tool, "_client", return_value=_Db(ref)), \
             patch.object(orcamento_foto_tool, "_extrair", side_effect=extrair):
            resultado = _rodar(ler_orcamento_das_fotos("VIS-1"))

        self.assertEqual(resultado["fotos_lidas"], 0)
        self.assertFalse(resultado["legivel"])
        self.assertIsNone(ref.gravado)

    def test_falha_do_modelo_nao_marca_fotos(self):
        ref = _Ref(self._vistoria())

        async def baixar(_img):
            return b"jpg"

        async def extrair(_fotos):
            raise RuntimeError("modelo fora do ar")

        with patch.object(orcamento_foto_tool, "_client", return_value=_Db(ref)), \
             patch.object(orcamento_foto_tool, "_baixar", side_effect=baixar), \
             patch.object(orcamento_foto_tool, "_extrair", side_effect=extrair):
            resultado = _rodar(ler_orcamento_das_fotos("VIS-1"))

        self.assertIn("erro", resultado)
        self.assertEqual(resultado["itens"], [])
        self.assertIsNone(ref.gravado)

    def test_ilegivel(self):
        ref = _Ref(self._vistoria())

        async def baixar(_img):
            return b"jpg"

        async def extrair(_fotos):
            return {"legivel": False, "itens": []}

        with patch.object(orcamento_foto_tool, "_client", return_value=_Db(ref)), \
             patch.object(orcamento_foto_tool, "_baixar", side_effect=baixar), \
             patch.object(orcamento_foto_tool, "_extrair", side_effect=extrair):
            resultado = _rodar(ler_orcamento_das_fotos("VIS-1"))

        self.assertFalse(resultado["legivel"])
        self.assertEqual(resultado["itens"], [])


if __name__ == "__main__":
    unittest.main()

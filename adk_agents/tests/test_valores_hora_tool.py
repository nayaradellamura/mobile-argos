"""Testes das tools de valor da hora da oficina
(`orcamento_team/tools/valores_hora_tool.py`), com Firestore em memória.

Rodar (de dentro de adk_agents/):
    .venv/Scripts/python.exe -m unittest discover -s tests -t . -v
"""

from __future__ import annotations

import unittest
from unittest.mock import patch

from orcamento_team.tools import valores_hora_tool
from orcamento_team.tools.valores_hora_tool import (
    carregar_valores_hora_oficina,
    salvar_valor_hora_oficina,
)


class _Snap:
    def __init__(self, dados):
        self._dados = dados

    def to_dict(self):
        return self._dados


class _Doc:
    def __init__(self, banco, colecao, doc_id):
        self._banco, self._colecao, self._id = banco, colecao, doc_id

    def get(self):
        return _Snap(self._banco.dados.get(self._colecao, {}).get(self._id))

    def set(self, valores, merge=False):
        self._banco.escritas.append((self._colecao, self._id, valores, merge))


class _Colecao:
    def __init__(self, banco, nome):
        self._banco, self._nome = banco, nome

    def document(self, doc_id):
        return _Doc(self._banco, self._nome, doc_id)


class _Banco:
    def __init__(self, dados):
        self.dados = dados
        self.escritas = []

    def collection(self, nome):
        return _Colecao(self, nome)


def _banco(credenciado=None, sinistro_credenciado="oficina-1", vistoria_credenciado=""):
    return _Banco({
        "vistorias": {"VIS-1": {"sinistroId": "SIN-1", "credenciadoId": vistoria_credenciado}},
        "sinistro": {"SIN-1": {"credenciadoId": sinistro_credenciado}},
        "credenciados": {"oficina-1": credenciado} if credenciado is not None else {},
    })


class CarregarValoresHoraTest(unittest.TestCase):
    def test_devolve_so_tipos_configurados(self):
        banco = _banco({"valoresHoraMaoObra": {"funilaria": 120, "pintura": "150,50", "mecanica": 0}})
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = carregar_valores_hora_oficina("VIS-1")

        self.assertTrue(resultado["oficina_encontrada"])
        self.assertEqual(resultado["valores"], {"funilaria": 120.0, "pintura": 150.5})
        self.assertEqual(resultado["tipos_sem_valor"], ["mecanica", "eletrica"])

    def test_oficina_sem_configuracao(self):
        banco = _banco({})
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = carregar_valores_hora_oficina("VIS-1")

        self.assertEqual(resultado["valores"], {})
        self.assertEqual(len(resultado["tipos_sem_valor"]), 4)

    def test_sem_oficina_vinculada(self):
        banco = _banco(None, sinistro_credenciado="", vistoria_credenciado="")
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = carregar_valores_hora_oficina("VIS-1")

        self.assertFalse(resultado["oficina_encontrada"])

    def test_usa_oficina_da_vistoria_quando_sinistro_nao_tem(self):
        banco = _banco({"valoresHoraMaoObra": {"eletrica": 100}}, sinistro_credenciado="",
                       vistoria_credenciado="oficina-1")
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = carregar_valores_hora_oficina("VIS-1")

        self.assertEqual(resultado["valores"], {"eletrica": 100.0})


class SalvarValorHoraTest(unittest.TestCase):
    def test_grava_merge_so_do_tipo_informado(self):
        banco = _banco({})
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = salvar_valor_hora_oficina("VIS-1", "Funilaria", "120,00")

        self.assertEqual(resultado, {"salvo": True, "tipo_servico": "funilaria", "valor_hora": 120.0})
        colecao, doc_id, valores, merge = banco.escritas[0]
        self.assertEqual((colecao, doc_id, merge), ("credenciados", "oficina-1", True))
        self.assertEqual(valores["valoresHoraMaoObra"], {"funilaria": 120.0})

    def test_rejeita_tipo_invalido(self):
        banco = _banco({})
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = salvar_valor_hora_oficina("VIS-1", "borracharia", 80)

        self.assertFalse(resultado["salvo"])
        self.assertEqual(banco.escritas, [])

    def test_rejeita_valor_zero_ou_invalido(self):
        banco = _banco({})
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            for valor in (0, -10, "abc", None):
                self.assertFalse(salvar_valor_hora_oficina("VIS-1", "pintura", valor)["salvo"])

        self.assertEqual(banco.escritas, [])

    def test_sem_oficina_nao_grava(self):
        banco = _banco(None, sinistro_credenciado="", vistoria_credenciado="")
        with patch.object(valores_hora_tool, "_client", return_value=banco):
            resultado = salvar_valor_hora_oficina("VIS-1", "pintura", 150)

        self.assertFalse(resultado["salvo"])
        self.assertEqual(banco.escritas, [])


if __name__ == "__main__":
    unittest.main()

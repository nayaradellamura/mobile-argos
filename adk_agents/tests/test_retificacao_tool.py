"""Testes das tools da retificação (`vistoria_team/tools/retificacao_tool.py`),
com um Firestore em memória.

Rodar (de dentro de adk_agents/):
    .venv/Scripts/python.exe -m unittest discover -s tests -t . -v
"""

from __future__ import annotations

import copy
import unittest
from unittest.mock import patch

from google.cloud import firestore

from vistoria_team.tools import retificacao_tool
from vistoria_team.tools.retificacao_tool import (
    carregar_contexto_retificacao,
    registrar_resposta_ajuste,
)


def _valores(union):
    return list(getattr(union, "values", None) or getattr(union, "_values", []))


def _merge(destino: dict, origem: dict) -> None:
    for chave, valor in origem.items():
        if isinstance(valor, firestore.ArrayUnion):
            atual = destino.setdefault(chave, [])
            for item in _valores(valor):
                if item not in atual:
                    atual.append(item)
        elif isinstance(valor, dict) and isinstance(destino.get(chave), dict):
            _merge(destino[chave], valor)
        else:
            destino[chave] = copy.deepcopy(valor)


class _Snap:
    def __init__(self, dados):
        self._dados = dados

    def to_dict(self):
        return copy.deepcopy(self._dados) if self._dados is not None else None


class _Doc:
    def __init__(self, banco, doc_id):
        self.banco, self.doc_id = banco, doc_id

    def get(self):
        return _Snap(self.banco.get(self.doc_id))

    def set(self, dados, merge=False):
        if merge and self.doc_id in self.banco:
            _merge(self.banco[self.doc_id], dados)
        else:
            novo = {}
            _merge(novo, dados)
            self.banco[self.doc_id] = novo


class _Db:
    def __init__(self, vistorias):
        self.vistorias = vistorias

    def collection(self, _nome):
        return self

    def document(self, doc_id):
        return _Doc(self.vistorias, doc_id)


def _banco():
    return {
        "VIS-1": {
            "tipoVistoria": "ORIGINAL",
            "status": "REJEITADA",
            "descricaoArtigos": "Bati a frente num poste.",
            "ajustesNecessarios": "Falta foto do chassi.",
            "motivoRejeicao": "Evidência insuficiente",
            "images": [{"imageId": "f1", "url": "u1"}, {"imageId": "f2", "url": "u2"}],
            "orcamentoItensFinais": [{"peca": "Farol"}],
            "agentParameters": {
                "hodometro": "45320",
                "danos_externos": ["para-choque", "farol"],
                "severidade_geral": "moderado",
                "itens_orcamento": [{"peca": "Farol", "valor_peca": 550, "valor_hora": 90}],
                "valor_total_final": 586,
                "passo_externos": "concluido",
            },
        },
        "VIS-2": {
            "tipoVistoria": "RETIFICACAO",
            "vistoriaOrigemId": "VIS-1",
            "ajustesNecessarios": "Falta foto do chassi.",
            "placa": "ABC1D23",
            "images": [],
            "agentParameters": {"tipo_vistoria": "RETIFICACAO"},
        },
    }


class CarregarContextoRetificacaoTest(unittest.TestCase):
    def setUp(self):
        self.banco = _banco()
        self.patch = patch.object(retificacao_tool, "_client", return_value=_Db(self.banco))
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_herda_dados_da_original(self):
        r = carregar_contexto_retificacao("VIS-2")

        self.assertEqual(r["ajustes_necessarios"], "Falta foto do chassi.")
        self.assertEqual(r["motivo_rejeicao"], "Evidência insuficiente")
        self.assertEqual(r["fotos_herdadas"], 2)
        self.assertEqual(r["orcamento_original"]["valor_total_final"], 586)
        self.assertEqual(r["vistoria_original"]["hodometro"], "45320")

        nova = self.banco["VIS-2"]
        self.assertTrue(nova["retificacaoHerdada"])
        self.assertEqual(nova["agentParameters"]["danos_externos"], ["para-choque", "farol"])
        self.assertNotIn("passo_externos", nova["agentParameters"])
        self.assertEqual(nova["agentParameters"]["tipo_vistoria"], "RETIFICACAO")
        self.assertEqual([i["imageId"] for i in nova["images"]], ["f1", "f2"])
        self.assertEqual(nova["images"][0]["herdadaDe"], "VIS-1")
        # Fotos herdadas não voltam para a fila do analista de visão.
        self.assertEqual(nova["imagensAnalisadasIds"], ["f1", "f2"])
        self.assertEqual(nova["orcamentoItensFinais"], [{"peca": "Farol"}])

    def test_heranca_acontece_uma_vez(self):
        carregar_contexto_retificacao("VIS-2")
        self.banco["VIS-2"]["agentParameters"]["hodometro"] = "45400"
        carregar_contexto_retificacao("VIS-2")

        nova = self.banco["VIS-2"]
        self.assertEqual(len(nova["images"]), 2)
        self.assertEqual(nova["agentParameters"]["hodometro"], "45400")

    def test_nao_sobrescreve_o_que_a_retificacao_ja_tem(self):
        self.banco["VIS-2"]["agentParameters"]["severidade_geral"] = "leve"
        carregar_contexto_retificacao("VIS-2")
        self.assertEqual(self.banco["VIS-2"]["agentParameters"]["severidade_geral"], "leve")

    def test_vistoria_que_nao_e_retificacao(self):
        r = carregar_contexto_retificacao("VIS-1")
        self.assertIn("erro", r)
        self.assertNotIn("retificacaoHerdada", self.banco["VIS-1"])


class RegistrarRespostaAjusteTest(unittest.TestCase):
    def setUp(self):
        self.banco = _banco()
        self.patch = patch.object(retificacao_tool, "_client", return_value=_Db(self.banco))
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_registra_e_substitui_por_numero(self):
        registrar_resposta_ajuste("VIS-2", 1, "Foto do chassi", "pendente", "Foto desfocada.")
        registrar_resposta_ajuste("VIS-2", "1", "Foto do chassi", "Resolvido", "Foto legível enviada.")
        registrar_resposta_ajuste("VIS-2", 2, "Hodômetro", "resolvido", "45.400 km.")

        respostas = self.banco["VIS-2"]["respostasRetificacao"]
        self.assertEqual(respostas["1"]["status"], "resolvido")
        self.assertEqual(respostas["1"]["resposta"], "Foto legível enviada.")
        self.assertEqual(respostas["2"]["numero"], 2)

    def test_status_ou_numero_invalido(self):
        self.assertIn("erro", registrar_resposta_ajuste("VIS-2", 1, "x", "feito", "y"))
        self.assertIn("erro", registrar_resposta_ajuste("VIS-2", "um", "x", "resolvido", "y"))
        self.assertNotIn("respostasRetificacao", self.banco["VIS-2"])


if __name__ == "__main__":
    unittest.main()

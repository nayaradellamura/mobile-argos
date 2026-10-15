"""Popula o EMULADOR do Firestore com as vistorias usadas pelos eval sets
(`orcamento_team/eval/*.test.json` e `vistoria_team/eval/*.test.json`).

Rode antes de cada execução das avaliações: as tools gravam no Firestore
(`salvar_estado_vistoria`, `enviar_laudo_cloud_function`...) e este script
devolve tudo ao estado inicial esperado pelos casos.

Os valores foram escolhidos para os casos serem determinísticos:
- Referência: para-choque R$ 550 + 1,2h e farol R$ 550 + 0,4h.
- Oficina de avaliação com hora a R$ 90 em todos os tipos. Total esperado
  com os valores de referência: R$ 1.244,00 (R$ 2.194,00 com o farol a
  R$ 1.500).
- VIS-EVAL-ORC-0004 pertence a um sinistro de oficina SEM valor da hora,
  para o agente ter de perguntar e salvar.

Uso (de dentro de adk_agents/, com o emulador no ar):
    $env:FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080"
    .venv\\Scripts\\python.exe eval\\seed_eval.py
"""

from __future__ import annotations

import os
import sys

from google.cloud import firestore

SINISTRO = "SIN-EVAL-0001"
SINISTRO_SEM_VALOR_HORA = "SIN-EVAL-0002"
MODELO = "Fiat Argo 2022"

# Referência de preço gravada explicitamente (sobrepõe qualquer seed
# anterior de `scripts/seed_tabela_precos.py` no emulador).
TABELA_PRECOS = {
    "para-choque dianteiro": {"valorPeca": 550.0, "horasMaoObra": 1.2},
    "farol dianteiro direito": {"valorPeca": 550.0, "horasMaoObra": 0.4},
}

AGENT_PARAMETERS_VISTORIA_CONCLUIDA = {
    "hodometro": "45320",
    "dinamica_acidente": "colisão frontal contra poste a cerca de 20 km/h",
    "ponto_impacto": "frontal",
    "danos_externos": ["para-choque dianteiro", "farol dianteiro direito"],
    "danos_estruturais": [],
    "severidade_geral": "moderado",
    "modelo_veiculo": MODELO,
    "vistoria_pronta_para_orcamento": True,
}


def _vistoria_base(id_vistoria: str, **extra) -> dict:
    return {
        "idvistoria": id_vistoria,
        "sinistroId": SINISTRO,
        "status": "EM_ANDAMENTO",
        "tipoVistoria": "ORIGINAL",
        "placa": "ABC1D23",
        "veiculo": MODELO,
        "cliente": "Cliente de Avaliação",
        "credenciado": "Oficina de Avaliação",
        "descricaoArtigos": (
            "Cliente relatou pelo app: bati a frente do carro contra um poste "
            "em baixa velocidade, sem feridos."
        ),
        "observacoes": "",
        "images": [],
        "agentParameters": {},
        **extra,
    }


VISTORIAS = {
    # vistoria_team: vistoria nova, com relato inicial do cliente.
    "VIS-EVAL-VIS-0001": _vistoria_base("VIS-EVAL-VIS-0001"),
    # vistoria_team: retificação pedida pela análise operacional.
    "VIS-EVAL-VIS-0002": _vistoria_base(
        "VIS-EVAL-VIS-0002",
        tipoVistoria="RETIFICACAO",
        ajustesNecessarios=(
            "Faltou a foto da numeração do chassi e uma foto do farol "
            "dianteiro direito mais de perto."
        ),
        contextoVistoriaAnterior=(
            "Colisão frontal contra poste; para-choque dianteiro e farol "
            "dianteiro direito danificados; severidade moderada."
        ),
    ),
    # orcamento_team: vistoria concluída, orçamento montado no chat. Uma
    # vistoria por caso, porque o agente grava o orçamento no documento.
    "VIS-EVAL-ORC-0001": _vistoria_base(
        "VIS-EVAL-ORC-0001",
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
    ),
    "VIS-EVAL-ORC-0002": _vistoria_base(
        "VIS-EVAL-ORC-0002",
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
    ),
    "VIS-EVAL-ORC-0003": _vistoria_base(
        "VIS-EVAL-ORC-0003",
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
    ),
    # orcamento_team: oficina sem valor da hora configurado.
    "VIS-EVAL-ORC-0004": _vistoria_base(
        "VIS-EVAL-ORC-0004",
        sinistroId=SINISTRO_SEM_VALOR_HORA,
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
    ),
}


def main() -> None:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print(
            "FIRESTORE_EMULATOR_HOST não está setado. Este script só roda contra "
            "o emulador, nunca contra o projeto real.",
            file=sys.stderr,
        )
        sys.exit(1)

    db = firestore.Client(project=os.environ.get("GOOGLE_CLOUD_PROJECT", "demo-argos"))

    db.collection("sinistro").document(SINISTRO).set(
        {
            "placa": "ABC1D23",
            "vehicle": MODELO,
            "priority": "media",
            "claimType": "colisao",
            "credenciadoId": "credenciado-avaliacao",
        }
    )

    db.collection("sinistro").document(SINISTRO_SEM_VALOR_HORA).set(
        {
            "placa": "ABC1D23",
            "vehicle": MODELO,
            "priority": "media",
            "claimType": "colisao",
            "credenciadoId": "credenciado-sem-valor-hora",
        }
    )
    # set() sem merge também apaga o valor da hora salvo pela execução
    # anterior do caso "oficina sem valor da hora".
    db.collection("credenciados").document("credenciado-sem-valor-hora").set(
        {"name": "Oficina Sem Valor da Hora"}
    )

    # Valor da hora da oficina já configurado (R$ 90 em todos os tipos), para
    # o agente não parar perguntando e os totais esperados continuarem
    # valendo.
    db.collection("credenciados").document("credenciado-avaliacao").set(
        {
            "name": "Oficina de Avaliação",
            "valoresHoraMaoObra": {
                "funilaria": 90.0,
                "pintura": 90.0,
                "mecanica": 90.0,
                "eletrica": 90.0,
            },
        }
    )

    for peca, dados in TABELA_PRECOS.items():
        (
            db.collection("tabelaPrecos")
            .document("popular_compacto")
            .collection("pecas")
            .document(peca)
            .set(dados)
        )

    # set() sem merge: sobrescreve o que as execuções anteriores gravaram.
    for id_vistoria, dados in VISTORIAS.items():
        db.collection("vistorias").document(id_vistoria).set(dados)

    print(f"Seed de avaliação criado: {', '.join(VISTORIAS)}.")


if __name__ == "__main__":
    main()

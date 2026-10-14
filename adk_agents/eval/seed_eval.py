"""Popula o EMULADOR do Firestore com as vistorias usadas pelos eval sets
(`orcamento_team/eval/*.test.json` e `vistoria_team/eval/*.test.json`).

Rode antes de cada execução das avaliações: as tools gravam no Firestore
(`salvar_estado_vistoria`, `enviar_laudo_cloud_function`...) e este script
devolve tudo ao estado inicial esperado pelos casos.

Os valores foram escolhidos para os casos serem determinísticos:
- VIS-EVAL-ORC-0001: farol R$ 1.500 contra referência de R$ 550 (fora da
  faixa de 20%) e para-choque R$ 580 contra R$ 550 (dentro). Total
  esperado: R$ 2.272,00.
- VIS-EVAL-ORC-0002: tudo dentro da faixa. Total esperado: R$ 1.352,00.

Uso (de dentro de adk_agents/, com o emulador no ar):
    $env:FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080"
    .venv\\Scripts\\python.exe eval\\seed_eval.py
"""

from __future__ import annotations

import os
import sys

from google.cloud import firestore

SINISTRO = "SIN-EVAL-0001"
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


def _item(peca: str, valor_peca: float, horas: float, valor_hora: float = 120.0) -> dict:
    """Item no formato que o app grava em `orcamentoItensFinais`."""
    return {
        "id": f"eval_{peca.replace(' ', '_')}",
        "peca": peca,
        "tipoIntervencao": "substituicao",
        "quantidade": 1,
        "valorPeca": valor_peca,
        "tipoServico": "funilaria",
        "horasMaoObra": horas,
        "valorHora": valor_hora,
        "valorMaoObra": horas * valor_hora,
        "valorTotal": valor_peca + horas * valor_hora,
        "origem": "vistoria",
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
    # orcamento_team: retomada com um item fora da faixa (farol).
    "VIS-EVAL-ORC-0001": _vistoria_base(
        "VIS-EVAL-ORC-0001",
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
        orcamentoItensFinais=[
            _item("para-choque dianteiro", 580.0, 1.2),
            _item("farol dianteiro direito", 1500.0, 0.4),
        ],
    ),
    # orcamento_team: retomada com tudo dentro da faixa.
    "VIS-EVAL-ORC-0002": _vistoria_base(
        "VIS-EVAL-ORC-0002",
        agentParameters=AGENT_PARAMETERS_VISTORIA_CONCLUIDA,
        orcamentoItensFinais=[
            _item("para-choque dianteiro", 560.0, 1.2),
            _item("farol dianteiro direito", 600.0, 0.4),
        ],
    ),
    # orcamento_team: transição vistoria -> orçamento (sem tabela ainda).
    "VIS-EVAL-ORC-0003": _vistoria_base(
        "VIS-EVAL-ORC-0003",
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

    # Valor da hora da oficina já configurado (R$ 90 em todos os tipos), para
    # o agente não parar perguntando e os totais esperados continuarem
    # valendo. Um caso de "oficina sem valor" deve usar outro credenciado.
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

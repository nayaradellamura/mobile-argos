"""Cria uma vistoria de exemplo no emulador do Firestore, só para o
`carregar_contexto_vistoria` ter algo pra carregar durante a simulação
local (sem isso, o agente começaria sem placa/veículo/relato nenhum).

Requer `FIRESTORE_EMULATOR_HOST` já setado no ambiente (o script
`simular_local.ps1` faz isso antes de chamar este arquivo).
"""

from __future__ import annotations

import os
import sys

from google.cloud import firestore

ID_VISTORIA = "VIS-SIMULACAO-0001"
ID_SINISTRO = "SIN-SIMULACAO-0001"


def main() -> None:
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print(
            "FIRESTORE_EMULATOR_HOST não está setado — rode isto através de "
            "simular_local.ps1, ou exporte a variável manualmente antes.",
            file=sys.stderr,
        )
        sys.exit(1)

    db = firestore.Client(project=os.environ.get("GOOGLE_CLOUD_PROJECT", "demo-argos"))

    db.collection("sinistro").document(ID_SINISTRO).set(
        {
            "placa": "ABC1D23",
            "vehicle": "Fiat Argo 2022",
            "priority": "media",
            "claimType": "colisao",
            "credenciadoId": "credenciado-simulacao",
        }
    )

    db.collection("vistorias").document(ID_VISTORIA).set(
        {
            "idvistoria": ID_VISTORIA,
            "sinistroId": ID_SINISTRO,
            "status": "EM_ANDAMENTO",
            "tipoVistoria": "ORIGINAL",
            "placa": "ABC1D23",
            "veiculo": "Fiat Argo 2022",
            "cliente": "Cliente de Teste",
            "credenciado": "Oficina de Simulação",
            "descricaoArtigos": (
                "Cliente relatou pelo app: bati a frente do carro contra um "
                "poste em baixa velocidade, sem feridos."
            ),
            "observacoes": "",
            "images": [],
            "agentParameters": {},
        }
    )

    print(f"Seed criado: vistorias/{ID_VISTORIA} (sinistro {ID_SINISTRO}).")
    print("Use esse id ao chamar as tools no `adk web` (ex.: id_vistoria='VIS-SIMULACAO-0001').")


if __name__ == "__main__":
    main()

"""Seed da coleção `tabelaPrecos`, segmentada por categoria de porte de
veículo (Firestore emulador ou real).

Fecha a pendência descrita em `orcamento_team/README.md`: os valores
anteriores eram um único "modelo genérico" inventado sem embasamento.
Validado com um agente de domínio (persona `especialista-sinistros`) em
2026-09-01: peça de reposição no Brasil varia demais por porte/plataforma
do veículo pra sustentar uma tabela única — segmentar em categorias é
necessário, não só "mais realista". Ver `_categoria_por_modelo` em
`orcamento_team/tools/precos_tool.py` para o mapeamento modelo->categoria.

Ainda são valores estimados pro TCC (não uma tabela de mercado auditada),
mas agora com ordem de grandeza ancorada: para-choque/farol têm faixa de
preço real pesquisada (fontes abaixo); o resto segue proporção de domínio
entre categorias (peça de SUV grande custa tipicamente 2-4x a de um
popular, mão de obra varia bem menos que peça). Fontes consultadas:
- https://autocidade.com/guia/quanto-custa-funilaria (funilaria/pintura, 2026)
- https://acheioprofissional.com.br/blog/tabela-mao-de-obra-mecanica-2026
- https://www.sindifupi.org.br/noticias.asp?t=2385 (pesquisa de mão de obra)
- https://www.facesp.com.br/noticia/cliente-oculto-aponta-custo-real-de-mao-de-obra-em-funilaria
- Anúncios reais de para-choque (Onix, HB20) e farol LED (T-Cross) em
  lojas de autopeças/Mercado Livre, usados só como ordem de grandeza.

Ajustes na lista de peças (recomendação do especialista):
- Removidas "coluna de direção" (item de perícia estrutural em colisão
  grave, não cabe em pré-preenchimento automático) e "tanque de
  combustível" (baixíssima frequência no cenário leve/moderado do app).
- Adicionadas: para-lama traseiro (direito/esquerdo), maçaneta externa,
  sensor de estacionamento — comuns em colisão lateral/traseira leve, que
  não estavam cobertas antes.
- Airbag do motorista mantido, mas é item de severidade GRAVE apenas —
  o valor é uma referência grosseira (não inclui central/sensores), por
  isso o agente deve tratar isso como exceção a negociar, não sugestão
  automática confiável (ver instruction do `OrcamentoOficinaAgent`).

Uso (emulador, mesma variável que `simular_local.ps1` seta):
    $env:FIRESTORE_EMULATOR_HOST = "localhost:8080"
    .venv\\Scripts\\python.exe scripts\\seed_tabela_precos.py

Uso (Firestore real do projeto — CUIDADO, escreve em produção):
    .venv\\Scripts\\python.exe scripts\\seed_tabela_precos.py --real
"""

from __future__ import annotations

import sys

from google.cloud import firestore

# categoria -> {peca: (valor_peca_reais, horas_mao_obra)}
TABELA: dict[str, dict[str, tuple[float, float]]] = {
    "popular_compacto": {
        "para-choque dianteiro": (550.0, 1.2),
        "para-choque traseiro": (500.0, 1.2),
        "grade dianteira": (180.0, 0.4),
        "farol dianteiro direito": (550.0, 0.4),
        "farol dianteiro esquerdo": (550.0, 0.4),
        "lanterna traseira direita": (260.0, 0.3),
        "lanterna traseira esquerda": (260.0, 0.3),
        "capô": (750.0, 1.3),
        "para-lama dianteiro direito": (320.0, 0.9),
        "para-lama dianteiro esquerdo": (320.0, 0.9),
        "para-lama traseiro direito": (340.0, 1.0),
        "para-lama traseiro esquerdo": (340.0, 1.0),
        "porta dianteira direita": (950.0, 2.2),
        "porta dianteira esquerda": (950.0, 2.2),
        "porta traseira direita": (850.0, 2.0),
        "porta traseira esquerda": (850.0, 2.0),
        "retrovisor direito": (220.0, 0.4),
        "retrovisor esquerdo": (220.0, 0.4),
        "maçaneta externa": (110.0, 0.5),
        "radiador": (450.0, 1.6),
        "condensador de ar-condicionado": (420.0, 1.6),
        "parabrisa": (680.0, 1.5),
        "vidro traseiro": (450.0, 1.0),
        "capô do porta-malas": (680.0, 1.3),
        "amortecedor dianteiro direito": (280.0, 1.2),
        "amortecedor dianteiro esquerdo": (280.0, 1.2),
        "roda liga leve": (450.0, 0.3),
        "pneu": (380.0, 0.3),
        "sensor de estacionamento": (90.0, 0.3),
        "airbag do motorista": (2200.0, 2.5),
    },
    "medio_suv_compacto": {
        "para-choque dianteiro": (950.0, 1.3),
        "para-choque traseiro": (850.0, 1.3),
        "grade dianteira": (320.0, 0.4),
        "farol dianteiro direito": (1450.0, 0.5),
        "farol dianteiro esquerdo": (1450.0, 0.5),
        "lanterna traseira direita": (480.0, 0.4),
        "lanterna traseira esquerda": (480.0, 0.4),
        "capô": (1250.0, 1.4),
        "para-lama dianteiro direito": (580.0, 1.0),
        "para-lama dianteiro esquerdo": (580.0, 1.0),
        "para-lama traseiro direito": (600.0, 1.1),
        "para-lama traseiro esquerdo": (600.0, 1.1),
        "porta dianteira direita": (1650.0, 2.4),
        "porta dianteira esquerda": (1650.0, 2.4),
        "porta traseira direita": (1500.0, 2.2),
        "porta traseira esquerda": (1500.0, 2.2),
        "retrovisor direito": (450.0, 0.5),
        "retrovisor esquerdo": (450.0, 0.5),
        "maçaneta externa": (180.0, 0.5),
        "radiador": (750.0, 1.7),
        "condensador de ar-condicionado": (700.0, 1.7),
        "parabrisa": (1100.0, 1.6),
        "vidro traseiro": (750.0, 1.1),
        "capô do porta-malas": (1150.0, 1.4),
        "amortecedor dianteiro direito": (480.0, 1.3),
        "amortecedor dianteiro esquerdo": (480.0, 1.3),
        "roda liga leve": (800.0, 0.3),
        "pneu": (650.0, 0.3),
        "sensor de estacionamento": (130.0, 0.3),
        "airbag do motorista": (3400.0, 2.8),
    },
    "suv_grande_picape": {
        "para-choque dianteiro": (1900.0, 1.6),
        "para-choque traseiro": (1600.0, 1.4),
        "grade dianteira": (550.0, 0.5),
        "farol dianteiro direito": (2600.0, 0.6),
        "farol dianteiro esquerdo": (2600.0, 0.6),
        "lanterna traseira direita": (780.0, 0.4),
        "lanterna traseira esquerda": (780.0, 0.4),
        "capô": (2100.0, 1.6),
        "para-lama dianteiro direito": (950.0, 1.2),
        "para-lama dianteiro esquerdo": (950.0, 1.2),
        "para-lama traseiro direito": (1000.0, 1.3),
        "para-lama traseiro esquerdo": (1000.0, 1.3),
        "porta dianteira direita": (2600.0, 2.6),
        "porta dianteira esquerda": (2600.0, 2.6),
        "porta traseira direita": (2400.0, 2.4),
        "porta traseira esquerda": (2400.0, 2.4),
        "retrovisor direito": (750.0, 0.5),
        "retrovisor esquerdo": (750.0, 0.5),
        "maçaneta externa": (280.0, 0.5),
        "radiador": (1300.0, 1.9),
        "condensador de ar-condicionado": (1150.0, 1.9),
        "parabrisa": (1750.0, 1.8),
        "vidro traseiro": (1050.0, 1.2),
        "capô do porta-malas": (1900.0, 1.6),
        "amortecedor dianteiro direito": (850.0, 1.5),
        "amortecedor dianteiro esquerdo": (850.0, 1.5),
        "roda liga leve": (1400.0, 0.3),
        "pneu": (1100.0, 0.3),
        "sensor de estacionamento": (170.0, 0.3),
        "airbag do motorista": (4800.0, 3.0),
    },
}


def _client(use_real: bool) -> firestore.Client:
    import os

    if not use_real and not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        print(
            "FIRESTORE_EMULATOR_HOST não está setado. Rode este script depois "
            "de `simular_local.ps1` já ter o emulador no ar (ou exporte a "
            "variável manualmente), ou passe --real para escrever no "
            "Firestore de produção (não recomendado sem confirmar antes).",
            file=sys.stderr,
        )
        sys.exit(1)

    project = os.environ.get("GOOGLE_CLOUD_PROJECT", "demo-argos")
    return firestore.Client(project=project)


def main() -> None:
    use_real = "--real" in sys.argv

    if use_real:
        confirm = input(
            "Isso vai escrever em Firestore de PRODUÇÃO. Digite 'confirmo' "
            "para continuar: "
        )
        if confirm.strip().lower() != "confirmo":
            print("Cancelado.")
            return

    db = _client(use_real)
    total = 0

    for categoria, pecas in TABELA.items():
        pecas_ref = db.collection("tabelaPrecos").document(categoria).collection("pecas")
        batch = db.batch()

        for peca, (valor_peca, horas) in pecas.items():
            doc_id = peca.strip().lower()
            batch.set(
                pecas_ref.document(doc_id),
                {
                    "peca": peca,
                    "valorPeca": valor_peca,
                    "horasMaoObra": horas,
                },
            )

        batch.commit()
        total += len(pecas)
        print(f"  tabelaPrecos/{categoria}/pecas: {len(pecas)} peças")

    print(f"Seed concluído: {total} registros em {len(TABELA)} categorias.")


if __name__ == "__main__":
    main()

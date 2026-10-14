"""Tools de preço de referência e cálculo do orçamento.

A regra mais importante herdada do playbook original é preservada aqui em
código, não em prompt: o agente NUNCA soma valores "de cabeça" — quem
soma é `calcular_orcamento_total`, de forma determinística.
"""

from __future__ import annotations

import re
import unicodedata

from google.cloud import firestore

from common.firestore_tools import _para_float

_db: firestore.Client | None = None

# Fallback mínimo para o MVP/TCC, usado só quando não há registro na
# coleção `tabelaPrecos` do Firestore para a peça/categoria consultados.
# Valores da categoria "popular_compacto" (ver `scripts/seed_tabela_precos.py`
# e a validação de domínio de 2026-09-01 — não são chute sem embasamento).
_FALLBACK_PRECOS = {
    "para-choque": {"valor_peca": 550.0, "horas_mao_obra": 1.2},
    "farol": {"valor_peca": 550.0, "horas_mao_obra": 0.4},
    "paralama": {"valor_peca": 320.0, "horas_mao_obra": 0.9},
    "radiador": {"valor_peca": 450.0, "horas_mao_obra": 1.6},
    "condensador de ar-condicionado": {"valor_peca": 420.0, "horas_mao_obra": 1.6},
}

_VALOR_HORA_MAO_OBRA = 90.0
_TOLERANCIA_FAIXA_PRECO = 0.20  # 20% acima do valor de referência

_CATEGORIA_DEFAULT = "popular_compacto"

# Mapeamento modelo -> categoria de porte do veículo, usado pra escolher a
# tabela de referência certa em `tabelaPrecos/{categoria}/pecas/{peca}` —
# peça de reposição varia muito de preço por porte/plataforma no Brasil
# (ver validação de domínio de 2026-09-01), então uma tabela "genérica"
# única não é defensável. Cobertura deliberadamente parcial (os modelos
# mais comuns por categoria); o que não bate com nenhum termo cai no
# default (`_CATEGORIA_DEFAULT`), o segmento mais comum no Brasil.
_MODELOS_POR_CATEGORIA = {
    "popular_compacto": (
        "onix", "hb20", "gol", "ka", "argo", "mobi", "polo", "up!", "up ",
        "kwid", "sandero", "prisma", "voyage", "logan", "celta", "palio",
    ),
    "medio_suv_compacto": (
        "corolla", "civic", "cronos", "virtus", "t-cross", "tcross",
        "creta", "compass", "jetta", "cruze", "duster", "kicks", "hr-v",
        "hrv", "tiggo", "ix35", "tucson", "sportage", "corolla cross",
        "renegade", "nivus", "tracker", "captur", "c4 cactus",
    ),
    "suv_grande_picape": (
        "hilux", "s10", "ranger", "sw4", "trailblazer", "pajero sport",
        "amarok", "frontier", "l200", "land cruiser", "grand cherokee",
    ),
}


def _client() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def _normalizar(texto: str) -> str:
    return texto.strip().lower()


# O modelo escreve "paralama"/"para lama"; a tabela usa "para-lama". Sem
# normalizar, o substantivo principal nao bate no casamento estrito e a peca
# cai no fallback de carro popular — errado, e silencioso.
_GRAFIAS = {
    "paralama": "para-lama",
    "para lama": "para-lama",
    "parachoque": "para-choque",
    "para choque": "para-choque",
    "parabrisas": "parabrisa",
    "para-brisa": "parabrisa",
    "retrovisor externo": "retrovisor",
}


def _chave_documento(peca: str) -> str:
    """Normaliza o nome da peça para um document id estável do Firestore.

    Sem isto, "capô" e "capo" viram documentos diferentes (o seed grava um,
    o modelo pede o outro) e a consulta cai no fallback sem ninguém notar.
    Também remove barras, que são separadoras de path e quebrariam a
    referência ao documento.
    """
    sem_acento = (
        unicodedata.normalize("NFKD", _normalizar(peca))
        .encode("ascii", "ignore")
        .decode("ascii")
    )
    limpo = re.sub(r"[^a-z0-9 _-]", "", sem_acento)
    chave = re.sub(r"\s+", " ", limpo).strip()

    for errado, certo in _GRAFIAS.items():
        if chave == errado or chave.startswith(errado + " "):
            chave = certo + chave[len(errado):]
            break

    return chave


def _categoria_por_modelo(modelo_veiculo: str) -> str:
    texto = _normalizar(modelo_veiculo)

    for categoria, termos in _MODELOS_POR_CATEGORIA.items():
        if any(termo in texto for termo in termos):
            return categoria

    return _CATEGORIA_DEFAULT


# Cache das pecas de cada categoria, para o casamento aproximado nao pagar
# uma listagem por consulta. Vive pelo tempo da instancia do Cloud Run.
_pecas_por_categoria: dict[str, dict[str, dict]] = {}


def _pecas_da_categoria(db, categoria: str) -> dict[str, dict]:
    if categoria not in _pecas_por_categoria:
        docs = (
            db.collection("tabelaPrecos")
            .document(categoria)
            .collection("pecas")
            .stream()
        )
        _pecas_por_categoria[categoria] = {d.id: (d.to_dict() or {}) for d in docs}
    return _pecas_por_categoria[categoria]


# Palavras que nao carregam identidade de peca. Sem remove-las, "banco do
# motorista" casava com "airbag do motorista" por conta de "do"+"motorista".
_IRRELEVANTES = {"do", "da", "de", "dos", "das", "o", "a", "os", "as", "e"}

# O mecanico e a tabela usam palavras diferentes para a mesma posicao.
_SINONIMOS = {
    "frente": "dianteiro", "frontal": "dianteiro", "dianteira": "dianteiro",
    "tras": "traseiro", "atras": "traseiro", "traseira": "traseiro",
    "direita": "direito", "esquerda": "esquerdo",
}


def _tokens(chave: str) -> list[str]:
    saida = []
    for t in chave.split():
        if t in _IRRELEVANTES:
            continue
        saida.append(_SINONIMOS.get(t, t))
    return saida


def _melhor_aproximacao(chave: str, disponiveis: dict[str, dict]) -> tuple[str, dict] | None:
    """Acha a peca da tabela que corresponde ao termo pedido, ou None.

    A busca principal e por document id exato. Mas o modelo escreve o nome da
    peca em linguagem natural e a tabela usa nomes canonicos: ele pede
    "farol direito", a tabela tem "farol dianteiro direito".

    O casamento e ESTRITO de proposito. Uma versao permissiva (sobreposicao de
    termos com limiar) foi testada e produzia erros graves: "banco do
    motorista" casava com "airbag do motorista" (R$ 4.800 por um banco) e
    "porta da frente direita" casava com "porta traseira direita". Preco
    errado com cara de certo e pior que cair no fallback, que pelo menos se
    declara como `fonte: fallback_mvp`.

    As tres regras:
      1. O substantivo principal (primeiro termo) tem que ser IGUAL. "banco"
         nunca casa com "airbag".
      2. Todo termo restante do pedido tem que existir no nome canonico, apos
         normalizar sinonimos de posicao (frente->dianteiro, direita->direito).
      3. Se mais de uma peca satisfizer, e ambiguo -> None. "para-choque" sem
         dizer se e dianteiro ou traseiro nao deve escolher um por conta.
    """
    # Acerto exato ganha de qualquer ambiguidade. No fluxo real a busca por
    # document id ja resolveu isso antes, mas sem esta linha o matcher
    # isolado recusaria "capo" por existir tambem "capo do porta-malas".
    if chave in disponiveis:
        return chave, disponiveis[chave]

    pedidos = _tokens(chave)
    if not pedidos:
        return None

    cabeca, modificadores = pedidos[0], set(pedidos[1:])

    candidatos = []
    for doc_id, dados in disponiveis.items():
        termos = _tokens(doc_id)
        if not termos or termos[0] != cabeca:
            continue
        if not modificadores.issubset(set(termos[1:])):
            continue
        candidatos.append((doc_id, dados))

    if len(candidatos) != 1:
        return None
    return candidatos[0]


def consultar_preco_referencia(peca: str, modelo_veiculo: str) -> dict:
    """Busca o preço/horas de referência de uma peça para pré-preencher a
    tabela de orçamento (ver skill `nova-captura-em-lote`).

    Args:
        peca: nome da peça (ex.: "para-choque dianteiro").
        modelo_veiculo: marca + modelo do veículo — usado pra escolher a
            categoria de porte certa (popular/médio/SUV grande), não o
            modelo exato (a tabela é por categoria, não por modelo único).

    Returns:
        dict com `valor_peca_sugerido`, `horas_mao_obra_sugeridas` e
        `fonte` ("tabela_referencia" ou "sem_referencia").
    """
    db = _client()
    chave_modelo = _categoria_por_modelo(modelo_veiculo)
    chave_peca = _normalizar(peca)
    chave_doc = _chave_documento(peca)

    doc = (
        db.collection("tabelaPrecos")
        .document(chave_modelo)
        .collection("pecas")
        .document(chave_doc)
        .get()
    )

    if doc.exists:
        dados = doc.to_dict() or {}
        return {
            "peca": peca,
            "valor_peca_sugerido": _para_float(dados.get("valorPeca")),
            "horas_mao_obra_sugeridas": _para_float(dados.get("horasMaoObra")),
            "fonte": "tabela_referencia",
        }

    aprox = _melhor_aproximacao(chave_doc, _pecas_da_categoria(db, chave_modelo))
    if aprox is not None:
        doc_id, dados = aprox
        return {
            "peca": peca,
            "valor_peca_sugerido": _para_float(dados.get("valorPeca")),
            "horas_mao_obra_sugeridas": _para_float(dados.get("horasMaoObra")),
            "fonte": "tabela_referencia_aproximada",
            "peca_na_tabela": dados.get("peca", doc_id),
        }

    for termo, referencia in _FALLBACK_PRECOS.items():
        if termo in chave_peca:
            return {
                "peca": peca,
                "valor_peca_sugerido": referencia["valor_peca"],
                "horas_mao_obra_sugeridas": referencia["horas_mao_obra"],
                "fonte": "fallback_mvp",
            }

    return {
        "peca": peca,
        "valor_peca_sugerido": None,
        "horas_mao_obra_sugeridas": None,
        "fonte": "sem_referencia",
    }


def verificar_faixa_preco(peca: str, valor_informado: float, modelo_veiculo: str) -> dict:
    """Confere se um valor informado pelo mecânico está dentro da faixa
    esperada, para o agente saber quando vale negociar (Step 3 do
    `Orcamento_Oficina_Playbook` original).

    Returns:
        dict com `dentro_da_faixa` (bool), `valor_esperado` e
        `diferenca_percentual` (None se não há referência para comparar).
    """
    referencia = consultar_preco_referencia(peca, modelo_veiculo)
    valor_esperado = referencia["valor_peca_sugerido"]
    valor_informado = _para_float(valor_informado)

    if valor_esperado in (None, 0):
        return {
            "peca": peca,
            "dentro_da_faixa": True,
            "valor_esperado": None,
            "diferenca_percentual": None,
        }

    valor_esperado = _para_float(valor_esperado)
    diferenca = (valor_informado - valor_esperado) / valor_esperado

    return {
        "peca": peca,
        "dentro_da_faixa": diferenca <= _TOLERANCIA_FAIXA_PRECO,
        "valor_esperado": valor_esperado,
        "diferenca_percentual": round(diferenca * 100, 1),
    }


def calcular_orcamento_total(itens: list[dict]) -> dict:
    """Soma o orçamento de forma determinística — o agente nunca deve
    calcular esse valor por conta própria.

    Args:
        itens: lista de dicts no formato
            `{"peca": str, "valor_peca": float, "horas_mao_obra": float}`.
            `valor_peca` e `horas_mao_obra` podem ser 0 quando não se
            aplicam ao item (ex.: item só de mão de obra ou só de peça).

    Returns:
        dict com `valor_total_pecas`, `valor_total_mao_obra`,
        `valor_total_final` e o detalhamento por item.
    """
    detalhamento = []
    valor_total_pecas = 0.0
    valor_total_mao_obra = 0.0

    for item in itens:
        valor_peca = _para_float(item.get("valor_peca"))
        horas = _para_float(item.get("horas_mao_obra"))
        valor_mao_obra = horas * _VALOR_HORA_MAO_OBRA

        valor_total_pecas += valor_peca
        valor_total_mao_obra += valor_mao_obra

        detalhamento.append(
            {
                "peca": item.get("peca"),
                "valor_peca": round(valor_peca, 2),
                "horas_mao_obra": horas,
                "valor_mao_obra": round(valor_mao_obra, 2),
                "valor_item_total": round(valor_peca + valor_mao_obra, 2),
            }
        )

    valor_total_final = round(valor_total_pecas + valor_total_mao_obra, 2)

    return {
        "valor_total_pecas": round(valor_total_pecas, 2),
        "valor_total_mao_obra": round(valor_total_mao_obra, 2),
        "valor_total_final": valor_total_final,
        "detalhamento": detalhamento,
    }

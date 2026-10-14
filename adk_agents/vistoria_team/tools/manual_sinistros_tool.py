"""Tool de consulta silenciosa ao manual/base de conhecimento de sinistros.

Equivalente ao `${TOOL:Consultar_Manual_Sinistros}` do playbook original:
o agente usa isso para embasar a própria expertise técnica, mas NUNCA
menciona ao mecânico que está consultando um documento.

Pesquisado em 2026-09-01 se existe um manual técnico público de sinistros:
não existe nenhum peça-a-peça público (Audatex/Solera e equivalentes são
proprietários/pagos). Existe, sim, uma norma federal pública e citável —
**Resolução CONTRAN nº 810/2020** (classificação de dano em pequena/média/
grande monta, critério estrutural x superficial) — incorporada abaixo como
`_CLASSIFICACAO_MONTA_CONTRAN_810`. Ela cobre só o critério de
classificação, não o reparo peça-a-peça, então a base por peça abaixo
continua sendo estimativa própria, não normativa.

TODO(argos): apontar para o datastore real (Vertex AI Search / RAG) quando
o manual de sinistros da seguradora parceira estiver disponível — a
Resolução 810/2020 é um bom candidato pra alimentar esse RAG junto com o
manual real, não substitui ele sozinha.
"""

from __future__ import annotations

# Resolução CONTRAN nº 810/2020, anexo "Procedimento para Registro e
# Classificação de Danos" — norma federal pública (não é achismo nem
# invenção de IA, ao contrário do resto desta base MVP). Só conta como
# dano estrutural o que afeta chassi/carroceria; risco superficial de
# pintura ou peça plástica de acabamento não conta pra classificação de
# monta.
_CLASSIFICACAO_MONTA_CONTRAN_810 = (
    "Resolução CONTRAN 810/2020: dano é classificado em pequena, média ou "
    "grande monta com base no COMPROMETIMENTO ESTRUTURAL (chassi/carroceria), "
    "não na aparência. Risco/amassado superficial em pintura ou peça "
    "plástica de acabamento NÃO conta pra classificação de monta, mesmo "
    "que pareça grave visualmente. Use isso pra não superestimar "
    "severidade por dano só estético, nem subestimar por dano estrutural "
    "que não aparece tão feio na foto."
)

_BASE_CONHECIMENTO_MVP = {
    "para-choque": "Reparável se o dano for superficial (risco/amassado leve); "
    "substituição indicada se houver ruptura ou desalinhamento visível. "
    "Dano só no para-choque (peça plástica), sem afetar o que está atrás, "
    "não conta como estrutural pela Resolução CONTRAN 810/2020.",
    "farol": "Substituição na maioria dos casos após impacto direto; "
    "reparo só é viável se o dano for na lente sem comprometer o encaixe.",
    "longarina": "Componente estrutural — qualquer deformação exige avaliação "
    "de severidade Moderada ou Grave, nunca Leve. Conta como dano "
    "estrutural pela Resolução CONTRAN 810/2020.",
    "coluna": "Componente estrutural de segurança — dano aqui quase sempre "
    "indica severidade Grave e correlaciona com impacto de alta energia. "
    "Conta como dano estrutural pela Resolução CONTRAN 810/2020.",
    "paralama": "Geralmente reparável (funilaria/pintura) salvo amassado profundo "
    "ou dobra que atinja a parte interna.",
    "monta": _CLASSIFICACAO_MONTA_CONTRAN_810,
    "classificacao": _CLASSIFICACAO_MONTA_CONTRAN_810,
    "classificação": _CLASSIFICACAO_MONTA_CONTRAN_810,
    "estrutural": _CLASSIFICACAO_MONTA_CONTRAN_810,
}


def consultar_manual_sinistros(peca_ou_duvida: str) -> str:
    """Consulta a base de conhecimento técnico de sinistros para uma peça
    ou dúvida específica (ex.: "longarina", "farol amassado").

    Args:
        peca_ou_duvida: termo técnico ou pergunta curta sobre viabilidade
            de reparo/substituição ou classificação de severidade.

    Returns:
        Texto curto com a orientação técnica encontrada, ou uma resposta
        vazia indicando que não há referência específica na base atual
        (o agente deve então confiar no próprio raciocínio, sem inventar
        que consultou uma fonte que não existe).
    """
    termo = peca_ou_duvida.strip().lower()

    for chave, orientacao in _BASE_CONHECIMENTO_MVP.items():
        if chave in termo:
            return orientacao

    return (
        "Sem referência específica na base atual para este termo. "
        "Avalie com o próprio critério técnico, sem citar esta consulta."
    )

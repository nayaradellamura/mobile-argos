"""Tools de acesso ao Firestore usadas pelo time de Vistoria.

Espelham o que hoje vive em `functions/index.js` (loadArgosInspectionContext,
buildArgosSessionParameters, saveAgentStateToVistoria) para não perder
nenhum dado de negócio já em uso pelo app Flutter durante o redesenho do
agente. Ver especialista-flutter-firebase-argos para o schema das coleções.
"""

from __future__ import annotations

from google.cloud import firestore

_db: firestore.Client | None = None


def _client() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def _para_float(valor) -> float:
    """Converte para float sem explodir no formato que o modelo (ou o app)
    costuma mandar: "R$ 550,00", "1,2", "550.00", None, "".

    `float()` puro levanta ValueError nesses casos, e exceção em tool mata o
    turno do chat inteiro no ADK — o mecânico perde a conversa.
    """
    if valor is None or valor == "":
        return 0.0
    if isinstance(valor, (int, float)):
        return float(valor)

    texto = str(valor).strip()
    for lixo in ("R$", "r$", " ", " "):
        texto = texto.replace(lixo, "")
    # "1.234,56" -> "1234.56" | "1234,56" -> "1234.56"
    if "," in texto:
        texto = texto.replace(".", "").replace(",", ".")

    try:
        return float(texto)
    except ValueError:
        return 0.0


def carregar_contexto_vistoria(id_vistoria: str) -> dict:
    """Carrega o contexto já existente de uma vistoria (e do sinistro/veículo
    relacionados) para o agente não perguntar de novo o que já está salvo.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.

    Returns:
        dict com os campos já conhecidos: placa, veiculo, cliente,
        oficina, tipo_vistoria, agent_parameters salvos anteriormente,
        e (se for retificação) ajustes_necessarios/contexto_vistoria_anterior.
    """
    db = _client()
    vistoria_ref = db.collection("vistorias").document(id_vistoria)
    vistoria = vistoria_ref.get().to_dict() or {}

    sinistro_id = str(vistoria.get("sinistroId") or "")
    sinistro = {}
    if sinistro_id:
        sinistro = db.collection("sinistro").document(sinistro_id).get().to_dict() or {}

    return {
        "id_vistoria": id_vistoria,
        "sinistro_id": sinistro_id,
        "tipo_vistoria": vistoria.get("tipoVistoria", "ORIGINAL"),
        "placa_veiculo": vistoria.get("placa", ""),
        "modelo_veiculo": vistoria.get("veiculo", ""),
        "cliente_nome": vistoria.get("cliente", ""),
        "oficina_nome": vistoria.get("credenciado", ""),
        "relato_inicial": vistoria.get("descricaoArtigos", ""),
        "observacoes": vistoria.get("observacoes", ""),
        "ajustes_necessarios": vistoria.get("ajustesNecessarios", ""),
        "contexto_vistoria_anterior": vistoria.get("contextoVistoriaAnterior", ""),
        "agent_parameters_salvos": vistoria.get("agentParameters", {}),
        "imagens": vistoria.get("images", []),
        "prioridade_sinistro": sinistro.get("priority", ""),
        "tipo_sinistro": sinistro.get("claimType", ""),
    }


def salvar_estado_vistoria(id_vistoria: str, campos: dict) -> dict:
    """Persiste os campos coletados/decididos pelo agente nesta etapa.

    Faz merge (não sobrescreve o documento inteiro), do mesmo jeito que
    `saveAgentStateToVistoria` faz hoje em `functions/index.js`.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        campos: dict com os campos a mesclar em `agentParameters`
            (ex.: hodometro, dinamica_acidente, ponto_impacto,
            danos_externos, danos_estruturais, severidade_geral).

    Returns:
        dict de confirmação com os campos efetivamente salvos.
    """
    db = _client()
    limpos = {k: v for k, v in campos.items() if v not in (None, "", [])}

    db.collection("vistorias").document(id_vistoria).set(
        {
            "agentParameters": limpos,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"id_vistoria": id_vistoria, "campos_salvos": limpos}


def salvar_rascunho_orcamento(id_vistoria: str, itens: list[dict]) -> dict:
    """Persiste o rascunho de orçamento (peças + preço/horas de referência
    já pré-preenchidos) para a tela nativa de tabela editável ler antes de
    abrir — ver skill `nova-captura-em-lote`.

    Chamado no Passo 2 do `OrcamentoOficinaAgent`, depois de
    `consultar_preco_referencia` para cada peça confirmada.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        itens: lista de dicts `{"peca": str, "tipo_intervencao": str,
            "quantidade": int, "valor_peca": float, "tipo_servico": str,
            "horas_mao_obra": float, "valor_hora": float, "origem": str}`.
            `valor_hora` é o da oficina para o `tipo_servico` do item.
            `origem` é "vistoria" ou "sugestao_aceita", só para o app poder
            sinalizar visualmente o que veio de sugestão proativa.
            Mão de obra em valor total (sem horas): um item com
            `mao_obra_em_valor: true`, `horas_mao_obra: 1` e `valor_hora` =
            o valor total — mesma convenção da tabela do app.

    Returns:
        dict de confirmação com a quantidade de itens salvos.
    """
    db = _client()

    rascunho = [_item_rascunho(item) for item in itens]

    db.collection("vistorias").document(id_vistoria).set(
        {
            "orcamentoRascunho": rascunho,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"id_vistoria": id_vistoria, "itens_salvos": len(rascunho)}


def _item_rascunho(item: dict) -> dict:
    """Converte um item do agente para o formato que a tabela do app lê."""
    if item.get("mao_obra_em_valor"):
        valor = _para_float(item.get("valor_hora"))
        return {
            "peca": item.get("peca") or "Mão de obra",
            "tipoIntervencao": item.get("tipo_intervencao", "reparo"),
            "quantidade": 1,
            "valorPeca": _para_float(item.get("valor_peca")),
            "tipoServico": item.get("tipo_servico") or "mecanica",
            # Tabela do app: mão de obra em valor = 1 h ao valor informado.
            "horasMaoObra": 1.0 if valor > 0 else 0.0,
            "valorHora": valor,
            "valorMaoObra": valor,
            "maoObraEmValor": True,
            # Nunca "mecanico": essa origem marca o rascunho do envio em massa,
            # e o laudo-service usaria só as linhas com ela como orçamento.
            "origem": item.get("origem") or "vistoria",
        }

    return {
        "peca": item.get("peca", ""),
        "tipoIntervencao": item.get("tipo_intervencao", "substituicao"),
        "quantidade": max(1, round(_para_float(item.get("quantidade")) or 1)),
        "valorPeca": _para_float(item.get("valor_peca")),
        "tipoServico": item.get("tipo_servico") or "funilaria",
        "horasMaoObra": _para_float(item.get("horas_mao_obra")),
        "origem": item.get("origem", "vistoria"),
        # Congelado no item, como o app faz; sem valor, o histórico e o
        # laudo caem no valor legado.
        **(
            {"valorHora": _para_float(item.get("valor_hora"))}
            if item.get("valor_hora") is not None
            else {}
        ),
    }


def carregar_orcamento_confirmado(id_vistoria: str) -> dict:
    """Lê a lista final de itens que o mecânico confirmou na tela nativa de
    tabela editável (`orcamentoItensFinais`, escrito pelo app numa única
    gravação quando ele toca em "Enviar orçamento").

    Chamado no início do Passo 4 do `OrcamentoOficinaAgent`, depois que o
    agente recebe a mensagem de retomada da conversa (o app manda essa
    mensagem só depois de gravar a lista, então ela já está disponível
    aqui).

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.

    Returns:
        dict com `itens` no formato que `verificar_faixa_preco`/
        `calcular_orcamento_total` esperam (`peca`, `valor_peca`,
        `horas_mao_obra`), e `tipo_intervencao` para referência.
    """
    db = _client()
    vistoria = db.collection("vistorias").document(id_vistoria).get().to_dict() or {}
    itens_finais = vistoria.get("orcamentoItensFinais") or []

    itens = [
        {
            "peca": item.get("peca", ""),
            "tipo_intervencao": item.get("tipoIntervencao", "substituicao"),
            "quantidade": int(_para_float(item.get("quantidade")) or 1),
            "valor_peca": _para_float(item.get("valorPeca")),
            "tipo_servico": item.get("tipoServico", ""),
            "horas_mao_obra": _para_float(item.get("horasMaoObra")),
            "valor_hora": item.get("valorHora"),
            **({"mao_obra_em_valor": True} if item.get("maoObraEmValor") else {}),
        }
        for item in itens_finais
    ]

    return {"id_vistoria": id_vistoria, "itens": itens, "quantidade": len(itens)}


def marcar_fotos_analisadas(id_vistoria: str, image_ids: list[str]) -> dict:
    """Marca fotos como já analisadas, DEPOIS que a análise visual realmente
    aconteceu.

    Chame isto apenas no fim do Passo 4, quando `AnalistaDanosVisao` e
    `VerificadorConsistencia` já responderam sobre a leva. Nunca antes: quem
    marca antes perde a foto para sempre se o turno falhar no meio (a próxima
    chamada de `carregar_fotos_para_analise` a considera já processada e a
    pula), e a vistoria segue com um laudo "consistente" que nunca viu
    aquela imagem.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        image_ids: os `image_ids_da_leva` devolvidos por
            `carregar_fotos_para_analise` nesta mesma leva.

    Returns:
        dict de confirmação com a quantidade marcada.
    """
    ids = [str(i) for i in (image_ids or []) if str(i).strip()]
    if not ids:
        return {"id_vistoria": id_vistoria, "marcadas": 0}

    db = _client()
    db.collection("vistorias").document(id_vistoria).set(
        {
            "imagensAnalisadasIds": firestore.ArrayUnion(ids),
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"id_vistoria": id_vistoria, "marcadas": len(ids)}


# Aceita tanto o nome canônico quanto os apelidos que o modelo tende a
# gerar. Antes isto levantava ValueError, e uma exceção em tool MATA o turno
# do chat no ADK (functions.py:636-650 re-levanta quando não há handler).
_APELIDOS_DE_PASSO = {
    "identificacao": "passo_identificacao",
    "identificação": "passo_identificacao",
    "passo_identificacao": "passo_identificacao",
    "externos": "passo_externos",
    "danos_externos": "passo_externos",
    "passo_externos": "passo_externos",
    "estruturais": "passo_estruturais",
    "danos_estruturais": "passo_estruturais",
    "passo_estruturais": "passo_estruturais",
}


def marcar_passo_concluido(id_vistoria: str, passo: str) -> dict:
    """Marca um passo da 'trava de estado' (ex.: captura de fotos) como
    concluído, para o agente não repetir a mesma pergunta em turnos futuros.

    Args:
        id_vistoria: id do documento em `vistorias/{id_vistoria}`.
        passo: um de `passo_identificacao`, `passo_externos`,
            `passo_estruturais`.
    """
    chave = _APELIDOS_DE_PASSO.get(str(passo or "").strip().lower())
    if chave is None:
        return {
            "erro": (
                f"passo desconhecido: {passo!r}. Use passo_identificacao, "
                "passo_externos ou passo_estruturais."
            )
        }
    passo = chave

    db = _client()
    db.collection("vistorias").document(id_vistoria).set(
        {
            "agentParameters": {passo: "concluido"},
            "updatedAt": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"id_vistoria": id_vistoria, "passo": passo, "status": "concluido"}

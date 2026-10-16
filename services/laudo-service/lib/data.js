const admin = require("firebase-admin");

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function str(value, fallback = "") {
  if (value === null || value === undefined) return fallback;
  const s = String(value).trim();
  return s || fallback;
}

function formatDate(value) {
  if (!value) return "";
  // Timestamp do Firestore (admin SDK) ou já Date.
  const date = typeof value.toDate === "function" ? value.toDate() : new Date(value);
  if (Number.isNaN(date.getTime())) return "";

  return date.toLocaleString("pt-BR", {
    timeZone: "America/Sao_Paulo",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Valor da hora usado só para itens antigos, gravados antes de cada oficina
// configurar o seu (`credenciados/{id}.valoresHoraMaoObra`). Itens novos já
// chegam com `valorHora` congelado pelo app — ver
// lib/features/orcamento/orcamento_calculo.dart no app mobile.
const VALOR_HORA_LEGADO = 90;

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

// Normaliza um item vindo de qualquer fonte para o mesmo formato e recalcula
// os totais a partir dos campos base (nunca confia num total pronto).
function normalizarItem({ peca, quantidade, valorPeca, tipoServico, horasMaoObra, valorHora, maoObraEmValor }) {
  const qtd = Math.max(1, Math.round(num(quantidade)) || 1);
  const horas = num(horasMaoObra);
  const hora = valorHora === undefined || valorHora === null ? VALOR_HORA_LEGADO : num(valorHora);
  const unitario = num(valorPeca);
  const valorPecas = unitario * qtd;
  const valorMaoObra = horas * hora;

  return {
    peca: str(peca),
    quantidade: qtd,
    valorPeca: unitario,
    valorPecas,
    tipoServico: str(tipoServico),
    horasMaoObra: horas,
    valorHora: hora,
    valorMaoObra,
    valorTotal: valorPecas + valorMaoObra,
    // Mão de obra informada em reais (gravada como 1 h ao valor), não por hora.
    ...(maoObraEmValor === true ? { maoObraEmValor: true } : {}),
  };
}

// Nome digitado todo em maiúsculas (comum em orçamento lido de papel) vira
// "Primeira maiúscula"; o resto fica como o mecânico escreveu.
function nomeLegivel(texto) {
  const s = str(texto);
  const letras = s.replace(/[^A-Za-zÀ-ÿ]/g, "");
  if (letras.length < 4 || letras !== letras.toUpperCase()) return s;
  const minusculo = s.toLocaleLowerCase("pt-BR");
  return minusculo.charAt(0).toLocaleUpperCase("pt-BR") + minusculo.slice(1);
}

function formatarReais(valor) {
  return (Number(valor) || 0).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * Orçamento no formato do relatório do cliente: peças separadas de serviços
 * (itens sem valor de peça, inclusive a mão de obra em valor total), horas
 * explícitas quando a oficina cobra por hora, e a coluna de mão de obra das
 * peças só quando alguma peça tem mão de obra.
 */
function orcamentoRelatorio(orcamentoCampo) {
  const linha = (item) => ({
    nome: nomeLegivel(item.peca),
    quantidade: item.quantidade,
    valorPecas: item.valorPecas,
    valorMaoObra: item.valorMaoObra,
    valorTotal: item.valorTotal,
    detalheHoras:
      !item.maoObraEmValor && item.horasMaoObra > 0
        ? `${String(Math.round(item.horasMaoObra * 10) / 10).replace(".", ",")} h × R$ ${formatarReais(item.valorHora)}`
        : "",
  });

  const itens = Array.isArray(orcamentoCampo?.itens) ? orcamentoCampo.itens : [];
  const pecas = itens.filter((item) => item.valorPecas > 0).map(linha);
  const servicos = itens.filter((item) => !(item.valorPecas > 0)).map(linha);
  const soma = (lista, campo) => lista.reduce((total, item) => total + item[campo], 0);

  return {
    pecas,
    servicos,
    pecasComMaoObra: pecas.some((item) => item.valorMaoObra > 0),
    // Totais do rodapé: peças (só o valor das peças) e mão de obra/serviços
    // (toda mão de obra, das peças e dos serviços).
    totalPecas: soma(pecas, "valorPecas"),
    totalMaoObra: soma(pecas, "valorMaoObra") + soma(servicos, "valorTotal"),
    total: soma(pecas, "valorTotal") + soma(servicos, "valorTotal"),
  };
}

const VALIDADE_PADRAO_DIAS = 15;

// Opções do relatório escolhidas pelo mecânico no app e gravadas pela
// função gerarRelatorioCliente em sinistro.relatorioCliente.
function opcoesRelatorio(sinistro) {
  const relatorio = asObject(sinistro?.relatorioCliente);
  const excluidas = Array.isArray(relatorio.fotosExcluidas) ? relatorio.fotosExcluidas.map((f) => str(f)).filter(Boolean) : [];
  const dias = Math.round(num(relatorio.validadeDias));
  return {
    fotosExcluidas: excluidas,
    validadeDias: dias >= 1 && dias <= 180 ? dias : VALIDADE_PADRAO_DIAS,
  };
}

/**
 * Orçamento registrado em campo, com o total calculado sempre da mesma forma
 * (peças × quantidade + horas × valor da hora), venha de qual fluxo vier.
 * Fontes, em ordem de prioridade:
 *
 * 1. `orcamentoItensFinais` — tabela confirmada no chat guiado (escrita pelo
 *    app, não pelo modelo, então não sofre erro de transcrição do LLM).
 * 2. `orcamentoRascunho` com origem 'mecanico' — envio em massa (o ADK nunca
 *    participa desse fluxo).
 * 3. `agentParameters.itens_orcamento` — vistorias antigas do chat guiado,
 *    de antes da tabela gravar `orcamentoItensFinais`.
 *
 * É passado ao Gemini como referência NÃO verificada, não como veredito,
 * para evitar ancoragem do laudo no que o campo já concluiu.
 */
function buildOrcamentoCampo({ vistoria, agentParameters }) {
  const daTabela = (lista) =>
    lista
      .filter((item) => item && typeof item === "object")
      .map((item) =>
        normalizarItem({
          peca: item.peca,
          quantidade: item.quantidade,
          valorPeca: item.valorPeca,
          tipoServico: item.tipoServico,
          horasMaoObra: item.horasMaoObra,
          valorHora: item.valorHora,
          maoObraEmValor: item.maoObraEmValor,
        })
      )
      .filter((item) => item.peca);

  let itens = [];

  if (Array.isArray(vistoria.orcamentoItensFinais) && vistoria.orcamentoItensFinais.length > 0) {
    itens = daTabela(vistoria.orcamentoItensFinais);
  }

  if (itens.length === 0 && Array.isArray(vistoria.orcamentoRascunho)) {
    itens = daTabela(vistoria.orcamentoRascunho.filter((item) => item && item.origem === "mecanico"));
  }

  if (itens.length === 0 && Array.isArray(agentParameters.itens_orcamento)) {
    itens = agentParameters.itens_orcamento
      .filter((item) => item && typeof item === "object")
      .map((item) =>
        normalizarItem({
          peca: item.peca,
          quantidade: item.quantidade,
          valorPeca: item.valor_peca,
          tipoServico: item.tipo_servico,
          horasMaoObra: item.horas_mao_obra,
          valorHora: item.valor_hora,
          maoObraEmValor: item.mao_obra_em_valor,
        })
      )
      .filter((item) => item.peca);
  }

  const soma = (campo) => itens.reduce((total, item) => total + item[campo], 0);

  return {
    itens,
    valorPecas: soma("valorPecas"),
    valorMaoObra: soma("valorMaoObra"),
    valorTotal: soma("valorTotal"),
  };
}

/**
 * Junta tudo que o laudo precisa: dados do sinistro (snapshots denormalizados
 * de cliente/veículo/seguradora/credenciado), da vistoria (fotos, mensagens
 * do chat = narração do mecânico + respostas da IA) e do mecânico responsável.
 *
 * Mesma fonte de dados que o InspectionCase do app mobile lê — ver
 * lib/features/inspections/data/inspection_case.dart no argos_app.
 */
// Fotos que entram no laudo. Foto de orçamento pronto (lida pelo agente na
// etapa de orçamento, em imagensOrcamentoIds) não é foto de dano.
function fotosDeDano(vistoria) {
  const idsOrcamento = new Set(
    Array.isArray(vistoria?.imagensOrcamentoIds) ? vistoria.imagensOrcamentoIds : []
  );
  const images = Array.isArray(vistoria?.images) ? vistoria.images : [];
  return images.filter((img) => !idsOrcamento.has(img?.imageId));
}

// Danos que a vistoria registrou (agentParameters.danos_externos e
// danos_estruturais), como lista de textos sem repetição.
function listaDeDanos(agentParameters) {
  const vistos = new Set();
  const danos = [];
  for (const campo of ["danos_externos", "danos_estruturais"]) {
    const valor = agentParameters?.[campo];
    const itens = Array.isArray(valor) ? valor : str(valor).split(/[;,\n]/);
    for (const item of itens) {
      const texto = (typeof item === "object" && item ? str(item.peca || item.nome || item.descricao) : str(item)).trim();
      const chave = texto.toLowerCase();
      if (texto && !vistos.has(chave)) {
        vistos.add(chave);
        danos.push(texto.charAt(0).toUpperCase() + texto.slice(1));
      }
    }
  }
  return danos.slice(0, 30);
}

// Ajustes pedidos pelo analista e o que foi feito em cada um, quando a
// vistoria é uma retificação (ver retificacao_tool.py nos agentes ADK).
function dadosRetificacao(vistoria) {
  if (str(vistoria?.tipoVistoria).toUpperCase() !== "RETIFICACAO") return null;

  const STATUS = { resolvido: "Resolvido", nao_aplicavel: "Não se aplica", pendente: "Pendente" };
  const respostas = Object.values(asObject(vistoria.respostasRetificacao))
    .filter((r) => r && typeof r === "object")
    .map((r) => ({
      numero: Number(r.numero) || 0,
      ajuste: str(r.ajuste),
      status: str(r.status),
      statusLabel: STATUS[str(r.status)] || str(r.status),
      resposta: str(r.resposta),
    }))
    .sort((a, b) => a.numero - b.numero);

  return {
    vistoriaOrigemId: str(vistoria.vistoriaOrigemId),
    ajustesNecessarios: str(vistoria.ajustesNecessarios),
    respostas,
  };
}

// Etapas mostradas ao cliente, com a atual destacada pelo status da vistoria.
function etapasRelatorio(statusVistoria) {
  const status = str(statusVistoria).toUpperCase();
  let atual = 1;
  if (status.includes("ANALISE")) atual = 2;
  if (status.includes("APROVAD") || status === "FINALIZADA") atual = 3;

  return [
    { numero: 1, titulo: "Vistoria e orçamento", descricao: "A oficina registrou os danos e montou o orçamento do reparo." },
    { numero: 2, titulo: "Análise da seguradora", descricao: "A seguradora confere a vistoria e aprova os valores." },
    { numero: 3, titulo: "Reparo", descricao: "Com a aprovação, a oficina agenda e executa o conserto." },
  ].map((etapa) => ({ ...etapa, atual: etapa.numero === atual }));
}

async function loadLaudoContext({ sinistroId, vistoriaId }) {
  const db = admin.firestore();

  const [sinistroSnap, vistoriaSnapInicial] = await Promise.all([
    db.collection("sinistro").doc(sinistroId).get(),
    db.collection("vistorias").doc(vistoriaId).get(),
  ]);

  if (!sinistroSnap.exists) {
    throw new Error(`Sinistro ${sinistroId} não encontrado.`);
  }

  let vistoriaSnap = vistoriaSnapInicial;

  // O gatilho que enfileira a geração do laudo (onVistoriaEnterAnaliseOperacional,
  // functions/index.js) captura o vistoriaAtualId do sinistro NO INSTANTE em
  // que o status muda pra EM_ANALISE_OPERACIONAL -- se a vistoria foi criada
  // offline, esse instante pode ainda ser o ID provisório (VIS-OFFLINE-...),
  // já que a reconciliação pro número real só roda DEPOIS que o upload
  // termina de verdade. Até o Cloud Task rodar (retry com backoff, pode levar
  // minutos/horas), a reconciliação já apagou o doc provisório, e a busca
  // acima falha com um 404 que o Cloud Tasks fica retentando pra sempre (bug
  // real, achado 2026-10-02 vendo os logs de produção: VIS-OFFLINE-5801
  // falhando com retry desde 15h, sem nunca se resolver sozinho). Se isso
  // acontecer, o sinistro já deve estar apontando pro ID real reconciliado
  // -- tenta de novo com ele antes de desistir.
  if (!vistoriaSnap.exists && vistoriaId.startsWith("VIS-OFFLINE-")) {
    const vistoriaAtualId = String(sinistroSnap.data()?.vistoriaAtualId || "").trim();

    if (vistoriaAtualId && vistoriaAtualId !== vistoriaId) {
      vistoriaSnap = await db.collection("vistorias").doc(vistoriaAtualId).get();
    }
  }

  if (!vistoriaSnap.exists) {
    throw new Error(`Vistoria ${vistoriaId} não encontrada.`);
  }

  const sinistro = sinistroSnap.data() || {};
  const vistoria = vistoriaSnap.data() || {};
  const agentParameters = asObject(vistoria.agentParameters);

  const clienteSnapshot = asObject(sinistro.clienteSnapshot);
  const veiculoSnapshot = asObject(sinistro.veiculoSnapshot);
  const credenciadoSnapshot = asObject(sinistro.credenciadoSnapshot);
  const seguradoraSnapshot = asObject(sinistro.seguradoraSnapshot);

  const images = fotosDeDano(vistoria);
  const chatmessages = Array.isArray(vistoria.chatmessages) ? vistoria.chatmessages : [];

  // Narração do mecânico e respostas da IA, na ordem em que aconteceram —
  // é o que vira o "relato técnico" que o Gemini vai sintetizar.
  const transcricao = chatmessages
    .filter((m) => m && (m.role === "user" || m.role === "ai" || m.role === "audio"))
    .map((m) => ({
      autor: m.role === "ai" ? "IA" : "Mecânico",
      texto: str(m.text),
    }))
    .filter((m) => m.texto);

  const orcamentoCampo = buildOrcamentoCampo({ vistoria, agentParameters });

  return {
    sinistroId,
    vistoriaId,
    protocolo: str(sinistro.protocol, sinistroId),
    tipoSinistro: str(sinistro.claimType, "Sinistro"),
    dataAgendamento: formatDate(sinistro.scheduledDate),

    seguradoraNome: str(seguradoraSnapshot.name),
    seguradoraCnpj: str(seguradoraSnapshot.cnpj),

    clienteNome: str(clienteSnapshot.nomeCompleto),
    clienteDocumento: str(clienteSnapshot.cpfCnpj),

    veiculoPlaca: str(veiculoSnapshot.placa),
    veiculoModelo: [str(veiculoSnapshot.marca), str(veiculoSnapshot.modelo)]
      .filter(Boolean)
      .join(" "),
    veiculoAno: str(veiculoSnapshot.anoFabricacao || veiculoSnapshot.ano),
    veiculoCor: str(veiculoSnapshot.cor),
    veiculoChassi: str(veiculoSnapshot.chassi),

    oficinaNome: str(credenciadoSnapshot.name),
    oficinaEndereco: str(credenciadoSnapshot.address),
    oficinaCidade: [str(credenciadoSnapshot.city), str(credenciadoSnapshot.uf)]
      .filter(Boolean)
      .join("/"),
    oficinaTelefone: str(credenciadoSnapshot.phone),
    oficinaEmail: str(credenciadoSnapshot.email),

    mecanicoNome: str(sinistro.assignedToName, "Não informado"),
    mecanicoEmail: str(sinistro.assignedToEmail),

    checkInEm: formatDate(sinistro.checkInAt),
    finalizadoEm: formatDate(vistoria.updatedAt),

    danosDescritos: str(sinistro.damageDescription),
    observacoes: str(sinistro.observations),

    fotos: images.map((img, i) => ({
      numero: i + 1,
      url: str(img.url),
      storagePath: str(img.storagePath),
      contentType: str(img.contentType, "image/jpeg"),
      nomeArquivo: str(img.fileName, `foto-${i + 1}`),
    })),

    transcricao,

    orcamentoCampo,

    statusVistoria: str(vistoria.status),
    danosIdentificados: listaDeDanos(agentParameters),

    retificacao: dadosRetificacao(vistoria),

    relatorioOpcoes: opcoesRelatorio(sinistro),
  };
}

// buildOrcamentoCampo, normalizarItem e VALOR_HORA_LEGADO são exportados só
// para os testes (test/data.test.js) — o servidor usa apenas loadLaudoContext.
module.exports = {
  loadLaudoContext,
  buildOrcamentoCampo,
  orcamentoRelatorio,
  opcoesRelatorio,
  nomeLegivel,
  VALIDADE_PADRAO_DIAS,
  normalizarItem,
  fotosDeDano,
  listaDeDanos,
  etapasRelatorio,
  dadosRetificacao,
  VALOR_HORA_LEGADO,
};

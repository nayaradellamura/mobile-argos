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
function normalizarItem({ peca, quantidade, valorPeca, tipoServico, horasMaoObra, valorHora }) {
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
  };
}

// buildOrcamentoCampo, normalizarItem e VALOR_HORA_LEGADO são exportados só
// para os testes (test/data.test.js) — o servidor usa apenas loadLaudoContext.
module.exports = { loadLaudoContext, buildOrcamentoCampo, normalizarItem, fotosDeDano, VALOR_HORA_LEGADO };

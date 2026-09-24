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

/**
 * Junta tudo que o laudo precisa: dados do sinistro (snapshots denormalizados
 * de cliente/veículo/seguradora/credenciado), da vistoria (fotos, mensagens
 * do chat = narração do mecânico + respostas da IA) e do mecânico responsável.
 *
 * Mesma fonte de dados que o InspectionCase do app mobile lê — ver
 * lib/features/inspections/data/inspection_case.dart no argos_app.
 */
async function loadLaudoContext({ sinistroId, vistoriaId }) {
  const db = admin.firestore();

  const [sinistroSnap, vistoriaSnap] = await Promise.all([
    db.collection("sinistro").doc(sinistroId).get(),
    db.collection("vistorias").doc(vistoriaId).get(),
  ]);

  if (!sinistroSnap.exists) {
    throw new Error(`Sinistro ${sinistroId} não encontrado.`);
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

  const images = Array.isArray(vistoria.images) ? vistoria.images : [];
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

    // Orçamento que o agente ADK já rascunhou ao vivo durante o chat (tool
    // `salvar_estado_vistoria`) — passado como referência NÃO verificada
    // pro Gemini cruzar com as fotos, não como severidade/veredito pronto
    // (isso evitaria o efeito de ancoragem: o laudo só repetindo o que o
    // agente de campo já concluiu, em vez de reanalisar de fato).
    orcamentoCampo: {
      itens: Array.isArray(agentParameters.itens_orcamento)
        ? agentParameters.itens_orcamento
            .filter((item) => item && typeof item === "object")
            .map((item) => ({
              peca: str(item.peca),
              valor: Number(item.valor_peca) || 0,
              horasMaoObra: Number(item.horas_mao_obra) || 0,
            }))
            .filter((item) => item.peca)
        : [],
      valorTotal: Number(agentParameters.valor_total_final) || 0,
    },
  };
}

module.exports = { loadLaudoContext };

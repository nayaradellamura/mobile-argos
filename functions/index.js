const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineString } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { GoogleAuth } = require("google-auth-library");
const { VertexAI } = require("@google-cloud/vertexai");
const { CloudTasksClient } = require("@google-cloud/tasks");

if (!admin.apps.length) {
  admin.initializeApp({
    projectId:
      process.env.GCLOUD_PROJECT ||
      process.env.GCP_PROJECT ||
      "fho-argos",
  });
}



// URL do Cloud Run onde o agente ADK roda. Setada como env var do servico
// (--update-env-vars ARGOS_ADK_SERVICE_URL=...), nao como secret: nao e
// segredo, e o rollback fica sendo so trocar a revisao.
const ARGOS_ADK_SERVICE_URL = defineString("ARGOS_ADK_SERVICE_URL", { default: "" });

// URL do Cloud Run do gerador de laudo (services/laudo-service). Ex:
// https://laudo-service-xxxx-uc.a.run.app/gerar-laudo
const LAUDO_SERVICE_URL = defineString("LAUDO_SERVICE_URL", { default: "" });
// Fila do Cloud Tasks usada para enfileirar a geracao (retry automatico se o
// Cloud Run estiver frio/indisponivel). Criada uma vez com:
//   gcloud tasks queues create laudo-tecnico --location=us-central1
const LAUDO_TASKS_QUEUE = defineString("LAUDO_TASKS_QUEUE", { default: "laudo-tecnico" });
const LAUDO_TASKS_LOCATION = defineString("LAUDO_TASKS_LOCATION", { default: "us-central1" });
// Service account que o Cloud Tasks usa para autenticar (OIDC) a chamada no
// Cloud Run — precisa ter o papel roles/run.invoker no servico laudo-service.
const LAUDO_INVOKER_SERVICE_ACCOUNT = defineString("LAUDO_INVOKER_SERVICE_ACCOUNT", { default: "" });

// Orcamento aprovado: mesmo servico Cloud Run do laudo tecnico
// (services/laudo-service), rota diferente (/gerar-orcamento-aprovado) —
// so muda a URL. Reaproveita a mesma fila/service account do laudo.
const ORCAMENTO_SERVICE_URL = defineString("ORCAMENTO_SERVICE_URL", { default: "" });

const FIREBASE_PROJECT_ID =
  process.env.GCLOUD_PROJECT ||
  process.env.GCP_PROJECT ||
  "fho-argos";

const VERTEX_PROJECT_ID = FIREBASE_PROJECT_ID;
const VERTEX_LOCATION = "us-central1";
const GEMINI_REVIEW_MODEL = "gemini-2.5-flash";

let cachedGeminiModel = null;


function getGeminiReviewModel() {
  if (cachedGeminiModel) return cachedGeminiModel;

  const vertexAI = new VertexAI({
    project: VERTEX_PROJECT_ID,
    location: VERTEX_LOCATION,
  });

  cachedGeminiModel = vertexAI.getGenerativeModel({
    model: GEMINI_REVIEW_MODEL,
    generationConfig: {
      temperature: 0.1,
      maxOutputTokens: 1024,
      responseMimeType: "application/json",
    },
  });

  return cachedGeminiModel;
}

function createSessionId(uid, inspectionId) {
  return crypto
    .createHash("sha256")
    .update(`${uid}_${inspectionId}`)
    .digest("hex")
    .slice(0, 32);
}


exports.sendArgosMessage = onCall(
  {
    region: "us-central1",
    // O turno de fotos encadeia download das imagens + AnalistaDanosVisao
    // (multimodal) + VerificadorConsistencia. Nos 60s default isso estoura.
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Usuário precisa estar autenticado."
      );
    }

    const uid = request.auth.uid;

    const text = String(request.data.text || request.data.message || "").trim();

    const inspectionId = String(
      request.data.inspectionId ||
        request.data.idvistoria ||
        request.data.sinistroId ||
        "INS-001"
    ).trim();

    const modo = String(request.data.modo || "").trim();

    if (!text) {
      throw new HttpsError("invalid-argument", "Mensagem vazia.");
    }

    const sessionId = createSessionId(uid, inspectionId);

    try {
      const context = await loadArgosInspectionContext({
        inspectionId,
        sinistroId: request.data.sinistroId,
      });

      const freshSessionParameters = buildArgosSessionParameters({
        inspectionId,
        sinistroId: context.sinistroId,
        vistoria: context.vistoria,
        sinistro: context.sinistro,
        veiculo: context.veiculo,
        extra: {
          ...(request.data.parameters || {}),
          ...(modo === "retificacao"
            ? {
                ajustes_necessarios: request.data.ajustesNecessarios,
                contexto_vistoria_anterior:
                  request.data.contextoVistoriaAnterior,
                tipo_vistoria: "RETIFICACAO",
              }
            : {}),
        },
      });

      const savedAgentParameters = context.vistoria?.agentParameters || {};
      const sessionParameters = mergeSessionParameters(
        savedAgentParameters,
        freshSessionParameters
      );

      console.log("Parâmetros enviados ao agente Argos no texto:", {
        inspectionId,
        sinistroId: context.sinistroId,
        sessionId,
        parameters: sessionParameters,
      });

      const agentResult = await sendTextToArgosAgent({
        uid,
        inspectionId,
        text,
        sessionParameters,
        chatmessages: context.vistoria?.chatmessages || [],
        currentAgent: context.vistoria?.agentCurrentAgent || "",
      });

      const reply = agentResult.reply;

      await saveAgentStateToVistoria({
        idvistoria: inspectionId,
        currentAgent: agentResult.currentAgent,
      });

      return {
        reply,
        inspectionId,
        sinistroId: context.sinistroId,
        modo: modo || "normal",
        sessionParameters,
      };
    } catch (error) {
      console.error("Erro ao conversar com o agente ADK:", error);
      console.error("code:", error.code);
      console.error("message:", error.message);
      console.error("details:", error.details);

      throw new HttpsError(
        "internal",
        "Não foi possível conversar com o assistente Argos.",
        {
          code: error.code || null,
          message: error.message || null,
          details: error.details || null,
        }
      );
    }
  }
);

exports.sendmessageargos = exports.sendArgosMessage;

exports.notifySinistroChanges = onDocumentWritten(
  {
    document: "sinistro/{sinistroId}",
    region: "us-central1",
  },
  async (event) => {
    if (!event.data) return;

    const beforeExists = event.data.before.exists;
    const afterExists = event.data.after.exists;
    if (!afterExists) return;

    const sinistroId = event.params.sinistroId;
    const before = beforeExists ? event.data.before.data() : null;
    const after = event.data.after.data();
    if (!after) return;

    if (beforeExists && before && shouldIgnoreSinistroNotificationUpdate(before, after)) {
      console.log("Ignorando atualização de presença/viewers:", { sinistroId });
      return;
    }

    const credenciadoId = String(
      after.credenciadoId || after.credenciadoID || after.workshopId || after.oficinaId || ""
    ).trim();

    if (!credenciadoId) {
      console.log("Sinistro sem credenciadoId:", sinistroId);
      return;
    }

    const notification = buildSinistroNotification({
      sinistroId,
      before,
      after,
      isCreate: !beforeExists,
    });

    if (!notification) {
      console.log("Alteração sem notificação:", sinistroId);
      return;
    }

    const db = admin.firestore();
    const credenciadoSnap = await db.collection("credenciados").doc(credenciadoId).get();

    if (!credenciadoSnap.exists) {
      console.log("Credenciado não encontrado:", credenciadoId);
      return;
    }

    const credenciadoData = credenciadoSnap.data() || {};
    const funcionariosUids = Array.isArray(credenciadoData.funcionariosUids)
      ? credenciadoData.funcionariosUids
      : [];

    if (funcionariosUids.length === 0) {
      console.log("Credenciado sem funcionariosUids:", credenciadoId);
      return;
    }

    const tokenEntries = await loadTokenEntriesForUids(funcionariosUids);
    if (tokenEntries.length === 0) {
      console.log("Nenhum token encontrado para:", funcionariosUids);
      return;
    }

    const result = await sendPushToTokenEntries({
      tokenEntries,
      title: notification.title,
      body: notification.body,
      data: {
        type: "sinistro_update",
        sinistroId,
        credenciadoId,
        protocol: String(after.protocol || ""),
        status: String(after.status || ""),
        priority: String(after.priority || ""),
        notificationType: notification.type,
      },
    });

    console.log("Tentativa de notificação concluída:", {
      sinistroId,
      credenciadoId,
      tokens: tokenEntries.length,
      successCount: result.successCount,
      failureCount: result.failureCount,
    });
  }
);

// Dispara a geracao do laudo tecnico assim que a vistoria entra em analise
// operacional (mecanico terminou de coletar fotos/audio/relato — ver
// EM_ANALISE_OPERACIONAL em vistoria_chat_session_service.dart no app mobile).
// So enfileira (Cloud Tasks -> laudo-service no Cloud Run); a geracao em si
// roda la, nao aqui, porque envolve Puppeteer/Chromium e Gemini multimodal —
// coisa pesada demais pro runtime de Cloud Functions.
let cachedTasksClient = null;

function getTasksClient() {
  if (!cachedTasksClient) cachedTasksClient = new CloudTasksClient();
  return cachedTasksClient;
}

async function enqueuePdfGeneration({ serviceUrl, taskKind, sinistroId, vistoriaId }) {
  if (!serviceUrl) {
    console.warn(`${taskKind}: URL nao configurada — pulando`, { sinistroId, vistoriaId });
    return;
  }

  const client = getTasksClient();
  const queuePath = client.queuePath(
    FIREBASE_PROJECT_ID,
    LAUDO_TASKS_LOCATION.value(),
    LAUDO_TASKS_QUEUE.value()
  );

  const payload = { sinistroId, vistoriaId };
  const invokerServiceAccount = LAUDO_INVOKER_SERVICE_ACCOUNT.value();

  const task = {
    httpRequest: {
      httpMethod: "POST",
      url: serviceUrl,
      headers: { "Content-Type": "application/json" },
      body: Buffer.from(JSON.stringify(payload)).toString("base64"),
      ...(invokerServiceAccount
        ? { oidcToken: { serviceAccountEmail: invokerServiceAccount } }
        : {}),
    },
    // Nome deterministico: se o mesmo sinistro/vistoria disparar duas vezes
    // (ex: retry do proprio Firestore trigger), o Cloud Tasks rejeita a
    // segunda com ALREADY_EXISTS em vez de gerar o documento duplicado.
    name: `${queuePath}/tasks/${taskKind}-${sinistroId}-${vistoriaId}`,
  };

  try {
    await client.createTask({ parent: queuePath, task });
    console.log(`${taskKind} enfileirado:`, { sinistroId, vistoriaId });
  } catch (err) {
    if (err?.code === 6 /* ALREADY_EXISTS */) {
      console.log(`${taskKind} ja enfileirado anteriormente, ignorando:`, { sinistroId, vistoriaId });
      return;
    }
    console.error(`Falha ao enfileirar ${taskKind}:`, err);
    throw err;
  }
}

function enqueueLaudoGeneration({ sinistroId, vistoriaId }) {
  return enqueuePdfGeneration({
    serviceUrl: LAUDO_SERVICE_URL.value(),
    taskKind: "laudo",
    sinistroId,
    vistoriaId,
  });
}

function enqueueOrcamentoAprovado({ sinistroId, vistoriaId }) {
  return enqueuePdfGeneration({
    serviceUrl: ORCAMENTO_SERVICE_URL.value(),
    taskKind: "orcamento",
    sinistroId,
    vistoriaId,
  });
}

exports.onVistoriaEnterAnaliseOperacional = onDocumentWritten(
  {
    document: "sinistro/{sinistroId}",
    region: "us-central1",
  },
  async (event) => {
    if (!event.data) return;

    const afterExists = event.data.after.exists;
    if (!afterExists) return;

    const before = event.data.before.exists ? event.data.before.data() : null;
    const after = event.data.after.data();
    if (!after) return;

    const beforeStatus = String(before?.vistoriaAtualStatus || "").toUpperCase();
    const afterStatus = String(after.vistoriaAtualStatus || "").toUpperCase();

    if (beforeStatus === afterStatus || afterStatus !== "EM_ANALISE_OPERACIONAL") {
      return;
    }

    const sinistroId = event.params.sinistroId;
    const vistoriaId = String(after.vistoriaAtualId || "").trim();

    if (!vistoriaId) {
      console.warn("Sinistro entrou em analise operacional sem vistoriaAtualId:", sinistroId);
      return;
    }

    await enqueueLaudoGeneration({ sinistroId, vistoriaId });
  }
);

// Dispara a geracao do PDF de orcamento aprovado assim que o sinistro e
// aprovado pelo analista (sinistro.status vira FINALIZADO — ver
// /api/sinistros/[id]/finalizar no web-argos e markAsFinalizada no app
// mobile, os dois caminhos que podem fazer essa transicao). Reusa
// vistoriaAtualId, que a rota de finalizar nao mexe (so ela ja estava
// certa desde que a vistoria entrou em analise operacional).
exports.onSinistroFinalizado = onDocumentWritten(
  {
    document: "sinistro/{sinistroId}",
    region: "us-central1",
  },
  async (event) => {
    if (!event.data) return;

    const afterExists = event.data.after.exists;
    if (!afterExists) return;

    const before = event.data.before.exists ? event.data.before.data() : null;
    const after = event.data.after.data();
    if (!after) return;

    const beforeStatus = String(before?.status || "").toUpperCase();
    const afterStatus = String(after.status || "").toUpperCase();

    if (beforeStatus === afterStatus || afterStatus !== "FINALIZADO") {
      return;
    }

    const sinistroId = event.params.sinistroId;
    const vistoriaId = String(after.vistoriaAtualId || "").trim();

    if (!vistoriaId) {
      console.warn("Sinistro finalizado sem vistoriaAtualId:", sinistroId);
      return;
    }

    await enqueueOrcamentoAprovado({ sinistroId, vistoriaId });
  }
);

exports.sendArgosAudioMessage = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuário precisa estar autenticado.");
    }

    const uid = request.auth.uid;
    const data = request.data || {};

    const idvistoria = String(data.idvistoria || data.inspectionId || "").trim();
    const sinistroId = String(data.sinistroId || "").trim();
    const audioId = String(data.audioId || `audio_${Date.now()}`).trim();
    const storagePath = String(data.storagePath || "").trim();
    const bucket = String(data.bucket || "").trim();

    if (!idvistoria) throw new HttpsError("invalid-argument", "idvistoria é obrigatório.");
    if (!storagePath) throw new HttpsError("invalid-argument", "storagePath é obrigatório.");

    const bucketName = bucket || `${FIREBASE_PROJECT_ID}.firebasestorage.app`;
    const gcsUri = `gs://${bucketName}/${storagePath}`;

    const db = admin.firestore();
    const vistoriaRef = db.collection("vistorias").doc(idvistoria);
    const audioRef = vistoriaRef.collection("audios").doc(audioId);

    try {
      await audioRef.set(
        {
          audioId,
          idvistoria,
          sinistroId,
          uid,
          storagePath,
          gcsUri,
          transcriptionStatus: "processing",
          reviewStatus: "pending",
          agentStatus: "pending",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      console.log("Iniciando transcrição do áudio:", {
        idvistoria,
        sinistroId,
        audioId,
        storagePath,
        gcsUri,
      });

      const vistoriaSnap = await vistoriaRef.get();
      const vistoria = vistoriaSnap.data() || {};

      const sinistroSnap = sinistroId
        ? await db.collection("sinistro").doc(sinistroId).get()
        : null;
      const sinistro = sinistroSnap?.exists ? sinistroSnap.data() || {} : {};
      const veiculo = await loadVehicleContext({ db, sinistro });

      const audioAnalysis = await transcribeAndReviewAudioWithGemini({
        gcsUri,
        idvistoria,
        sinistroId,
        vistoria,
      });

      const originalTranscript = audioAnalysis.transcricaoOriginal;
      const revisedTranscript = audioAnalysis.transcricaoRevisada;

      if (!originalTranscript && !revisedTranscript) {
        throw new Error("Gemini não conseguiu transcrever o áudio.");
      }

      await audioRef.set(
        {
          transcriptionStatus: "done",
          transcricaoOriginal: originalTranscript,
          reviewStatus: "done",
          transcricaoRevisada: revisedTranscript,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      console.log("Áudio transcrito pelo Gemini:", {
        idvistoria,
        audioId,
        originalChars: originalTranscript.length,
        revisedChars: revisedTranscript.length,
      });

      const freshSessionParameters = buildArgosSessionParameters({
  inspectionId: idvistoria,
  sinistroId,
  vistoria,
  sinistro,
  veiculo,
  extra: data.parameters || {},
});

const savedAgentParameters = vistoria?.agentParameters || {};

const sessionParameters = mergeSessionParameters(
  savedAgentParameters,
  freshSessionParameters
);

console.log("Parâmetros enviados ao agente Argos no áudio:", sessionParameters);

    const agentResult = await sendTextToArgosAgent({
      uid,
      inspectionId: idvistoria,
      text: revisedTranscript,
      sessionParameters,
      chatmessages: vistoria?.chatmessages || [],
      currentAgent: vistoria?.agentCurrentAgent || "",
    });

    const reply = agentResult.reply;

    await saveAgentStateToVistoria({
      idvistoria,
      currentAgent: agentResult.currentAgent,
    });

      const now = admin.firestore.Timestamp.now();

      await vistoriaRef.set(
        {
          ultimaTranscricaoOriginal: originalTranscript,
          ultimaTranscricaoRevisada: revisedTranscript,
          transcriptionStatus: "done",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          chatmessages: admin.firestore.FieldValue.arrayUnion(
            {
              role: "user",
              type: "audio_transcription",
              text: revisedTranscript,
              originalText: originalTranscript,
              audioId,
              storagePath,
              createdAt: now,
            },
            {
              role: "ai",
              type: "text",
              text: reply,
              createdAt: now,
            }
          ),
        },
        { merge: true }
      );

      await audioRef.set(
        {
          agentStatus: "done",
          agentReply: reply,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      console.log("Áudio processado e enviado ao agente Argos:", {
        idvistoria,
        audioId,
        replyChars: reply.length,
      });

      return {
        audioId,
        idvistoria,
        sinistroId,
        originalTranscript,
        revisedTranscript,
        reply,
        sessionParameters,
      };
    } catch (error) {
      console.error("Erro em sendArgosAudioMessage:", error);
      const audioError = normalizeArgosAudioError(error);

      await audioRef.set(
        {
          transcriptionStatus: "error",
          reviewStatus: "error",
          agentStatus: "error",
          errorCode: audioError.code,
          errorMessage: audioError.message,
          errorDetails: audioError.details,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      throw new HttpsError(audioError.httpsCode, audioError.message, {
        code: audioError.code,
        message: error.message || String(error),
        details: audioError.details,
      });
    }
  }
);

function normalizeArgosAudioError(error) {
  const message = String(error?.message || error || "");
  const causeMessage = String(error?.cause?.message || "");
  const combinedMessage = `${message}\n${causeMessage}`.toLowerCase();
  const statusCode = Number(error?.code || error?.cause?.code || 0);

  if (
    statusCode === 403 &&
    combinedMessage.includes("dunning") &&
    combinedMessage.includes("deny")
  ) {
    return {
      httpsCode: "failed-precondition",
      code: "vertex-ai-billing-denied",
      message:
        "O projeto está bloqueado para usar o Vertex AI/Gemini por cobrança ou faturamento. Verifique a conta de faturamento do projeto fho-argos e tente enviar o áudio novamente.",
      details: {
        provider: "vertex-ai",
        projectId: FIREBASE_PROJECT_ID,
        reason: "billing-or-dunning-denied",
      },
    };
  }

  if (statusCode === 403) {
    return {
      httpsCode: "permission-denied",
      code: "vertex-ai-permission-denied",
      message:
        "A função não tem permissão para usar o Vertex AI/Gemini neste projeto.",
      details: {
        provider: "vertex-ai",
        projectId: FIREBASE_PROJECT_ID,
      },
    };
  }

  return {
    httpsCode: "internal",
    code: "audio-processing-error",
    message: "Não foi possível processar o áudio do chat.",
    details: {
      provider: "argos-audio",
    },
  };
}

function buildSinistroNotification({ sinistroId, before, after, isCreate }) {
  const protocol = String(after.protocol || sinistroId);
  const vehicle = after.veiculoSnapshot || after.vehicleSnapshot || {};
  const plate = String(vehicle.placa || after.plate || "");
  const brand = String(vehicle.marca || "");
  const model = String(vehicle.modelo || after.vehicle || "");
  const claimType = String(after.claimType || "Vistoria");
  const vehicleLabel = [brand, model, plate].filter((item) => item && item.trim()).join(" ");

  if (isCreate) {
    return {
      type: "sinistro_created",
      title: "Nova vistoria atribuída",
      body: `${protocol} · ${vehicleLabel || claimType}`,
    };
  }

  if (String(before?.status || "") !== String(after.status || "")) {
    return {
      type: "status_changed",
      title: "Status da vistoria atualizado",
      body: `${protocol} mudou para ${after.status || "novo status"}`,
    };
  }

  if (String(before?.priority || "") !== String(after.priority || "")) {
    return {
      type: "priority_changed",
      title: "Prioridade da vistoria alterada",
      body: `${protocol} agora está com prioridade ${after.priority}`,
    };
  }

  if (String(before?.scheduledDate || "") !== String(after.scheduledDate || "")) {
    return {
      type: "schedule_changed",
      title: "Agendamento atualizado",
      body: `${protocol} teve o horário de vistoria alterado`,
    };
  }

  const beforeCheckIn = String(before?.checkInAt || "");
  const afterCheckIn = String(after.checkInAt || "");

  if (!beforeCheckIn && afterCheckIn) {
    return {
      type: "checkin_created",
      title: "Check-in realizado",
      body: `${protocol} teve check-in registrado na oficina`,
    };
  }

  if (String(before?.chatStatus || "") !== String(after.chatStatus || "")) {
    return {
      type: "chat_status_changed",
      title: "Chat da vistoria atualizado",
      body: `${protocol} está com chat ${after.chatStatus || "atualizado"}`,
    };
  }

  return {
    type: "sinistro_updated",
    title: "Vistoria atualizada",
    body: `${protocol} recebeu uma nova atualização`,
  };
}

function shouldIgnoreSinistroNotificationUpdate(before, after) {
  const ignoredFields = new Set([
    "activeViewers",
    "activeViewersCount",
    "activeViewersUpdatedAt",
    "viewersUpdatedAt",
    "lastViewerAt",
    "lastMessage",
    "lastMessageAt",
    "lastMessageBy",
    "agentBusinessExpiresAt",
    "agentSessionTtlSeconds",
    "ttlBusinessHours",
    "workdays",
    "updatedAt",
  ]);

  const changedFields = getChangedTopLevelFields(before, after);
  if (changedFields.length === 0) return true;

  return changedFields.every((field) => ignoredFields.has(field));
}

function getChangedTopLevelFields(before, after) {
  const keys = new Set([...Object.keys(before || {}), ...Object.keys(after || {})]);
  const changed = [];

  for (const key of keys) {
    const beforeValue = before ? before[key] : undefined;
    const afterValue = after ? after[key] : undefined;

    if (stableStringify(beforeValue) !== stableStringify(afterValue)) {
      changed.push(key);
    }
  }

  return changed;
}

function stableStringify(value) {
  if (value === null || value === undefined) return String(value);
  if (Array.isArray(value)) return `[${value.map((item) => stableStringify(item)).join(",")}]`;

  if (typeof value === "object") {
    if (typeof value.toMillis === "function") return `timestamp:${value.toMillis()}`;

    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${key}:${stableStringify(value[key])}`).join(",")}}`;
  }

  return JSON.stringify(value);
}

async function loadTokenEntriesForUids(uids) {
  const db = admin.firestore();
  const tokenMap = new Map();

  for (const uid of uids) {
    const safeUid = String(uid || "").trim();
    if (!safeUid) continue;

    const tokensSnap = await db.collection("userDevices").doc(safeUid).collection("tokens").get();

    tokensSnap.forEach((doc) => {
      const data = doc.data() || {};
      const token = String(data.token || "").trim();
      if (!token) return;

      tokenMap.set(token, { token, uid: safeUid, ref: doc.ref });
    });
  }

  return Array.from(tokenMap.values());
}

async function sendPushToTokenEntries({ tokenEntries, title, body, data }) {
  const batches = chunkArray(tokenEntries, 500);
  let totalSuccess = 0;
  let totalFailure = 0;

  for (const batchEntries of batches) {
    const tokens = batchEntries.map((entry) => entry.token);

    const response = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      data,
      android: {
        priority: "high",
        notification: { sound: "default" },
      },
    });

    totalSuccess += response.successCount;
    totalFailure += response.failureCount;

    console.log("FCM batch:", {
      successCount: response.successCount,
      failureCount: response.failureCount,
    });

    const cleanupPromises = [];

    response.responses.forEach((result, index) => {
      const tokenEntry = batchEntries[index];

      if (result.success) {
        console.log("FCM sucesso:", {
          uid: tokenEntry.uid,
          tokenPreview: maskToken(tokenEntry.token),
          messageId: result.messageId,
        });
        return;
      }

      const code = result.error?.code || "";
      const message = result.error?.message || "";

      console.error("FCM falhou:", {
        uid: tokenEntry.uid,
        tokenPreview: maskToken(tokenEntry.token),
        code,
        message,
      });

      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        cleanupPromises.push(tokenEntry.ref.delete().catch(() => null));
      }
    });

    await Promise.all(cleanupPromises);
  }

  return { successCount: totalSuccess, failureCount: totalFailure };
}

async function transcribeAndReviewAudioWithGemini({ gcsUri, idvistoria, sinistroId, vistoria }) {
  console.log("Gemini recebendo áudio:", gcsUri);

  const match = gcsUri.match(/^gs:\/\/([^/]+)\/(.+)$/);
  if (!match) throw new Error(`GCS URI inválida: ${gcsUri}`);

  const bucketName = match[1];
  const filePath = match[2];
  const bucket = admin.storage().bucket(bucketName);
  const file = bucket.file(filePath);
  const [exists] = await file.exists();

  if (!exists) throw new Error(`Arquivo não encontrado no Storage: ${gcsUri}`);

  const [metadata] = await file.getMetadata();

  console.log("Metadata do áudio para Gemini:", {
    bucketName,
    filePath,
    size: metadata.size,
    contentType: metadata.contentType,
    name: metadata.name,
    updated: metadata.updated,
  });

  const size = Number(metadata.size || 0);
  if (!size || size < 1000) throw new Error(`Arquivo de áudio muito pequeno ou vazio. Size: ${metadata.size}`);

  const [audioBuffer] = await file.download();

  console.log("Áudio baixado para Gemini:", {
    bytes: audioBuffer.length,
    isBuffer: Buffer.isBuffer(audioBuffer),
  });

  if (!audioBuffer || audioBuffer.length < 1000) {
    throw new Error(`Buffer de áudio vazio ou muito pequeno. Bytes: ${audioBuffer?.length || 0}`);
  }

  const mimeType = normalizeAudioMimeType(metadata.contentType);
  const placa = String(vistoria.placa || "").trim();
  const veiculo = String(vistoria.veiculo || "").trim();
  const cliente = String(vistoria.cliente || "").trim();
  const descricaoArtigos = String(vistoria.descricaoArtigos || "").trim();
  const observacoes = String(vistoria.observacoes || "").trim();

const prompt = `
Você é um assistente técnico de vistoria automotiva.

Analise o áudio enviado pelo mecânico e retorne obrigatoriamente um JSON válido, sem markdown, sem crases e sem explicações.

Formato obrigatório:
{
  "transcricaoOriginal": "texto transcrito do áudio",
  "transcricaoRevisada": "texto revisado com clareza técnica"
}

Regras:
- Transcreva o áudio em português do Brasil.
- Corrija apenas gramática, pontuação, concordância e clareza técnica.
- Não invente danos.
- Não adicione peças, locais de dano ou conclusões que não estejam no áudio.
- Não transforme dúvida em certeza.
- Preserve expressões de incerteza como "parece", "aparenta", "possivelmente".
- Se algum trecho estiver incompreensível, use "[inaudível]".
- A transcricaoOriginal deve ser próxima do que foi falado.
- A transcricaoRevisada deve ser adequada para um relatório técnico, mas sem mudar o sentido.
- Mesmo se o áudio for muito curto, retorne os dois campos completos.
- Não retorne JSON dentro de string.
- Não corte o JSON.
- Se a transcricaoRevisada for igual à original, repita o mesmo texto nos dois campos.

Contexto da vistoria:
- Vistoria: ${idvistoria}
- Sinistro: ${sinistroId}
- Placa: ${placa}
- Veículo: ${veiculo}
- Cliente: ${cliente}
- Relato inicial do cliente: ${descricaoArtigos}
- Observações: ${observacoes}
`.trim();

  const model = getGeminiReviewModel();

  const result = await model.generateContent({
    contents: [
      {
        role: "user",
        parts: [
          { text: prompt },
          {
            inlineData: {
              mimeType,
              data: audioBuffer.toString("base64"),
            },
          },
        ],
      },
    ],
  });

  const rawText = extractGeminiText(result);
  console.log("Resposta bruta Gemini áudio:", rawText);

  const parsed = parseGeminiAudioJson(rawText);

  const transcricaoOriginal = String(
    parsed.transcricaoOriginal || parsed.original || parsed.transcript || ""
  ).trim();

  const transcricaoRevisada = String(
    parsed.transcricaoRevisada || parsed.revisada || parsed.revised || transcricaoOriginal || ""
  ).trim();

  if (!transcricaoOriginal && !transcricaoRevisada) {
    throw new Error(`Gemini não retornou transcrição válida. Resposta: ${rawText}`);
  }

  return {
    transcricaoOriginal: transcricaoOriginal || transcricaoRevisada,
    transcricaoRevisada: transcricaoRevisada || transcricaoOriginal,
  };
}

function normalizeAudioMimeType(contentType) {
  const clean = String(contentType || "").trim().toLowerCase();

  if (clean.includes("mpeg") || clean.includes("mp3")) return "audio/mpeg";
  if (clean.includes("mp4") || clean.includes("m4a")) return "audio/mp4";
  if (clean.includes("aac")) return "audio/aac";
  if (clean.includes("wav")) return "audio/wav";
  if (clean.includes("webm")) return "audio/webm";

  return "audio/mpeg";
}

function extractGeminiText(result) {
  const candidates = result?.response?.candidates || [];
  const parts = candidates[0]?.content?.parts || [];
  return parts.map((part) => part.text || "").join("").trim();
}

function parseGeminiAudioJson(rawText) {
  const cleanText = String(rawText || "")
    .trim()
    .replace(/^```json/i, "")
    .replace(/^```/i, "")
    .replace(/```$/i, "")
    .trim();

  const parsedDirect = safeJsonParse(cleanText);

  if (parsedDirect) {
    return normalizeGeminiAudioParsedObject(parsedDirect, cleanText);
  }

  const jsonObjectText = extractFirstJsonObject(cleanText);
  const parsedObject = safeJsonParse(jsonObjectText);

  if (parsedObject) {
    return normalizeGeminiAudioParsedObject(parsedObject, cleanText);
  }

  const originalFromBrokenJson =
    extractJsonStringValue(cleanText, "transcricaoOriginal") ||
    extractJsonStringValue(cleanText, "transcriçãoOriginal") ||
    extractJsonStringValue(cleanText, "original") ||
    extractJsonStringValue(cleanText, "transcript");

  const revisedFromBrokenJson =
    extractJsonStringValue(cleanText, "transcricaoRevisada") ||
    extractJsonStringValue(cleanText, "transcriçãoRevisada") ||
    extractJsonStringValue(cleanText, "revisada") ||
    extractJsonStringValue(cleanText, "revised");

  const fallbackText = cleanBrokenGeminiText(cleanText);

  const transcricaoOriginal = String(
    originalFromBrokenJson ||
      revisedFromBrokenJson ||
      fallbackText ||
      ""
  ).trim();

  const transcricaoRevisada = String(
    revisedFromBrokenJson ||
      originalFromBrokenJson ||
      fallbackText ||
      ""
  ).trim();

  console.warn("Gemini retornou JSON inválido. Aplicando recuperação:", {
    rawText: cleanText,
    transcricaoOriginal,
    transcricaoRevisada,
  });

  return {
    transcricaoOriginal,
    transcricaoRevisada,
  };
}

function safeJsonParse(text) {
  if (!text || typeof text !== "string") return null;

  try {
    return JSON.parse(text);
  } catch (_) {
    return null;
  }
}

function extractFirstJsonObject(text) {
  if (!text) return "";

  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");

  if (start < 0 || end < 0 || end <= start) {
    return "";
  }

  return text.substring(start, end + 1).trim();
}

function extractJsonStringValue(text, key) {
  if (!text || !key) return "";

  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  const regex = new RegExp(
    `"${escapedKey}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)`,
    "i"
  );

  const match = text.match(regex);

  if (!match || !match[1]) {
    return "";
  }

  let value = match[1];

  value = value
    .replace(/",\s*"transcricaoRe.*$/i, "")
    .replace(/",\s*"transcriçãoRe.*$/i, "")
    .replace(/",\s*"revisada.*$/i, "")
    .replace(/",\s*"revised.*$/i, "")
    .trim();

  try {
    return JSON.parse(`"${value}"`);
  } catch (_) {
    return value
      .replace(/\\"/g, '"')
      .replace(/\\n/g, "\n")
      .replace(/\\\\/g, "\\")
      .trim();
  }
}

function normalizeGeminiAudioParsedObject(parsed, fallbackText) {
  const transcricaoOriginal = String(
    parsed.transcricaoOriginal ||
      parsed["transcriçãoOriginal"] ||
      parsed.original ||
      parsed.transcript ||
      ""
  ).trim();

  const transcricaoRevisada = String(
    parsed.transcricaoRevisada ||
      parsed["transcriçãoRevisada"] ||
      parsed.revisada ||
      parsed.revised ||
      transcricaoOriginal ||
      ""
  ).trim();

  return {
    transcricaoOriginal:
      cleanBrokenGeminiText(transcricaoOriginal) ||
      cleanBrokenGeminiText(transcricaoRevisada) ||
      cleanBrokenGeminiText(fallbackText),

    transcricaoRevisada:
      cleanBrokenGeminiText(transcricaoRevisada) ||
      cleanBrokenGeminiText(transcricaoOriginal) ||
      cleanBrokenGeminiText(fallbackText),
  };
}

function cleanBrokenGeminiText(text) {
  const value = String(text || "").trim();

  if (!value) return "";

  // Evita salvar JSON quebrado inteiro como transcrição.
  if (
    value.startsWith("{") &&
    value.includes("transcricaoOriginal")
  ) {
    const recovered =
      extractJsonStringValue(value, "transcricaoOriginal") ||
      extractJsonStringValue(value, "transcricaoRevisada");

    return recovered.trim();
  }

  return value
    .replace(/^"+/, "")
    .replace(/"+$/, "")
    .trim();
}

async function loadArgosInspectionContext({ inspectionId, sinistroId }) {
  const db = admin.firestore();
  const cleanInspectionId = String(inspectionId || "").trim();
  const cleanSinistroId = String(sinistroId || "").trim();

  let vistoria = {};
  let resolvedSinistroId = cleanSinistroId;

  if (cleanInspectionId) {
    const vistoriaSnap = await db.collection("vistorias").doc(cleanInspectionId).get();
    if (vistoriaSnap.exists) {
      vistoria = vistoriaSnap.data() || {};
      resolvedSinistroId = String(vistoria.sinistroId || resolvedSinistroId || "").trim();
    }
  }

  if (!Object.keys(vistoria).length && cleanInspectionId) {
    const vistoriaQuery = await db
      .collection("vistorias")
      .where("sinistroId", "==", cleanInspectionId)
      .limit(1)
      .get();

    if (!vistoriaQuery.empty) {
      vistoria = vistoriaQuery.docs[0].data() || {};
      resolvedSinistroId = String(vistoria.sinistroId || cleanInspectionId).trim();
    }
  }

  if (!resolvedSinistroId && cleanInspectionId && cleanInspectionId.startsWith("ARG-")) {
    resolvedSinistroId = cleanInspectionId;
  }

  let sinistro = {};

  if (resolvedSinistroId) {
    const sinistroSnap = await db.collection("sinistro").doc(resolvedSinistroId).get();
    if (sinistroSnap.exists) sinistro = sinistroSnap.data() || {};
  }

  const veiculo = await loadVehicleContext({ db, sinistro });

  return { vistoria, sinistro, veiculo, sinistroId: resolvedSinistroId };
}

async function loadVehicleContext({ db, sinistro = {} }) {
  const veiculoSnapshot = asObject(sinistro.veiculoSnapshot || sinistro.vehicleSnapshot);
  const veiculoId = str(sinistro.veiculoId || veiculoSnapshot.id);
  const placa = str(veiculoSnapshot.placa || sinistro.plate || sinistro.placa);

  if (veiculoId) {
    const byIdSnap = await db.collection("veiculos").doc(veiculoId).get();
    if (byIdSnap.exists) return byIdSnap.data() || {};
  }

  if (placa) {
    const byPlateSnap = await db
      .collection("veiculos")
      .where("placa", "==", placa)
      .limit(1)
      .get();

    if (!byPlateSnap.empty) return byPlateSnap.docs[0].data() || {};
  }

  return {};
}

function buildArgosSessionParameters({ inspectionId, sinistroId, vistoria = {}, sinistro = {}, veiculo = {}, extra = {} }) {
  const veiculoSnapshot = asObject(sinistro.veiculoSnapshot || sinistro.vehicleSnapshot);
  const veiculoCadastro = asObject(veiculo);
  const clienteSnapshot = asObject(sinistro.clienteSnapshot);
  const credenciadoSnapshot = asObject(sinistro.credenciadoSnapshot);
  const seguradoraSnapshot = asObject(sinistro.seguradoraSnapshot);

  const marca = str(veiculoSnapshot.marca || veiculoCadastro.marca);
  const modelo = str(veiculoSnapshot.modelo || veiculoCadastro.modelo);
  const modeloCompleto = [marca, modelo].filter(Boolean).join(" ").trim();
  const ano = str(
    veiculoSnapshot.anoFabricacao ||
      veiculoSnapshot.anoModelo ||
      veiculoSnapshot.ano ||
      veiculoCadastro.anoFabricacao ||
      veiculoCadastro.anoModelo ||
      veiculoCadastro.ano
  );

  return removeEmptyValues({
    placa_veiculo:
      extra.placa_veiculo ||
      extra.placaVeiculo ||
      vistoria.placa ||
      veiculoSnapshot.placa ||
      veiculoCadastro.placa ||
      sinistro.plate ||
      sinistro.placa,

    modelo_veiculo:
      extra.modelo_veiculo ||
      extra.modeloVeiculo ||
      vistoria.veiculo ||
      modeloCompleto ||
      veiculoCadastro.modelo ||
      sinistro.vehicle ||
      sinistro.veiculo,

    marca_veiculo:
      extra.marca_veiculo ||
      extra.marcaVeiculo ||
      marca ||
      veiculoCadastro.marca ||
      sinistro.marca,

    ano_veiculo:
      extra.ano_veiculo ||
      extra.anoVeiculo ||
      ano ||
      sinistro.ano,

    ano_fabricacao_veiculo:
      extra.ano_fabricacao_veiculo ||
      extra.anoFabricacaoVeiculo ||
      veiculoSnapshot.anoFabricacao ||
      veiculoCadastro.anoFabricacao,

    ano_modelo_veiculo:
      extra.ano_modelo_veiculo ||
      extra.anoModeloVeiculo ||
      veiculoSnapshot.anoModelo ||
      veiculoCadastro.anoModelo,

    cor_veiculo:
      extra.cor_veiculo ||
      extra.corVeiculo ||
      veiculoSnapshot.cor ||
      veiculoCadastro.cor ||
      sinistro.cor,

    chassi_veiculo:
      extra.chassi_veiculo ||
      extra.chassiVeiculo ||
      veiculoSnapshot.chassi ||
      veiculoSnapshot.chassis ||
      veiculoCadastro.chassi ||
      veiculoCadastro.chassis ||
      sinistro.chassi ||
      sinistro.chassis,

    renavam_veiculo:
      extra.renavam_veiculo ||
      extra.renavamVeiculo ||
      veiculoSnapshot.renavam ||
      veiculoCadastro.renavam ||
      sinistro.renavam,

    combustivel_veiculo:
      extra.combustivel_veiculo ||
      extra.combustivelVeiculo ||
      veiculoSnapshot.combustivel ||
      veiculoCadastro.combustivel ||
      sinistro.combustivel,

    veiculo_id:
      extra.veiculo_id ||
      extra.veiculoId ||
      sinistro.veiculoId ||
      veiculoSnapshot.id ||
      veiculoCadastro.id,

    proprietario_veiculo:
      extra.proprietario_veiculo ||
      extra.proprietarioVeiculo ||
      veiculoCadastro.proprietario ||
      sinistro.clienteId,

    status_veiculo:
      extra.status_veiculo ||
      extra.statusVeiculo ||
      veiculoCadastro.status,

    tipo_cobertura_veiculo:
      extra.tipo_cobertura_veiculo ||
      extra.tipoCoberturaVeiculo ||
      veiculoCadastro.tipoCobertura,

    relato_cliente_simulado:
      extra.relato_cliente_simulado ||
      extra.relatoClienteSimulado ||
      vistoria.descricaoArtigos ||
      sinistro.damageDescription ||
      sinistro.descricaoArtigos ||
      vistoria.observacoes ||
      sinistro.observations ||
      sinistro.observacoes,

    ocorrido_sinistro:
      extra.ocorrido_sinistro ||
      extra.ocorridoSinistro ||
      sinistro.damageDescription ||
      sinistro.descricaoArtigos ||
      vistoria.descricaoArtigos,

    observacoes_sinistro:
      extra.observacoes_sinistro ||
      extra.observacoesSinistro ||
      sinistro.observations ||
      sinistro.observacoes ||
      vistoria.observacoes,

    id_vistoria: vistoria.idvistoria || inspectionId,
    sinistro_id: vistoria.sinistroId || sinistroId,
    protocolo_sinistro: sinistro.protocol || sinistroId,
    tipo_vistoria: extra.tipo_vistoria || extra.tipoVistoria || vistoria.tipoVistoria,

    cliente_nome:
      vistoria.cliente ||
      clienteSnapshot.nomeCompleto ||
      sinistro.owner ||
      sinistro.cliente,

    cliente_id: sinistro.clienteId,
    cliente_documento: clienteSnapshot.cpfCnpj,
    cliente_email: clienteSnapshot.email,
    cliente_telefone: clienteSnapshot.telefone,

    oficina_nome:
      vistoria.credenciado ||
      credenciadoSnapshot.name ||
      sinistro.workshop ||
      sinistro.credenciadoNome,

    credenciado_id: sinistro.credenciadoId,
    credenciado_nome: credenciadoSnapshot.name || vistoria.credenciado,
    credenciado_email: credenciadoSnapshot.email,
    credenciado_telefone: credenciadoSnapshot.phone,
    credenciado_endereco: credenciadoSnapshot.address || vistoria.local,
    credenciado_cidade: credenciadoSnapshot.city,
    credenciado_uf: credenciadoSnapshot.uf,

    seguradora_id: sinistro.seguradoraId,
    seguradora_nome: seguradoraSnapshot.name,
    seguradora_cnpj: seguradoraSnapshot.cnpj,

    prioridade_sinistro: sinistro.priority,
    tipo_sinistro: sinistro.claimType,
    status_sinistro: sinistro.status,
    dias_no_status_sinistro: sinistro.daysInStage,
    data_entrada_sinistro: sinistro.entryDate,
    data_agendada_sinistro: sinistro.scheduledDate,
    checkin_sinistro: sinistro.checkInAt || vistoria.checkInAt,
    status_atualizado_em_sinistro: sinistro.statusUpdatedAt,
    chat_habilitado_sinistro: sinistro.chatEnabled,
    chat_status_sinistro: sinistro.chatStatus,
    ultima_mensagem_sinistro: sinistro.lastMessage,
    ultima_mensagem_em_sinistro: sinistro.lastMessageAt,
    ultima_mensagem_por_sinistro: sinistro.lastMessageBy,
  });
}

function removeEmptyValues(data) {
  const clean = {};

  for (const [key, value] of Object.entries(data || {})) {
    if (value === undefined || value === null) continue;
    const text = String(value).trim();
    if (!text || text === "null" || text === "undefined") continue;
    clean[key] = text;
  }

  return clean;
}

function asObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value;
}

function str(value) {
  if (value === undefined || value === null) return "";
  return String(value).trim();
}

// ---------------------------------------------------------------------------
// Ponte para o agente ADK hospedado no Cloud Run (substitui o Dialogflow CX).
//
// O contrato HTTP abaixo foi conferido no código do ADK 2.8.0, não na doc:
//   - `cli/utils/common.py` define alias_generator=to_camel + populate_by_name,
//     então tanto camelCase quanto snake_case são aceitos no corpo.
//   - `cli/api_server.py` expõe GET/POST /apps/{app}/users/{uid}/sessions[/{sid}]
//     e POST /run, e `CreateSessionRequest` aceita `sessionId`, `state` e `events`.
//
// Duas decisões que importam:
//
// 1. O `state` inicial carrega `id_vistoria`. O prompt dos dois agentes usa
//    `{id_vistoria}` (sem `?`), então uma sessão criada sem esse state falha
//    ALTO em vez de renderizar silenciosamente uma instrução contraditória.
//
// 2. Quando a sessão não existe (cold start, deploy, reciclagem da instância),
//    ela é recriada JÁ COM o histórico de `vistorias/{id}.chatmessages`. Sem
//    isso, o Cloud Run reciclando no meio de uma vistoria faz o mecânico ser
//    cumprimentado de novo e perder tudo. O endpoint suporta isso de propósito
//    — ver `_validate_session_initialization_events` em api_server.py.
// ---------------------------------------------------------------------------

const ADK_APP_NAME = "vistoria_team";
const ADK_HTTP_TIMEOUT_MS = 500000;
// Teto de turnos reconstruídos: `chatmessages` é um array dentro do documento
// (limite de 1 MiB), e reenviar a conversa inteira a cada cold start custa
// tokens. Os últimos N turnos bastam para o agente retomar o fio.
const ADK_MAX_SEED_MESSAGES = 40;

let cachedAdkClient = null;
let cachedAdkAudience = "";

function getAdkBaseUrl() {
  const url = String(ARGOS_ADK_SERVICE_URL.value() || "").trim().replace(/\/+$/, "");

  if (!url) {
    throw new Error(
      "ARGOS_ADK_SERVICE_URL não configurada — aponte para a URL do Cloud Run do agente."
    );
  }

  return url;
}

async function getAdkClient(baseUrl) {
  if (cachedAdkClient && cachedAdkAudience === baseUrl) return cachedAdkClient;

  const auth = new GoogleAuth();
  // O serviço sobe com --no-allow-unauthenticated: o IAM do Cloud Run exige
  // um ID token OIDC assinado pelo Google, com a URL raiz como audience.
  cachedAdkClient = await auth.getIdTokenClient(baseUrl);
  cachedAdkAudience = baseUrl;

  return cachedAdkClient;
}

async function adkRequest({ baseUrl, method, path, body }) {
  const client = await getAdkClient(baseUrl);

  return client.request({
    url: `${baseUrl}${path}`,
    method,
    data: body,
    responseType: "json",
    timeout: ADK_HTTP_TIMEOUT_MS,
    validateStatus: () => true,
  });
}

function adkSessionsPath(uid) {
  return `/apps/${ADK_APP_NAME}/users/${encodeURIComponent(uid)}/sessions`;
}

// Converte `chatmessages` (formato do app: {role: 'user'|'ai'|'audio', text})
// para eventos do ADK. Só texto: o validador do ADK rejeita eventos que
// aleguem ser gerados por ele (tool calls reservadas, actions não-default).
function chatMessagesToAdkEvents(chatmessages, currentAgent) {
  // O autor das falas do agente vai como `agentCurrentAgent` (gravado no fim
  // do ultimo turno). Importa porque e assim que o ADK sabe quem estava com a
  // palavra: sem isso, uma reciclagem de instancia no meio do orcamento faria
  // a conversa voltar para o agente de vistoria e cumprimentar o mecanico de novo.
  const autorAgente = String(currentAgent || "").trim() || "VistoriaPeritoDigitalAgent";
  const mensagens = Array.isArray(chatmessages) ? chatmessages : [];
  const recentes = mensagens.slice(-ADK_MAX_SEED_MESSAGES);
  const eventos = [];

  recentes.forEach((mensagem, indice) => {
    const texto = String(mensagem?.text || "").trim();
    if (!texto) return;

    const ehAgente = mensagem?.role === "ai";

    eventos.push({
      id: `seed${indice}`,
      invocationId: `seed${indice}`,
      author: ehAgente ? autorAgente : "user",
      content: {
        role: ehAgente ? "model" : "user",
        parts: [{ text: texto }],
      },
    });
  });

  return eventos;
}

async function createAdkSession({ baseUrl, uid, sessionId, state, events }) {
  const res = await adkRequest({
    baseUrl,
    method: "POST",
    path: adkSessionsPath(uid),
    body: { sessionId, state, ...(events && events.length ? { events } : {}) },
  });

  // 409 = alguém criou entre o GET e o POST (duas mensagens em paralelo).
  if (res.status === 200 || res.status === 201 || res.status === 409) return;

  throw new Error(
    `ADK create_session ${res.status}: ${JSON.stringify(res.data)}`
  );
}

async function ensureAdkSession({ baseUrl, uid, sessionId, state, chatmessages, currentAgent }) {
  const res = await adkRequest({
    baseUrl,
    method: "GET",
    path: `${adkSessionsPath(uid)}/${encodeURIComponent(sessionId)}`,
  });

  if (res.status === 200) return { criada: false };

  if (res.status !== 404) {
    throw new Error(`ADK get_session ${res.status}: ${JSON.stringify(res.data)}`);
  }

  const events = chatMessagesToAdkEvents(chatmessages, currentAgent);

  await createAdkSession({ baseUrl, uid, sessionId, state, events });

  console.log("Sessão ADK recriada", {
    sessionId,
    turnosReconstruidos: events.length,
  });

  return { criada: true, turnosReconstruidos: events.length };
}

// Junta o texto que o usuário deve ver. Ignora o que não é fala do agente:
// eventos parciais (streaming), pensamento do modelo, chamadas de ferramenta
// e as respostas delas.
function extractAdkReply(events) {
  const lista = Array.isArray(events) ? events : [];
  const partes = [];

  for (const evento of lista) {
    if (evento?.partial === true) continue;

    const content = evento?.content || {};
    if (content.role === "user" || evento?.author === "user") continue;

    for (const parte of content.parts || []) {
      if (parte?.thought === true) continue;
      if (parte?.functionCall || parte?.functionResponse) continue;

      const texto = String(parte?.text || "").trim();
      if (texto) partes.push(texto);
    }
  }

  return (
    partes.join("\n").trim() ||
    "Entendi. Pode continuar descrevendo a vistoria."
  );
}

// Qual agente está com a palavra ao fim do turno — é o que substitui o
// `currentPage` do Dialogflow (que, aliás, nunca funcionou: o código gravava
// "[object Object]" e isValidCurrentPage sempre retornava false).
function extractAdkCurrentAgent(events) {
  const lista = Array.isArray(events) ? events : [];

  for (let i = lista.length - 1; i >= 0; i -= 1) {
    const autor = String(lista[i]?.author || "").trim();
    if (autor && autor !== "user") return autor;
  }

  return "";
}

async function sendTextToArgosAgent({
  uid,
  inspectionId,
  text,
  sessionParameters = {},
  chatmessages = [],
  currentAgent = "",
}) {
  const baseUrl = getAdkBaseUrl();

  // Mesmo sessionId determinístico de antes — preserva a correspondência
  // com o histórico já gravado no Firestore.
  const sessionId = createSessionId(uid, inspectionId);

  const state = {
    ...sessionParameters,
    id_vistoria: inspectionId,
    uid,
  };

  await ensureAdkSession({ baseUrl, uid, sessionId, state, chatmessages, currentAgent });

  const corpoRun = {
    appName: ADK_APP_NAME,
    userId: uid,
    sessionId,
    newMessage: { role: "user", parts: [{ text }] },
    // Reforça o id a cada turno: se a sessão foi recriada por outro
    // caminho, o agente continua sabendo de qual vistoria se trata.
    stateDelta: { id_vistoria: inspectionId },
    streaming: false,
  };

  let res = await adkRequest({ baseUrl, method: "POST", path: "/run", body: corpoRun });

  // A sessão do ADK vive na MEMÓRIA da instância do Cloud Run, e o serviço
  // roda com min-instances=0. Entre o ensureAdkSession acima e este /run a
  // instância pode ter sido reciclada — ou a requisição pode cair noutra
  // instância —, e aí volta 404 "Session not found". Verificar antes não
  // basta: é uma corrida. Quando isso acontece, recria a sessão (já com o
  // histórico do Firestore) e repete UMA vez.
  if (res.status === 404) {
    console.warn("Sessão ADK sumiu entre a verificação e o /run; recriando e repetindo.", { sessionId });

    await createAdkSession({
      baseUrl,
      uid,
      sessionId,
      state,
      events: chatMessagesToAdkEvents(chatmessages, currentAgent),
    });

    res = await adkRequest({ baseUrl, method: "POST", path: "/run", body: corpoRun });
  }

  if (res.status !== 200) {
    throw new Error(`ADK /run ${res.status}: ${JSON.stringify(res.data)}`);
  }

  return {
    reply: extractAdkReply(res.data),
    currentAgent: extractAdkCurrentAgent(res.data),
  };
}

function maskToken(token) {
  if (!token || token.length < 18) return token;
  return `${token.substring(0, 10)}...${token.substring(token.length - 8)}`;
}

function chunkArray(items, size) {
  const chunks = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}

function addBusinessHours(startDate, hours) {
  if (!hours || hours <= 0) return startDate;

  let current = normalizeBusinessStart(startDate);
  let remaining = hours;

  while (remaining > 0) {
    // Conta a hora que está prestes a decorrer (a que começa em `current`),
    // não a hora seguinte — checar a hora seguinte descartava a última hora
    // de sexta (23h-24h), porque o timestamp final cai bem na virada pra
    // sábado, mesmo essa hora inteira pertencendo à sexta.
    if (isBusinessDay(current)) {
      remaining -= 1;
    }

    current = normalizeBusinessStart(new Date(current.getTime() + 60 * 60 * 1000));
  }

  return current;
}

function normalizeBusinessStart(date) {
  let current = new Date(date);

  while (!isBusinessDay(current)) {
    current = new Date(current.getTime() + 24 * 60 * 60 * 1000);
  }

  return current;
}

function isBusinessDay(date) {
  const day = date.getDay();


  return day >= 1 && day <= 5;
}

function mergeSessionParameters(savedParameters, freshParameters) {
  return removeEmptyValues({
    ...(savedParameters || {}),
    ...(freshParameters || {}),
  });
}

async function saveAgentStateToVistoria({ idvistoria, currentAgent }) {
  const cleanId = String(idvistoria || "").trim();

  if (!cleanId) return;

  const now = new Date();
  const expiresAt = addBusinessHours(now, 24);

  // NAO grava mais `agentParameters`: quem escreve esse campo agora sao as
  // tools do ADK (`salvar_estado_vistoria`), e o `removeEmptyValues` daqui
  // coage tudo a string — passaria por cima das listas que o agente gravou.
  //
  // `agentCurrentPage` tambem saiu: era conceito do Dialogflow e ja estava
  // quebrado (gravava a string "[object Object]"). O equivalente util no ADK
  // e qual agente esta com a palavra ao fim do turno.
  await admin.firestore().collection("vistorias").doc(cleanId).set(
    {
      agentBackend: "adk",
      agentCurrentAgent: String(currentAgent || ""),
      agentLastTurnAt: admin.firestore.Timestamp.fromDate(now),
      agentBusinessExpiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      agentSessionPolicy: {
        ttlBusinessHours: 24,
        workdays: [1, 2, 3, 4, 5],
        description: "24 horas úteis, segunda a sexta.",
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

// Expira sozinha as vistorias que passaram das 24h úteis sem sair de
// EM_ANDAMENTO — antes disso só acontecia quando o próprio mecânico tentava
// reabrir aquela vistoria específica (findOpenVistoria, no app), então uma
// vistoria abandonada podia ficar "viva" indefinidamente se ninguém nunca
// mais voltasse nela. Replica exatamente o que o app já faz em
// _expireVistoria/_syncSinistroVistoriaStatus (vistoria_chat_session_service.dart),
// só que rodando sozinha, sem depender de ninguém abrir o app.
//
// Não cria vistoria nova aqui — isso o app já faz sozinho
// (createOrResumeFromSinistro) na próxima vez que o mecânico tentar retomar
// aquele sinistro.
exports.expireStaleVistorias = onSchedule(
  { schedule: "every 60 minutes", region: "us-central1", timeZone: "America/Sao_Paulo" },
  async () => {
    const db = admin.firestore();
    const now = admin.firestore.Timestamp.now();

    const snap = await db
      .collection("vistorias")
      .where("status", "==", "EM_ANDAMENTO")
      .where("agentBusinessExpiresAt", "<=", now)
      .get();

    if (snap.empty) {
      console.log("expireStaleVistorias: nenhuma vistoria vencida.");
      return;
    }

    console.log(`expireStaleVistorias: ${snap.size} vistoria(s) vencida(s), expirando.`);

    for (const doc of snap.docs) {
      const data = doc.data();
      const sinistroId = String(data.sinistroId || "").trim();

      const batch = db.batch();

      batch.set(
        doc.ref,
        {
          status: "EXPIRADA",
          expiredAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      if (sinistroId) {
        batch.set(
          db.collection("sinistro").doc(sinistroId),
          {
            vistoriaAtualId: String(data.idvistoria || doc.id),
            vistoriaAtualStatus: "EXPIRADA",
            vistoriaAtualTipo: String(data.tipoVistoria || "ORIGINAL"),
            ultimaVistoriaAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }

      await batch.commit();
      console.log("expireStaleVistorias: expirada", { vistoriaId: doc.id, sinistroId });
    }
  }
);

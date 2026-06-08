const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const dialogflowCx = require("@google-cloud/dialogflow-cx");
const { VertexAI } = require("@google-cloud/vertexai");

if (!admin.apps.length) {
  admin.initializeApp({
    projectId:
      process.env.GCLOUD_PROJECT ||
      process.env.GCP_PROJECT ||
      "fho-argos",
  });
}

const DIALOGFLOW_PROJECT_ID = "upheld-magpie-404322";
const LOCATION = "us-central1";
const AGENT_ID = "8ece03b0-a71c-4860-818f-422d9c61ddac";
const AGENT_SESSION_TTL_SECONDS = 86399;
const LANGUAGE_CODE = "pt-BR";

const DIALOGFLOW_CLIENT_EMAIL = defineSecret("DIALOGFLOW_CLIENT_EMAIL");
const DIALOGFLOW_PRIVATE_KEY = defineSecret("DIALOGFLOW_PRIVATE_KEY");

const FIREBASE_PROJECT_ID =
  process.env.GCLOUD_PROJECT ||
  process.env.GCP_PROJECT ||
  "fho-argos";

const VERTEX_PROJECT_ID = FIREBASE_PROJECT_ID;
const VERTEX_LOCATION = "us-central1";
const GEMINI_REVIEW_MODEL = "gemini-2.5-flash";

let cachedDialogflowClient = null;
let cachedGeminiModel = null;

function getDialogflowClient() {
  if (cachedDialogflowClient) return cachedDialogflowClient;

  const clientEmail = DIALOGFLOW_CLIENT_EMAIL.value();
  const privateKey = DIALOGFLOW_PRIVATE_KEY.value().replace(/\\n/g, "\n");

  if (!clientEmail || !privateKey) {
    throw new Error(
      "Secrets do Dialogflow não configuradas: DIALOGFLOW_CLIENT_EMAIL/DIALOGFLOW_PRIVATE_KEY."
    );
  }

  cachedDialogflowClient = new dialogflowCx.SessionsClient({
    apiEndpoint: `${LOCATION}-dialogflow.googleapis.com`,
    credentials: {
      client_email: clientEmail,
      private_key: privateKey,
    },
    projectId: DIALOGFLOW_PROJECT_ID,
  });

  return cachedDialogflowClient;
}

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

function extractDialogflowReply(response) {
  const messages = response?.queryResult?.responseMessages || [];
  const parts = [];

  for (const message of messages) {
    if (message.text?.text && Array.isArray(message.text.text)) {
      for (const text of message.text.text) parts.push(text);
    }
  }

  return parts.join("\n").trim() || "Entendi. Pode continuar descrevendo a vistoria.";
}

exports.sendArgosMessage = onCall(
  {
    region: "us-central1",
    secrets: [DIALOGFLOW_CLIENT_EMAIL, DIALOGFLOW_PRIVATE_KEY],
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
        currentPage: context.vistoria?.agentCurrentPage || "",
      });

      const reply = agentResult.reply;

      await saveAgentStateToVistoria({
        idvistoria: inspectionId,
        currentPage: agentResult.currentPage,
        parameters:
          agentResult.parameters && Object.keys(agentResult.parameters).length > 0
            ? agentResult.parameters
            : sessionParameters,
      });

      return {
        reply,
        inspectionId,
        sinistroId: context.sinistroId,
        modo: modo || "normal",
        sessionParameters,
      };
    } catch (error) {
      console.error("Erro ao conversar com Dialogflow CX:", error);
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

exports.sendArgosAudioMessage = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 180,
    memory: "1GiB",
    secrets: [DIALOGFLOW_CLIENT_EMAIL, DIALOGFLOW_PRIVATE_KEY],
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
      currentPage: vistoria?.agentCurrentPage || "",
    });

    const reply = agentResult.reply;

    await saveAgentStateToVistoria({
      idvistoria,
      currentPage: agentResult.currentPage,
      parameters:
        agentResult.parameters && Object.keys(agentResult.parameters).length > 0
          ? agentResult.parameters
          : sessionParameters,
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
    return { title: "Nova vistoria atribuída", body: `${protocol} · ${vehicleLabel || claimType}` };
  }

  if (String(before?.status || "") !== String(after.status || "")) {
    return { title: "Status da vistoria atualizado", body: `${protocol} mudou para ${after.status || "novo status"}` };
  }

  if (String(before?.priority || "") !== String(after.priority || "")) {
    return { title: "Prioridade da vistoria alterada", body: `${protocol} agora está com prioridade ${after.priority}` };
  }

  if (String(before?.scheduledDate || "") !== String(after.scheduledDate || "")) {
    return { title: "Agendamento atualizado", body: `${protocol} teve o horário de vistoria alterado` };
  }

  const beforeCheckIn = String(before?.checkInAt || "");
  const afterCheckIn = String(after.checkInAt || "");

  if (!beforeCheckIn && afterCheckIn) {
    return { title: "Check-in realizado", body: `${protocol} teve check-in registrado na oficina` };
  }

  return { title: "Vistoria atualizada", body: `${protocol} recebeu uma nova atualização` };
}

function shouldIgnoreSinistroNotificationUpdate(before, after) {
  const ignoredFields = new Set([
    "activeViewers",
    "activeViewersCount",
    "activeViewersUpdatedAt",
    "viewersUpdatedAt",
    "lastViewerAt",
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
        notification: { channelId: "argos_vistorias", sound: "default" },
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

function toProtoStruct(data) {
  const fields = {};

  for (const [key, value] of Object.entries(data || {})) {
    fields[key] = toProtoValue(value);
  }

  return { fields };
}

function toProtoValue(value) {
  if (value === null || value === undefined) return { nullValue: "NULL_VALUE" };
  if (typeof value === "number") return { numberValue: value };
  if (typeof value === "boolean") return { boolValue: value };

  if (Array.isArray(value)) {
    return { listValue: { values: value.map((item) => toProtoValue(item)) } };
  }

  if (typeof value === "object") {
    return { structValue: toProtoStruct(value) };
  }

  return { stringValue: String(value) };
}

async function sendTextToArgosAgent({
  uid,
  inspectionId,
  text,
  sessionParameters = {},
  currentPage = "",
}) {
  const client = getDialogflowClient();

  const sessionId = createSessionId(uid, inspectionId);

  const sessionPath = client.projectLocationAgentSessionPath(
    DIALOGFLOW_PROJECT_ID,
    LOCATION,
    AGENT_ID,
    sessionId
  );

  const queryParams = {
    sessionTtl: {
      seconds: AGENT_SESSION_TTL_SECONDS,
    },
  };

  if (sessionParameters && Object.keys(sessionParameters).length > 0) {
    queryParams.parameters = toProtoStruct(sessionParameters);
  }

  if (isValidCurrentPage(currentPage)) {
    queryParams.currentPage = currentPage;
  }

  const request = {
    session: sessionPath,
    queryInput: {
      text: {
        text,
      },
      languageCode: LANGUAGE_CODE,
    },
    queryParams,
  };

  const [response] = await client.detectIntent(request);

  const agentState = extractAgentStateFromResponse(response);

  return {
    reply: extractDialogflowReply(response),
    currentPage: agentState.currentPage,
    parameters: agentState.parameters,
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
    const nextHour = new Date(current.getTime() + 60 * 60 * 1000);

    if (isBusinessDay(nextHour)) {
      remaining -= 1;
    }

    current = normalizeBusinessStart(nextHour);
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

function protoValueToJs(value) {
  if (!value) return null;

  if (Object.prototype.hasOwnProperty.call(value, "stringValue")) {
    return value.stringValue;
  }

  if (Object.prototype.hasOwnProperty.call(value, "numberValue")) {
    return value.numberValue;
  }

  if (Object.prototype.hasOwnProperty.call(value, "boolValue")) {
    return value.boolValue;
  }

  if (Object.prototype.hasOwnProperty.call(value, "nullValue")) {
    return null;
  }

  if (value.listValue?.values) {
    return value.listValue.values.map((item) => protoValueToJs(item));
  }

  if (value.structValue?.fields) {
    return protoStructToJs(value.structValue);
  }

  return null;
}

function protoStructToJs(struct) {
  const fields = struct?.fields || {};
  const obj = {};

  for (const [key, value] of Object.entries(fields)) {
    obj[key] = protoValueToJs(value);
  }

  return obj;
}

function mergeSessionParameters(savedParameters, freshParameters) {
  return removeEmptyValues({
    ...(savedParameters || {}),
    ...(freshParameters || {}),
  });
}

async function saveAgentStateToVistoria({
  idvistoria,
  currentPage,
  parameters,
}) {
  const cleanId = String(idvistoria || "").trim();

  if (!cleanId) return;

  const now = new Date();
  const expiresAt = addBusinessHours(now, 24);

  await admin.firestore().collection("vistorias").doc(cleanId).set(
    {
      agentCurrentPage: String(currentPage || ""),
      agentParameters: removeEmptyValues(parameters || {}),
      agentLastTurnAt: admin.firestore.Timestamp.fromDate(now),
      agentBusinessExpiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      agentSessionTtlSeconds: AGENT_SESSION_TTL_SECONDS,
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

function extractAgentStateFromResponse(response) {
  const queryResult = response?.queryResult || {};
  const currentPage = queryResult.currentPage || "";

  const responseParameters = queryResult.parameters
    ? protoStructToJs(queryResult.parameters)
    : {};

  return {
    currentPage,
    parameters: responseParameters,
  };
}

function isValidCurrentPage(value) {
  const text = String(value || "").trim();

  return text.startsWith("projects/") && text.includes("/pages/");
}

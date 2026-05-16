const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const dialogflowCx = require("@google-cloud/dialogflow-cx");
const { VertexAI } = require("@google-cloud/vertexai");

// Firebase Admin usa a credencial padrão da Function no projeto fho-argos.
// Não use service account do Dialogflow aqui, senão FCM/Firestore/Storage podem falhar.
if (!admin.apps.length) {
  admin.initializeApp({
    projectId:
      process.env.GCLOUD_PROJECT ||
      process.env.GCP_PROJECT ||
      "fho-argos",
  });
}

// Projeto/agent do Dialogflow CX.
const DIALOGFLOW_PROJECT_ID = "upheld-magpie-404322";
const LOCATION = "us-central1";
const AGENT_ID = "8ece03b0-a71c-4860-818f-422d9c61ddac";
const LANGUAGE_CODE = "pt-BR";

// Secrets corretos.
// O defineSecret recebe o NOME do secret, nunca o valor.
// Configure com:
// firebase functions:secrets:set DIALOGFLOW_CLIENT_EMAIL
// firebase functions:secrets:set DIALOGFLOW_PRIVATE_KEY
const DIALOGFLOW_CLIENT_EMAIL = defineSecret("DIALOGFLOW_CLIENT_EMAIL");
const DIALOGFLOW_PRIVATE_KEY = defineSecret("DIALOGFLOW_PRIVATE_KEY");

// Projeto principal do app/backend: fho-argos.
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
  if (cachedDialogflowClient) {
    return cachedDialogflowClient;
  }

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
  if (cachedGeminiModel) {
    return cachedGeminiModel;
  }

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
      for (const text of message.text.text) {
        parts.push(text);
      }
    }
  }

  return (
    parts.join("\n").trim() ||
    "Entendi. Pode continuar descrevendo a vistoria."
  );
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
      request.data.inspectionId || request.data.sinistroId || "INS-001"
    ).trim();

    if (!text) {
      throw new HttpsError("invalid-argument", "Mensagem vazia.");
    }

    try {
      const reply = await sendTextToArgosAgent({
        uid,
        inspectionId,
        text,
      });

      return {
        reply,
        inspectionId,
      };
    } catch (error) {
      console.error("Erro no Dialogflow CX:", error);
      console.error("code:", error.code);
      console.error("message:", error.message);
      console.error("details:", error.details);

      throw new HttpsError(
        "internal",
        "Falha na comunicação com o Argos.",
        {
          code: error.code || null,
          message: error.message || null,
          details: error.details || null,
        }
      );
    }
  }
);

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

    const credenciadoId = String(
      after.credenciadoId ||
        after.credenciadoID ||
        after.workshopId ||
        after.oficinaId ||
        ""
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

    const credenciadoSnap = await db
      .collection("credenciados")
      .doc(credenciadoId)
      .get();

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
      throw new HttpsError(
        "unauthenticated",
        "Usuário precisa estar autenticado."
      );
    }

    const uid = request.auth.uid;
    const data = request.data || {};

    const idvistoria = String(
      data.idvistoria || data.inspectionId || ""
    ).trim();

    const sinistroId = String(data.sinistroId || "").trim();

    const audioId = String(
      data.audioId || `audio_${Date.now()}`
    ).trim();

    const storagePath = String(data.storagePath || "").trim();

    const bucket = String(data.bucket || "").trim();

    if (!idvistoria) {
      throw new HttpsError(
        "invalid-argument",
        "idvistoria é obrigatório."
      );
    }

    if (!storagePath) {
      throw new HttpsError(
        "invalid-argument",
        "storagePath é obrigatório."
      );
    }

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

      await audioRef.set(
        {
          reviewStatus: "done",
          transcricaoRevisada: revisedTranscript,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      console.log("Transcrição revisada com Gemini:", {
        idvistoria,
        audioId,
        chars: revisedTranscript.length,
      });

      const reply = await sendTextToArgosAgent({
        uid,
        inspectionId: idvistoria,
        text: revisedTranscript,
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
      };
    } catch (error) {
      console.error("Erro em sendArgosAudioMessage:", error);

      await audioRef.set(
        {
          transcriptionStatus: "error",
          reviewStatus: "error",
          agentStatus: "error",
          errorMessage: error.message || String(error),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      throw new HttpsError(
        "internal",
        "Não foi possível processar o áudio do chat.",
        {
          message: error.message || String(error),
        }
      );
    }
  }
);

function buildSinistroNotification({ sinistroId, before, after, isCreate }) {
  const protocol = String(after.protocol || sinistroId);

  const vehicle = after.veiculoSnapshot || after.vehicleSnapshot || {};
  const plate = String(vehicle.placa || after.plate || "");
  const brand = String(vehicle.marca || "");
  const model = String(vehicle.modelo || after.vehicle || "");
  const claimType = String(after.claimType || "Vistoria");

  const vehicleLabel = [brand, model, plate]
    .filter((item) => item && item.trim())
    .join(" ");

  if (isCreate) {
    return {
      title: "Nova vistoria atribuída",
      body: `${protocol} · ${vehicleLabel || claimType}`,
    };
  }

  if (String(before?.status || "") !== String(after.status || "")) {
    return {
      title: "Status da vistoria atualizado",
      body: `${protocol} mudou para ${after.status || "novo status"}`,
    };
  }

  if (String(before?.priority || "") !== String(after.priority || "")) {
    return {
      title: "Prioridade da vistoria alterada",
      body: `${protocol} agora está com prioridade ${after.priority}`,
    };
  }

  if (String(before?.scheduledDate || "") !== String(after.scheduledDate || "")) {
    return {
      title: "Agendamento atualizado",
      body: `${protocol} teve o horário de vistoria alterado`,
    };
  }

  const beforeCheckIn = String(before?.checkInAt || "");
  const afterCheckIn = String(after.checkInAt || "");

  if (!beforeCheckIn && afterCheckIn) {
    return {
      title: "Check-in realizado",
      body: `${protocol} teve check-in registrado na oficina`,
    };
  }

  return {
    title: "Vistoria atualizada",
    body: `${protocol} recebeu uma nova atualização`,
  };
}

async function loadTokenEntriesForUids(uids) {
  const db = admin.firestore();
  const tokenMap = new Map();

  for (const uid of uids) {
    const safeUid = String(uid || "").trim();

    if (!safeUid) continue;

    const tokensSnap = await db
      .collection("userDevices")
      .doc(safeUid)
      .collection("tokens")
      .get();

    tokensSnap.forEach((doc) => {
      const data = doc.data() || {};
      const token = String(data.token || "").trim();

      if (!token) return;

      tokenMap.set(token, {
        token,
        uid: safeUid,
        ref: doc.ref,
      });
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
      notification: {
        title,
        body,
      },
      data,
      android: {
        priority: "high",
        notification: {
          channelId: "argos_vistorias",
          sound: "default",
        },
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

  return {
    successCount: totalSuccess,
    failureCount: totalFailure,
  };
}

async function transcribeAndReviewAudioWithGemini({
  gcsUri,
  idvistoria,
  sinistroId,
  vistoria,
}) {
  console.log("Gemini recebendo áudio:", gcsUri);

  const match = gcsUri.match(/^gs:\/\/([^/]+)\/(.+)$/);

  if (!match) {
    throw new Error(`GCS URI inválida: ${gcsUri}`);
  }

  const bucketName = match[1];
  const filePath = match[2];

  const bucket = admin.storage().bucket(bucketName);
  const file = bucket.file(filePath);

  const [exists] = await file.exists();

  if (!exists) {
    throw new Error(`Arquivo não encontrado no Storage: ${gcsUri}`);
  }

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

  if (!size || size < 1000) {
    throw new Error(
      `Arquivo de áudio muito pequeno ou vazio. Size: ${metadata.size}`
    );
  }

  const [audioBuffer] = await file.download();

  console.log("Áudio baixado para Gemini:", {
    bytes: audioBuffer.length,
    isBuffer: Buffer.isBuffer(audioBuffer),
  });

  if (!audioBuffer || audioBuffer.length < 1000) {
    throw new Error(
      `Buffer de áudio vazio ou muito pequeno. Bytes: ${audioBuffer?.length || 0}`
    );
  }

  const mimeType = normalizeAudioMimeType(metadata.contentType);

  const placa = String(vistoria.placa || "").trim();
  const veiculo = String(vistoria.veiculo || "").trim();
  const cliente = String(vistoria.cliente || "").trim();
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

Contexto da vistoria:
- Vistoria: ${idvistoria}
- Sinistro: ${sinistroId}
- Placa: ${placa}
- Veículo: ${veiculo}
- Cliente: ${cliente}
- Observações: ${observacoes}
`.trim();

  const model = getGeminiReviewModel();

  const result = await model.generateContent({
    contents: [
      {
        role: "user",
        parts: [
          {
            text: prompt,
          },
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
    parsed.transcricaoOriginal ||
      parsed.original ||
      parsed.transcript ||
      ""
  ).trim();

  const transcricaoRevisada = String(
    parsed.transcricaoRevisada ||
      parsed.revisada ||
      parsed.revised ||
      transcricaoOriginal ||
      ""
  ).trim();

  if (!transcricaoOriginal && !transcricaoRevisada) {
    throw new Error(
      `Gemini não retornou transcrição válida. Resposta: ${rawText}`
    );
  }

  return {
    transcricaoOriginal: transcricaoOriginal || transcricaoRevisada,
    transcricaoRevisada: transcricaoRevisada || transcricaoOriginal,
  };
}

function normalizeAudioMimeType(contentType) {
  const clean = String(contentType || "").trim().toLowerCase();

  if (clean.includes("mpeg") || clean.includes("mp3")) {
    return "audio/mpeg";
  }

  if (clean.includes("mp4") || clean.includes("m4a")) {
    return "audio/mp4";
  }

  if (clean.includes("aac")) {
    return "audio/aac";
  }

  if (clean.includes("wav")) {
    return "audio/wav";
  }

  if (clean.includes("webm")) {
    return "audio/webm";
  }

  return "audio/mpeg";
}

function extractGeminiText(result) {
  const candidates = result?.response?.candidates || [];

  const parts = candidates[0]?.content?.parts || [];

  return parts
    .map((part) => part.text || "")
    .join("")
    .trim();
}

function parseGeminiAudioJson(rawText) {
  const cleanText = String(rawText || "")
    .trim()
    .replace(/^```json/i, "")
    .replace(/^```/i, "")
    .replace(/```$/i, "")
    .trim();

  try {
    return JSON.parse(cleanText);
  } catch (error) {
    console.error("Erro ao parsear JSON do Gemini:", {
      error: error.message,
      rawText,
    });

    return {
      transcricaoOriginal: cleanText,
      transcricaoRevisada: cleanText,
    };
  }
}

async function reviewTranscriptWithGemini({
  originalTranscript,
  vistoria,
  idvistoria,
  sinistroId,
}) {
  const placa = String(vistoria.placa || "").trim();
  const veiculo = String(vistoria.veiculo || "").trim();
  const cliente = String(vistoria.cliente || "").trim();
  const observacoes = String(vistoria.observacoes || "").trim();

  const prompt = `
Você é um revisor técnico de transcrições de vistoria automotiva.

Corrija apenas gramática, pontuação, concordância e clareza.
Não invente danos.
Não adicione peças, locais de dano ou conclusões que não estejam no texto original.
Não transforme incerteza em certeza.
Não remova informações técnicas importantes.
Mantenha o sentido do relato do mecânico.
Retorne apenas o texto revisado, sem explicações.

Contexto:
- Vistoria: ${idvistoria}
- Sinistro: ${sinistroId}
- Placa: ${placa}
- Veículo: ${veiculo}
- Cliente: ${cliente}
- Observações: ${observacoes}

Transcrição original:
${originalTranscript}
`.trim();

  const model = getGeminiReviewModel();
  const result = await model.generateContent(prompt);

  const text =
    result?.response?.candidates?.[0]?.content?.parts
      ?.map((part) => part.text || "")
      .join("")
      .trim() || "";

  return text || originalTranscript;
}

async function sendTextToArgosAgent({ uid, inspectionId, text }) {
  const client = getDialogflowClient();

  const sessionId = createSessionId(uid, inspectionId);

  const sessionPath = client.projectLocationAgentSessionPath(
    DIALOGFLOW_PROJECT_ID,
    LOCATION,
    AGENT_ID,
    sessionId
  );

  const [response] = await client.detectIntent({
    session: sessionPath,
    queryInput: {
      text: {
        text,
      },
      languageCode: LANGUAGE_CODE,
    },
  });

  return extractDialogflowReply(response);
}

function maskToken(token) {
  if (!token || token.length < 18) {
    return token;
  }

  return `${token.substring(0, 10)}...${token.substring(token.length - 8)}`;
}

function chunkArray(items, size) {
  const chunks = [];

  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }

  return chunks;
}
const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const dialogflowCx = require("@google-cloud/dialogflow-cx");

// Inicialização segura do Admin
if (!admin.apps.length) {
  admin.initializeApp({
    projectId: process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || "fho-argos",
  });
}

const PROJECT_ID = "upheld-magpie-404322";
const LOCATION = "us-central1";
const AGENT_ID = "8ece03b0-a71c-4860-818f-422d9c61ddac";
const LANGUAGE_CODE = "pt-BR";

// Credenciais chumbadas para o teste (conforme solicitado)
const DIALOGFLOW_CLIENT_EMAIL = "chat-argos@upheld-magpie-404322.iam.gserviceaccount.com";
const DIALOGFLOW_PRIVATE_KEY = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDmSMNlYuZO0g4X\nxPhaKSKus8QddXGtzYW9DvmaPbNT+WmtHBD5Y0+Qh8ZlpaBL8nD5fZ7W7rY7Jbbp\nTZ5Obe7mECIvgqNR6VQKfKEeL09dwYlAr2WPHWK6MfbQU9qPJq7lDwwPY9uPbAZG\nJi5k/f6l0Q3D11/7lyzf5eBI/dY+N+zjw/Xh/IyMsmPxZDWA5vKc0ynIRfcYA+dk\nsTxLq3eFUetVAU6OM1J+wyLgMo9bXhvb2xh9XaykU1bA5u+4dQMA2vMgeo0FKoql\nltnIoof4ikyU+M/oC40yNWdBptajDnetFat+cUNVu7lEDVqOL64Y5ybWR7SKdSbh\nk/NfmssfAgMBAAECggEAHXIYahJnWJTLcIajKwQvhx89aHbn/k1VWINdrzdMguRV\neukn0nu8ZMK3v6+Z+5wYjg5eDSWg75c2+EYQg/7SmWBevqx5rbOkJ2MgRvfNsjNZ\nFYhX+CDNyvkwkhrmy38qxedSp3UhUgmCE941+Hvx38oHdI9JmqYN+uMt9qdeib3m\nwlV2gB7BqxMLNpaTuHWVvyMbLFRvPUW+BmYKy5utG3ASqvwDHKZ9/8rgWUaEE9Th\nmyZl9ap/aQUrGC6LxTYTUT34D30OpmNia4lumC7WQmxZUOQR6HT16EGSgLrIEOXL\nRShw74+Md5x12XAFAQ+iehZgb4GBQUiKJYbfGwRjIQKBgQD//0s65JQz6gegW4Gh\nd96zmN1/98eiwu/RqERBCzJyoNd5AUye58YGwJt5HL/ncCxgHaBjcBuPDApyUv9E\n9459yVPQaM4DGMPN7RyJi8S5sSzcCTEA5MNknPirf8F3G5Kd/xbp3p7StXQEIFZ2\nfYVNFmAaEpFG3TTFfL9SeTScGwKBgQDmSWYCTcYjTVpKErbiRRzUcFI3lCQKOsbB\nqT0qnQWFtr22S+z0Tck6cYLwY1CFodj5sgJ2m5ovkoYb3WtlO0i/5EX3K9kTKolq\nhA9zA6KWpCdv5ayYf1hWnRLbs83jJNCmJSUP1Fn0Qawbmo3CLxKgQTAXddCOGHwH\nhFNyxkb1TQKBgHGlPhqI+xoI3RXdSbEK6/zC8iIrN58T9y8WCibt95lXuhBn+UHa\nFtlMjDi6AJ+X9rs8q8U5MaLRb5nNKrHNTJ6ez+yHel15kwNKLg8J0220L/wGwJBq\n/iseXG6WKqbbwL0PT3bHc66LC1QBnyC/HHxaYJNyhrf038aEWNMeJ7LdAoGBAK68\nguq8mNuwlhIeoSaPypBnqfsCLVaVwrqv7/mlq8sKHml0sxes7kOqXfCJa0/6vui4\naaYV66itRZVfLV5i3ZC9ZVlnrA8e96YbDp325Cfp5wLBA3WzKxSNmwGaLV9tT+TB\nyp14Q8lTC4TmgSoXDcsLq7Ihc15etb3+alNsn+sBAoGBAJBEEdkRL1SGVV7S9THl\nWjd4iKyoNacK8I2hePhMyyOkCPlkBOmMFDYqeXhSkNr0SSn5QfcFyIAiGVmeea7e\nXFU4l8OMc1XSXBy49uOPnJvfsjxr7SKKDGKMwfUhzfUlMs3iQazgmmXmbUFuiElp\nOF3KYHqgRNdvTIPKqZYll2n0\n-----END PRIVATE KEY-----\n";

let cachedDialogflowClient = null;

function getDialogflowClient() {
  if (cachedDialogflowClient) return cachedDialogflowClient;

  cachedDialogflowClient = new dialogflowCx.SessionsClient({
    apiEndpoint: `${LOCATION}-dialogflow.googleapis.com`,
    credentials: {
      client_email: DIALOGFLOW_CLIENT_EMAIL,
      private_key: DIALOGFLOW_PRIVATE_KEY.replace(/\\n/g, "\n"),
    },
    projectId: PROJECT_ID,
  });

  return cachedDialogflowClient;
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

  return parts.join("\n").trim() || "Entendi. Pode continuar descrevendo a vistoria.";
}

exports.sendArgosMessage = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuário precisa estar autenticado.");
    }

    const uid = request.auth.uid;
    const text = String(request.data.text || request.data.message || "").trim();
    const inspectionId = String(
      request.data.inspectionId || request.data.sinistroId || "INS-001"
    ).trim();

    if (!text) {
      throw new HttpsError("invalid-argument", "Mensagem vazia.");
    }

    const sessionId = createSessionId(uid, inspectionId);
    const client = getDialogflowClient();

    const sessionPath = client.projectLocationAgentSessionPath(
      PROJECT_ID,
      LOCATION,
      AGENT_ID,
      sessionId
    );

    try {
      const [response] = await client.detectIntent({
        session: sessionPath,
        queryInput: {
          text: { text },
          languageCode: LANGUAGE_CODE,
        },
      });

      return {
        reply: extractDialogflowReply(response),
        inspectionId,
      };
    } catch (error) {
      console.error("Erro no Dialogflow CX:", error);
      throw new HttpsError("internal", "Falha na comunicação com o Argos.", {
        code: error.code || null,
        message: error.message || null,
      });
    }
  }
);

exports.notifySinistroChanges = onDocumentWritten(
  { document: "sinistro/{sinistroId}", region: "us-central1" },
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
      after.credenciadoId || after.credenciadoID || after.workshopId || after.oficinaId || ""
    ).trim();

    if (!credenciadoId) return;

    const notification = buildSinistroNotification({ sinistroId, before, after, isCreate: !beforeExists });
    if (!notification) return;

    const db = admin.firestore();
    const credenciadoSnap = await db.collection("credenciados").doc(credenciadoId).get();
    if (!credenciadoSnap.exists) return;

    const funcionariosUids = Array.isArray(credenciadoSnap.data()?.funcionariosUids)
      ? credenciadoSnap.data().funcionariosUids
      : [];

    if (funcionariosUids.length === 0) return;

    const tokenEntries = await loadTokenEntriesForUids(funcionariosUids);
    if (tokenEntries.length === 0) return;

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

    console.log("Notificação enviada:", { sinistroId, success: result.successCount });
  }
);

function buildSinistroNotification({ sinistroId, before, after, isCreate }) {
  const protocol = String(after.protocol || sinistroId);
  const vehicle = after.veiculoSnapshot || after.vehicleSnapshot || {};
  const plate = String(vehicle.placa || after.plate || "");
  const brand = String(vehicle.marca || "");
  const model = String(vehicle.modelo || after.vehicle || "");
  const claimType = String(after.claimType || "Vistoria");

  const vehicleLabel = [brand, model, plate].filter(i => i?.trim()).join(" ");

  if (isCreate) return { title: "Nova vistoria atribuída", body: `${protocol} · ${vehicleLabel || claimType}` };

  if (String(before?.status) !== String(after.status)) {
    return { title: "Status atualizado", body: `${protocol} mudou para ${after.status}` };
  }
  if (String(before?.priority) !== String(after.priority)) {
    return { title: "Prioridade alterada", body: `${protocol} agora é ${after.priority}` };
  }

  return { title: "Vistoria atualizada", body: `${protocol} recebeu uma atualização` };
}

async function loadTokenEntriesForUids(uids) {
  const db = admin.firestore();
  const tokenMap = new Map();

  for (const uid of uids) {
    if (!uid) continue;
    const tokensSnap = await db.collection("userDevices").doc(String(uid)).collection("tokens").get();
    tokensSnap.forEach(doc => {
      const token = doc.data()?.token;
      if (token) tokenMap.set(token, { token, uid, ref: doc.ref });
    });
  }
  return Array.from(tokenMap.values());
}

async function sendPushToTokenEntries({ tokenEntries, title, body, data }) {
  const batches = chunkArray(tokenEntries, 500);
  let totalSuccess = 0;
  let totalFailure = 0;

  for (const batchEntries of batches) {
    const tokens = batchEntries.map(e => e.token);
    const response = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      data,
      android: { priority: "high", notification: { channelId: "argos_vistorias", sound: "default" } },
    });

    totalSuccess += response.successCount;
    totalFailure += response.failureCount;

    const cleanup = [];
    response.responses.forEach((res, i) => {
      if (!res.success) {
        const code = res.error?.code;
        if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
          cleanup.push(batchEntries[i].ref.delete().catch(() => null));
        }
      }
    });
    await Promise.all(cleanup);
  }
  return { successCount: totalSuccess, failureCount: totalFailure };
}

function chunkArray(items, size) {
  const chunks = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}
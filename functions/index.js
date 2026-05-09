const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const dialogflowCx = require("@google-cloud/dialogflow-cx");

/**
 * Arquitetura atual:
 *
 * Function roda no projeto Firebase principal:
 * - fho-argos
 *
 * Agente IA / Dialogflow CX fica em outro projeto:
 * - tcc-fho
 *
 * Firestore/banco:
 * - ajuste DB_PROJECT_ID conforme onde está seu banco.
 */

const FUNCTION_PROJECT_ID = process.env.GCLOUD_PROJECT || "fho-argos";

const AI_PROJECT_ID = "tcc-fho";
const DB_PROJECT_ID = "tcc-fho";

const LOCATION = "us-central1";
const AGENT_ID = "8ece03b0-a71c-4860-818f-422d9c61ddac";
const LANGUAGE_CODE = "pt-BR";

admin.initializeApp();

const dialogflowClient = new dialogflowCx.SessionsClient({
  apiEndpoint: LOCATION + "-dialogflow.googleapis.com",
});

function getFirestoreDb() {
  if (DB_PROJECT_ID === FUNCTION_PROJECT_ID) {
    return admin.firestore();
  }

  try {
    return admin.app("db-project").firestore();
  } catch (error) {
    const dbApp = admin.initializeApp(
      {
        projectId: DB_PROJECT_ID,
      },
      "db-project"
    );

    return dbApp.firestore();
  }
}

const db = getFirestoreDb();

function createSessionId(uid, inspectionId) {
  return crypto
    .createHash("sha256")
    .update(String(uid) + "_" + String(inspectionId))
    .digest("hex")
    .slice(0, 32);
}

function extractDialogflowReply(response) {
  let responseMessages = [];

  if (
    response &&
    response.queryResult &&
    response.queryResult.responseMessages
  ) {
    responseMessages = response.queryResult.responseMessages;
  }

  const replyParts = [];

  for (const message of responseMessages) {
    if (
      message.text &&
      message.text.text &&
      Array.isArray(message.text.text)
    ) {
      for (const textPart of message.text.text) {
        if (textPart) {
          replyParts.push(String(textPart));
        }
      }
    }
  }

  const reply = replyParts.join("\n").trim();

  if (reply) {
    return reply;
  }

  return "Entendi. Pode continuar descrevendo a vistoria.";
}

function buildErrorDetails(error, step) {
  return {
    step: step,
    code: error && error.code ? error.code : null,
    message: error && error.message ? error.message : null,
    details: error && error.details ? error.details : null,
  };
}

async function saveChatMessage({
  inspectionId,
  senderId,
  senderType,
  messageType,
  text,
}) {
  await db
    .collection("inspections")
    .doc(inspectionId)
    .collection("chatMessages")
    .add({
      senderId: senderId,
      senderType: senderType,
      messageType: messageType,
      text: text,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
}

exports.sendArgosMessage = onCall(
  {
    region: "us-central1",
  },
  async (request) => {
    if (!request.auth) {
      /*throw new HttpsError(
        "unauthenticated",
        "Usuário precisa estar autenticado."
      ); */
      const uid = request.auth ? request.auth.uid : "debug_user";
    }

    const uid = request.auth.uid;
    const text = String(request.data.text || "").trim();
    const inspectionId = String(request.data.inspectionId || "INS-001").trim();

    if (!text) {
      throw new HttpsError("invalid-argument", "Mensagem vazia.");
    }

    const sessionId = createSessionId(uid, inspectionId);

    const sessionPath = dialogflowClient.projectLocationAgentSessionPath(
      AI_PROJECT_ID,
      LOCATION,
      AGENT_ID,
      sessionId
    );

    let currentStep = "start";

    console.log("sendArgosMessage iniciado");
    console.log("FUNCTION_PROJECT_ID:", FUNCTION_PROJECT_ID);
    console.log("AI_PROJECT_ID:", AI_PROJECT_ID);
    console.log("DB_PROJECT_ID:", DB_PROJECT_ID);
    console.log("LOCATION:", LOCATION);
    console.log("AGENT_ID:", AGENT_ID);
    console.log("inspectionId:", inspectionId);
    console.log("sessionPath:", sessionPath);

    try {
      currentStep = "save_user_message_firestore";
      console.log("1 - Salvando mensagem do usuário no Firestore");

      await saveChatMessage({
        inspectionId: inspectionId,
        senderId: uid,
        senderType: "mechanic",
        messageType: "text",
        text: text,
      });

      currentStep = "dialogflow_detect_intent";
      console.log("2 - Mensagem salva. Chamando Dialogflow CX");

      const detectIntentRequest = {
        session: sessionPath,
        queryInput: {
          text: {
            text: text,
          },
          languageCode: LANGUAGE_CODE,
        },
      };

      const result = await dialogflowClient.detectIntent(detectIntentRequest);
      const response = result[0];

      console.log("3 - Dialogflow CX respondeu");

      const reply = extractDialogflowReply(response);

      currentStep = "save_ai_message_firestore";
      console.log("4 - Salvando resposta da IA no Firestore");

      await saveChatMessage({
        inspectionId: inspectionId,
        senderId: "argos_ai",
        senderType: "ai",
        messageType: "text",
        text: reply,
      });

      console.log("5 - Fluxo concluído com sucesso");

      return {
        reply: reply,
        inspectionId: inspectionId,
        sessionId: sessionId,
      };
    } catch (error) {
      console.error("Erro ao conversar com o assistente Argos");
      console.error("step:", currentStep);
      console.error("code:", error && error.code ? error.code : null);
      console.error("message:", error && error.message ? error.message : null);
      console.error("details:", error && error.details ? error.details : null);
      console.error("raw error:", error);

      throw new HttpsError(
        "internal",
        "Não foi possível conversar com o assistente Argos.",
        buildErrorDetails(error, currentStep)
      );
    }
  }
);
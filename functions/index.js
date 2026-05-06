const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleAuth } = require("google-auth-library");

admin.initializeApp();

const db = admin.firestore();

const CES_PROJECT_ID = "fho-argos";
const CES_LOCATION = "us";
const CES_APP_ID = "bf229998-26cb-4f10-bdf6-aa64656acafc";
const CES_APP_VERSION =
  "projects/fho-argos/locations/us/apps/bf229998-26cb-4f10-bdf6-aa64656acafc/versions/09d758a4-dcd9-4234-8076-e131c837267a";
const CES_DEPLOYMENT =
  "projects/fho-argos/locations/us/apps/bf229998-26cb-4f10-bdf6-aa64656acafc/deployments/ae6ecdc5-17f7-4223-8e95-3b00f9be3d4e";

const auth = new GoogleAuth({
  scopes: ["https://www.googleapis.com/auth/cloud-platform"],
});

function sanitizeSessionId(value) {
  return String(value || "session")
    .replace(/[^a-zA-Z0-9_-]/g, "_")
    .slice(0, 80);
}

function extractReplyFromCes(responseJson) {
  const outputs = responseJson.outputs || [];
  const parts = [];

  for (const output of outputs) {
    if (output.text) {
      parts.push(output.text);
    }

    if (output.message && output.message.text) {
      parts.push(output.message.text);
    }

    if (output.response && output.response.text) {
      parts.push(output.response.text);
    }

    if (output.content && output.content.text) {
      parts.push(output.content.text);
    }

    if (output.messages && Array.isArray(output.messages)) {
      for (const message of output.messages) {
        if (message.text) {
          parts.push(message.text);
        }

        if (message.content && message.content.text) {
          parts.push(message.content.text);
        }
      }
    }
  }

  return (
    parts
      .filter(Boolean)
      .map((item) => String(item))
      .join("\n")
      .trim() || "Entendi. Pode continuar descrevendo a vistoria."
  );
}

exports.sendArgosMessage = onCall(
  {
    region: "us-central1",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Usuário precisa estar autenticado."
      );
    }

    const uid = request.auth.uid;
    const text = String(request.data.text || "").trim();
    const inspectionId = String(request.data.inspectionId || "INS-001").trim();

    if (!text) {
      throw new HttpsError("invalid-argument", "Mensagem vazia.");
    }

    const sessionId = sanitizeSessionId(`${uid}_${inspectionId}`);
    const session =
      `projects/${CES_PROJECT_ID}/locations/${CES_LOCATION}` +
      `/apps/${CES_APP_ID}/sessions/${sessionId}`;

    const url =
      `https://ces.googleapis.com/v1beta/projects/${CES_PROJECT_ID}` +
      `/locations/${CES_LOCATION}/apps/${CES_APP_ID}` +
      `/sessions/${sessionId}:runSession`;

    const body = {
      config: {
        session: session,
        app_version: CES_APP_VERSION,
        deployment: CES_DEPLOYMENT,
      },
      inputs: [
        {
          text: text,
        },
      ],
    };

    try {
      await db
        .collection("inspections")
        .doc(inspectionId)
        .collection("chatMessages")
        .add({
          senderId: uid,
          senderType: "mechanic",
          messageType: "text",
          text: text,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

      const client = await auth.getClient();
      const accessTokenResponse = await client.getAccessToken();
      const accessToken = accessTokenResponse.token;

      const cesResponse = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });

      const responseText = await cesResponse.text();

      if (!cesResponse.ok) {
        console.error("CES status:", cesResponse.status);
        console.error("CES response:", responseText);

        throw new Error(
          `CES API error ${cesResponse.status}: ${responseText}`
        );
      }

      const responseJson = JSON.parse(responseText);
      console.log("CES response JSON:", JSON.stringify(responseJson));

      const reply = extractReplyFromCes(responseJson);

      await db
        .collection("inspections")
        .doc(inspectionId)
        .collection("chatMessages")
        .add({
          senderId: "argos_ai",
          senderType: "ai",
          messageType: "text",
          text: reply,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

      return {
        reply: reply,
        inspectionId: inspectionId,
      };
    } catch (error) {
      console.error("Erro ao conversar com CES:", error);
      console.error("message:", error.message);

      throw new HttpsError(
        "internal",
        "Não foi possível conversar com o assistente Argos.",
        {
          message: error.message || null,
        }
      );
    }
  }
);
// Leitura em voz das mensagens do Argos (botão "Ouvir" em toda fala do
// Argos no chat). O app manda o texto da mensagem; aqui ele vira MP3 com o
// Text-to-Speech do Google e volta em base64 para o app tocar.
// Para trocar a voz, mude só VOZ_PADRAO (lista: cloud.google.com/text-to-speech/docs/chirp3-hd).

const { GoogleAuth } = require("google-auth-library");

const VOZ_PADRAO = "pt-BR-Chirp3-HD-Charon";
const MAX_CARACTERES = 1500;
const ENDPOINT = "https://texttospeech.googleapis.com/v1/text:synthesize";

let auth = null;

// Tira o que não faz sentido falar: marcação, listas numeradas viram pausa.
function textoParaFala(texto) {
  return String(texto || "")
    .replace(/[*_`#>]+/g, "")
    .replace(/^\s*[-•]\s+/gm, "")
    .replace(/R\$\s?/g, "R$ ")
    .replace(/\n{2,}/g, ". ")
    .replace(/\n/g, ". ")
    .replace(/\.\s*\./g, ".")
    .replace(/\s{2,}/g, " ")
    .trim()
    .slice(0, MAX_CARACTERES);
}

async function sintetizar({ texto, projectId, voz = VOZ_PADRAO, fetchImpl = fetch }) {
  const limpo = textoParaFala(texto);
  if (!limpo) throw new Error("texto vazio");

  auth = auth || new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });
  const token = await auth.getAccessToken();

  const resposta = await fetchImpl(ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(projectId ? { "x-goog-user-project": projectId } : {}),
    },
    body: JSON.stringify({
      input: { text: limpo },
      voice: { languageCode: "pt-BR", name: voz },
      audioConfig: { audioEncoding: "MP3" },
    }),
  });

  if (!resposta.ok) {
    const corpo = await resposta.text().catch(() => "");
    throw new Error(`Text-to-Speech ${resposta.status}: ${corpo.slice(0, 200)}`);
  }

  const dados = await resposta.json();
  if (!dados.audioContent) throw new Error("Text-to-Speech sem áudio");
  return dados.audioContent;
}

module.exports = { textoParaFala, sintetizar, MAX_CARACTERES, VOZ_PADRAO };

const { VertexAI } = require("@google-cloud/vertexai");

const PROJECT_ID = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || "fho-argos";
const LOCATION = process.env.GOOGLE_CLOUD_LOCATION || "us-central1";
// Mesmo modelo que o resto do backend já usa para revisão (functions/index.js,
// GEMINI_REVIEW_MODEL) — mantém previsibilidade de custo/qualidade.
const MODEL = process.env.LAUDO_GEMINI_MODEL || "gemini-2.5-flash";
const STORAGE_BUCKET =
  process.env.ARGOS_STORAGE_BUCKET || `${PROJECT_ID}.firebasestorage.app`;

let cachedModel = null;

function getModel() {
  if (cachedModel) return cachedModel;

  const vertexAI = new VertexAI({ project: PROJECT_ID, location: LOCATION });
  cachedModel = vertexAI.getGenerativeModel({
    model: MODEL,
    generationConfig: {
      temperature: 0.2,
      // 4096 estava curto demais pra vistorias com muitos danos — o Gemini
      // cortava a resposta no meio de uma string, gerando JSON inválido
      // (ver caso ARG-2026-0086: colisão traseira com bastante dano
      // descrito). Dobrado com folga.
      maxOutputTokens: 8192,
      responseMimeType: "application/json",
    },
  });

  return cachedModel;
}

const SYSTEM_PROMPT = `Você é um perito técnico automotivo sênior, escrevendo o laudo
oficial de uma vistoria para o analista de sinistros de uma seguradora ler.

Você recebe: (1) as fotos tiradas pelo mecânico durante a vistoria, na ordem em
que foram enviadas, e (2) a transcrição completa da conversa entre o mecânico
(narração falada/escrita) e o agente de IA que o acompanhou em campo.

Sua tarefa é sintetizar tudo isso num laudo técnico estruturado, correlacionando
o que aparece nas fotos com o que o mecânico relatou (inclusive problemas que só
aparecem no relato, como ruídos ou folgas, que a foto sozinha não mostra).

Classifique a severidade segundo a Resolução CONTRAN nº 810/2020: "pequena
monta", "média monta" ou "grande monta" — e explique o raciocínio por trás da
classificação (isso é obrigatório: o analista precisa entender o "porquê", não
só o resultado).

Além disso, avalie explicitamente duas coisas: (1) se há alguma incongruência
entre o que o mecânico relatou na transcrição e o que as fotos realmente
mostram (ex: relato menciona um dano que nenhuma foto evidencia, ou o oposto);
(2) se as fotos enviadas são suficientes, em quantidade e enquadramento, para
sustentar com segurança a classificação de severidade dada.

Se vier um "orçamento registrado pelo agente de campo" no contexto, trate-o
como referência NÃO verificada — foi rascunhado por outro agente de IA ainda
durante a vistoria, sem revisão humana. Cruze o valor com o que você vê nas
fotos (severidade alta deveria custar mais, por exemplo) e mencione essa
comparação na justificativa, mas a classificação e o nível de confiança
continuam sendo seu julgamento independente sobre as fotos e o relato — nunca
copie a conclusão do outro agente sem confirmar pela evidência visual.

Responda ESTRITAMENTE em JSON com este formato, sem markdown, sem texto fora do JSON:
{
  "resumoExecutivo": "2-4 frases resumindo o estado do veículo e o achado principal",
  "danosIdentificados": [
    { "localizacao": "string", "descricao": "string", "gravidade": "leve|moderada|grave", "fotoReferencia": <número da foto ou null> }
  ],
  "classificacaoContran": "pequena monta|média monta|grande monta",
  "justificativaClassificacao": "explicação clara do porquê dessa classificação",
  "nivelConfianca": "alto|médio|baixo",
  "incongruenciaDetectada": <true|false>,
  "detalhesIncongruencia": "se incongruenciaDetectada for true, explique qual; senão string vazia",
  "evidenciasSuficientes": <true|false>,
  "observacoesAdicionais": "qualquer coisa relevante relatada pelo mecânico que não virou um dano formal (ex: já sinalizou reparo anterior, pediu retorno, etc.), ou string vazia",
  "recomendacoes": "recomendação objetiva para o analista (aprovar, pedir complementação, encaminhar para regulação manual, etc.)"
}`;

async function buildImageParts(fotos) {
  return fotos
    .filter((f) => f.storagePath)
    .map((f) => ({
      fileData: {
        fileUri: `gs://${STORAGE_BUCKET}/${f.storagePath}`,
        mimeType: f.contentType || "image/jpeg",
      },
    }));
}

/**
 * Chama o Gemini com as fotos (multimodal, via gs:// — sem baixar/re-subir
 * bytes) + a transcrição, e retorna os achados já estruturados.
 */
async function gerarAchadosTecnicos(context) {
  const model = getModel();

  const transcricaoTexto = context.transcricao
    .map((m) => `[${m.autor}]: ${m.texto}`)
    .join("\n");

  const imageParts = await buildImageParts(context.fotos);

  const orcamento = context.orcamentoCampo;
  const orcamentoTexto =
    orcamento && orcamento.itens.length > 0
      ? `
Orçamento registrado pelo agente de campo durante a vistoria (NÃO
verificado de forma independente — cruze com as fotos antes de usar; se
divergir do que você vê nas imagens, ignore ou ajuste):
${orcamento.itens.map((item) => `- ${item.peca} — R$ ${item.valor.toFixed(2)} (${item.horasMaoObra}h de mão de obra)`).join("\n")}
Total estimado em campo: R$ ${orcamento.valorTotal.toFixed(2)}
`
      : "";

  const textoContexto = `
Protocolo: ${context.protocolo}
Veículo: ${context.veiculoModelo} (${context.veiculoAno}) — placa ${context.veiculoPlaca}, cor ${context.veiculoCor}
Descrição inicial do sinistro: ${context.danosDescritos || "não informada"}
Observações registradas: ${context.observacoes || "nenhuma"}
${orcamentoTexto}
Total de fotos enviadas: ${context.fotos.length}

Transcrição da vistoria (mecânico + IA):
${transcricaoTexto || "(sem mensagens registradas)"}
`.trim();

  const result = await model.generateContent({
    contents: [
      {
        role: "user",
        parts: [{ text: SYSTEM_PROMPT }, { text: textoContexto }, ...imageParts],
      },
    ],
  });

  const rawText =
    result?.response?.candidates?.[0]?.content?.parts
      ?.map((p) => p.text || "")
      .join("")
      .trim() || "";

  if (!rawText) {
    throw new Error("Gemini não retornou conteúdo para o laudo.");
  }

  try {
    return JSON.parse(rawText);
  } catch (err) {
    throw new Error(`Gemini retornou JSON inválido: ${err.message}\n${rawText.slice(0, 500)}`);
  }
}

module.exports = { gerarAchadosTecnicos };

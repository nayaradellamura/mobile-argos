const express = require("express");
const admin = require("firebase-admin");

const { loadLaudoContext } = require("./lib/data");
const { gerarAchadosTecnicos } = require("./lib/gemini");
const { renderLaudoPdf, renderOrcamentoAprovadoPdf } = require("./lib/pdf");
const { uploadLaudoPdf, uploadOrcamentoAprovadoPdf } = require("./lib/storage");

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || "fho-argos",
  });
}

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/", (_req, res) => {
  res.status(200).send("laudo-service ok");
});

app.post("/gerar-laudo", async (req, res) => {
  const sinistroId = String(req.body?.sinistroId || "").trim();
  const vistoriaId = String(req.body?.vistoriaId || "").trim();

  if (!sinistroId || !vistoriaId) {
    // 400 = erro do chamador, não adianta o Cloud Tasks tentar de novo.
    res.status(400).json({ error: "sinistroId e vistoriaId são obrigatórios." });
    return;
  }

  const db = admin.firestore();
  const sinistroRef = db.collection("sinistro").doc(sinistroId);

  console.log("Gerando laudo:", { sinistroId, vistoriaId });

  try {
    // Idempotência: se esse laudo já ficou pronto (ex: Cloud Tasks reentregou
    // a mesma tarefa depois de um timeout que na verdade já tinha terminado),
    // não gera de novo nem sobrescreve.
    const sinistroSnapAntes = await sinistroRef.get();
    const laudoAtual = sinistroSnapAntes.data()?.laudoTecnico;
    if (laudoAtual?.status === "pronto" && laudoAtual?.vistoriaId === vistoriaId) {
      console.log("Laudo já estava pronto, ignorando:", { sinistroId, vistoriaId });
      res.status(200).json({ status: "ja_existia", url: laudoAtual.url });
      return;
    }

    await sinistroRef.set(
      { laudoTecnico: { status: "gerando", vistoriaId, iniciadoEm: admin.firestore.FieldValue.serverTimestamp() } },
      { merge: true }
    );

    const context = await loadLaudoContext({ sinistroId, vistoriaId });
    const achados = await gerarAchadosTecnicos(context);
    const pdfBuffer = await renderLaudoPdf({ context, achados });
    const { storagePath, url } = await uploadLaudoPdf({ vistoriaId, pdfBuffer });

    await sinistroRef.set(
      {
        laudoTecnico: {
          status: "pronto",
          vistoriaId,
          url,
          storagePath,
          classificacaoContran: achados.classificacaoContran || null,
          achados,
          geradoEm: admin.firestore.FieldValue.serverTimestamp(),
          modelo: process.env.LAUDO_GEMINI_MODEL || "gemini-2.5-flash",
        },
      },
      { merge: true }
    );

    console.log("Laudo pronto:", { sinistroId, vistoriaId, storagePath });
    res.status(200).json({ status: "pronto", url });
  } catch (err) {
    console.error("Falha ao gerar laudo:", { sinistroId, vistoriaId, error: err?.message, stack: err?.stack });

    await sinistroRef
      .set(
        {
          laudoTecnico: {
            status: "erro",
            vistoriaId,
            erro: String(err?.message || err),
            falhouEm: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
        { merge: true }
      )
      .catch(() => {});

    // 500 = erro nosso (Gemini, Puppeteer, Storage) — deixa o Cloud Tasks
    // tentar de novo automaticamente, respeitando a política de retry da fila.
    res.status(500).json({ error: String(err?.message || err) });
  }
});

// Gerado quando o analista aprova o sinistro (finalizar) — ver
// onSinistroFinalizado em functions/index.js. Ao contrário do laudo
// técnico, não chama o Gemini: é só um preenchimento de template com o
// orçamento que o mecânico já registrou em campo (context.orcamentoCampo),
// já formalmente aprovado pela decisão do analista.
app.post("/gerar-orcamento-aprovado", async (req, res) => {
  const sinistroId = String(req.body?.sinistroId || "").trim();
  const vistoriaId = String(req.body?.vistoriaId || "").trim();

  if (!sinistroId || !vistoriaId) {
    res.status(400).json({ error: "sinistroId e vistoriaId são obrigatórios." });
    return;
  }

  const db = admin.firestore();
  const sinistroRef = db.collection("sinistro").doc(sinistroId);

  console.log("Gerando orçamento aprovado:", { sinistroId, vistoriaId });

  try {
    const sinistroSnapAntes = await sinistroRef.get();
    const orcamentoAtual = sinistroSnapAntes.data()?.orcamentoAprovado;
    if (orcamentoAtual?.status === "pronto" && orcamentoAtual?.vistoriaId === vistoriaId) {
      console.log("Orçamento aprovado já estava pronto, ignorando:", { sinistroId, vistoriaId });
      res.status(200).json({ status: "ja_existia", url: orcamentoAtual.url });
      return;
    }

    await sinistroRef.set(
      {
        orcamentoAprovado: {
          status: "gerando",
          vistoriaId,
          iniciadoEm: admin.firestore.FieldValue.serverTimestamp(),
        },
      },
      { merge: true }
    );

    const context = await loadLaudoContext({ sinistroId, vistoriaId });

    if (context.orcamentoCampo.itens.length === 0) {
      // Sem orçamento nenhum registrado em campo — não faz sentido gerar
      // um PDF vazio. Registra como erro pra não ficar girando "gerando"
      // pra sempre, mas não é uma falha de verdade (nem todo mecânico
      // preenche orçamento).
      await sinistroRef.set(
        {
          orcamentoAprovado: {
            status: "erro",
            vistoriaId,
            erro: "Nenhum item de orçamento foi registrado pelo mecânico durante a vistoria.",
            falhouEm: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
        { merge: true }
      );
      res.status(200).json({ status: "sem_orcamento" });
      return;
    }

    const pdfBuffer = await renderOrcamentoAprovadoPdf({ context });
    const { storagePath, url } = await uploadOrcamentoAprovadoPdf({ vistoriaId, pdfBuffer });

    await sinistroRef.set(
      {
        orcamentoAprovado: {
          status: "pronto",
          vistoriaId,
          url,
          storagePath,
          valorTotal: context.orcamentoCampo.valorTotal,
          geradoEm: admin.firestore.FieldValue.serverTimestamp(),
        },
      },
      { merge: true }
    );

    console.log("Orçamento aprovado pronto:", { sinistroId, vistoriaId, storagePath });
    res.status(200).json({ status: "pronto", url });
  } catch (err) {
    console.error("Falha ao gerar orçamento aprovado:", {
      sinistroId,
      vistoriaId,
      error: err?.message,
      stack: err?.stack,
    });

    await sinistroRef
      .set(
        {
          orcamentoAprovado: {
            status: "erro",
            vistoriaId,
            erro: String(err?.message || err),
            falhouEm: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
        { merge: true }
      )
      .catch(() => {});

    res.status(500).json({ error: String(err?.message || err) });
  }
});

const port = process.env.PORT || 8080;
app.listen(port, () => {
  console.log(`laudo-service ouvindo na porta ${port}`);
});

const crypto = require("crypto");
const admin = require("firebase-admin");

const STORAGE_BUCKET =
  process.env.ARGOS_STORAGE_BUCKET ||
  `${process.env.GOOGLE_CLOUD_PROJECT || "fho-argos"}.firebasestorage.app`;

/**
 * Sobe um PDF pro mesmo bucket que fotos/áudios já usam, dentro da própria
 * pasta da vistoria (mesma raiz que "vistorias/{vistoriaId}/images/..."),
 * numa subpasta "vistorias" — GCS não tem pastas de verdade, então esse
 * prefixo é criado sozinho na primeira gravação, não precisa de setup.
 * `nomeDocumento` vira o nome do arquivo (ex: "Laudo Técnico", "Orçamento
 * Aprovado"), pra dar pra subir mais de um tipo de PDF pra mesma vistoria
 * sem um sobrescrever o outro.
 */
async function uploadPdf({ vistoriaId, pdfBuffer, nomeDocumento }) {
  const bucket = admin.storage().bucket(STORAGE_BUCKET);
  const storagePath = `vistorias/${vistoriaId}/vistorias/${nomeDocumento} ${vistoriaId}.pdf`;
  const file = bucket.file(storagePath);

  const downloadToken = crypto.randomUUID();

  await file.save(pdfBuffer, {
    contentType: "application/pdf",
    metadata: {
      metadata: {
        firebaseStorageDownloadTokens: downloadToken,
      },
    },
  });

  const encodedPath = encodeURIComponent(storagePath);
  const url = `https://firebasestorage.googleapis.com/v0/b/${STORAGE_BUCKET}/o/${encodedPath}?alt=media&token=${downloadToken}`;

  return { storagePath, url };
}

async function uploadLaudoPdf({ vistoriaId, pdfBuffer }) {
  return uploadPdf({ vistoriaId, pdfBuffer, nomeDocumento: "Laudo Técnico" });
}

async function uploadOrcamentoAprovadoPdf({ vistoriaId, pdfBuffer }) {
  return uploadPdf({ vistoriaId, pdfBuffer, nomeDocumento: "Orçamento Aprovado" });
}

module.exports = { uploadLaudoPdf, uploadOrcamentoAprovadoPdf };

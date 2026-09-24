const crypto = require("crypto");
const admin = require("firebase-admin");

const STORAGE_BUCKET =
  process.env.ARGOS_STORAGE_BUCKET ||
  `${process.env.GOOGLE_CLOUD_PROJECT || "fho-argos"}.firebasestorage.app`;

/**
 * Sobe o PDF pro mesmo bucket que fotos/áudios já usam, dentro da própria
 * pasta da vistoria (mesma raiz que "vistorias/{vistoriaId}/images/..."),
 * numa subpasta "vistorias" — GCS não tem pastas de verdade, então esse
 * prefixo é criado sozinho na primeira gravação, não precisa de setup.
 * Nome do arquivo com o mesmo nome da vistoria, pra ficar fácil de achar.
 */
async function uploadLaudoPdf({ sinistroId, vistoriaId, pdfBuffer }) {
  const bucket = admin.storage().bucket(STORAGE_BUCKET);
  const storagePath = `vistorias/${vistoriaId}/vistorias/Laudo Técnico ${vistoriaId}.pdf`;
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

module.exports = { uploadLaudoPdf };

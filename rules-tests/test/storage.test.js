// Testes das regras do Cloud Storage (storage.rules) no emulador.
// As regras consultam o Firestore (users / vistorias / credenciados / admins),
// então os dois emuladores precisam estar rodando.
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { ref, uploadBytes, getDownloadURL, getMetadata } = require('firebase/storage');
const { getEnv, seed, ctx, USERS } = require('./setup');

const MB = 1024 * 1024;
const bytes = (n) => new Uint8Array(n).fill(7);

describe('Storage rules', function () {
  let env;

  before(async () => { env = await getEnv(); });
  beforeEach(async () => {
    await seed(env);
    await env.clearStorage();
    // PDF gerado pelo laudo-service (Admin SDK)
    await env.withSecurityRulesDisabled(async (c) => {
      await uploadBytes(ref(c.storage(), 'vistorias/VIS-2026-0001/vistorias/Laudo Técnico VIS-2026-0001.pdf'),
        bytes(1024), { contentType: 'application/pdf' });
      await uploadBytes(ref(c.storage(), 'vistorias/VIS-2026-0002/images/img_1.jpg'),
        bytes(1024), { contentType: 'image/jpeg' });
    });
  });

  const st = (uid, claims) => ctx(env, uid, claims).storage();

  it('sem login não lê nem envia', async () => {
    const s = env.unauthenticatedContext().storage();
    await assertFails(uploadBytes(ref(s, 'vistorias/VIS-2026-0001/images/img_9.jpg'), bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(getMetadata(ref(s, 'vistorias/VIS-2026-0001/vistorias/Laudo Técnico VIS-2026-0001.pdf')));
  });

  it('mecânico da oficina envia foto JPEG da vistoria e gera URL', async () => {
    const r = ref(st('mecA2'), 'vistorias/VIS-2026-0001/images/img_123.jpg');
    await assertSucceeds(uploadBytes(r, bytes(2 * MB), { contentType: 'image/jpeg' }));
    await assertSucceeds(getDownloadURL(r));
  });

  it('membro só via funcionariosUids também envia', async () => {
    await assertSucceeds(uploadBytes(ref(st('funA'), 'vistorias/VIS-2026-0001/images/img_200.jpg'), bytes(100), { contentType: 'image/jpeg' }));
  });

  it('foto acima de 15 MB ou tipo errado é recusada', async () => {
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/images/img_big.jpg'), bytes(16 * MB), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/images/x.html'), bytes(10), { contentType: 'text/html' }));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/images/vazio.jpg'), bytes(0), { contentType: 'image/jpeg' }));
  });

  it('outra oficina / pendente não envia nem lê evidências', async () => {
    await assertFails(uploadBytes(ref(st('mecB'), 'vistorias/VIS-2026-0001/images/img_1.jpg'), bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(ref(st('pend'), 'vistorias/VIS-2026-0001/images/img_1.jpg'), bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(getDownloadURL(ref(st('mecA'), 'vistorias/VIS-2026-0002/images/img_1.jpg')));
    await assertFails(getMetadata(ref(st('mecB'), 'vistorias/VIS-2026-0001/vistorias/Laudo Técnico VIS-2026-0001.pdf')));
  });

  it('não sobrescreve arquivo existente', async () => {
    const r = ref(st('mecA'), 'vistorias/VIS-2026-0001/images/img_dup.jpg');
    await assertSucceeds(uploadBytes(r, bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(r, bytes(20), { contentType: 'image/jpeg' }));
  });

  it('áudio MP3 até 25 MB', async () => {
    await assertSucceeds(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/audio/VIS_2026_0001_AUD_01.mp3'), bytes(MB), { contentType: 'audio/mpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/audio/grande.mp3'), bytes(26 * MB), { contentType: 'audio/mpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/audio/a.exe'), bytes(10), { contentType: 'application/octet-stream' }));
  });

  it('PDF do laudo: membro e analista leem, ninguém grava pelo cliente', async () => {
    const path = 'vistorias/VIS-2026-0001/vistorias/Laudo Técnico VIS-2026-0001.pdf';
    await assertSucceeds(getDownloadURL(ref(st('mecA2'), path)));
    await assertSucceeds(getDownloadURL(ref(st('analista'), path)));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/vistorias/Falso.pdf'), bytes(10), { contentType: 'application/pdf' }));
  });

  it('foto de perfil só no próprio caminho, imagem até 5 MB', async () => {
    // o app usa Uri.encodeComponent(email) (com %40); as regras aceitam as duas formas
    const encoded = `users/${encodeURIComponent(USERS.mecA.email)}/profile_1700000000000.jpg`;
    await assertSucceeds(uploadBytes(ref(st('mecA'), encoded), bytes(MB), { contentType: 'image/jpeg' }));
    const own = `users/${USERS.mecA.email}/profile_1700000000001.jpg`;
    await assertSucceeds(uploadBytes(ref(st('mecA'), own), bytes(MB), { contentType: 'image/jpeg' }));
    await assertSucceeds(getDownloadURL(ref(st('mecA'), own)));
    await assertFails(uploadBytes(ref(st('mecA'), `users/${encodeURIComponent(USERS.mecB.email)}/profile_1.jpg`), bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), `users/${encodeURIComponent(USERS.mecA.email)}/profile_2.jpg`), bytes(6 * MB), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), `users/${encodeURIComponent(USERS.mecA.email)}/script.js`), bytes(10), { contentType: 'text/javascript' }));
    await assertFails(getDownloadURL(ref(st('mecB'), own)));
  });

  it('caminhos fora do mapeamento são negados', async () => {
    await assertFails(uploadBytes(ref(st('analista'), 'qualquer/coisa.jpg'), bytes(10), { contentType: 'image/jpeg' }));
    await assertFails(uploadBytes(ref(st('mecA'), 'vistorias/VIS-2026-0001/outro/x.jpg'), bytes(10), { contentType: 'image/jpeg' }));
  });
});

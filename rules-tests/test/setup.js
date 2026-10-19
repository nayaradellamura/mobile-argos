// Ambiente compartilhado dos testes de regras (Firestore + Storage).
// Rode via `npm run test:emu` (sobe os emuladores com firebase emulators:exec).
const fs = require('fs');
const path = require('path');
const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { doc, setDoc, setLogLevel } = require('firebase/firestore');

// Os PERMISSION_DENIED esperados poluem a saída; silencia o log do SDK.
setLogLevel('silent');

const PROJECT_ID = 'demo-argos-rules';
const ROOT = path.resolve(__dirname, '..', '..');

let envPromise = null;

function getEnv() {
  if (!envPromise) {
    envPromise = initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        rules: fs.readFileSync(path.join(ROOT, 'firestore.rules'), 'utf8'),
      },
      storage: {
        rules: fs.readFileSync(path.join(ROOT, 'storage.rules'), 'utf8'),
      },
    });
  }
  return envPromise;
}

// Usuários de teste: uid -> { email, users doc }
const USERS = {
  mecA: { email: 'mec.a@oficina.com', data: { status: 'ativo', credenciadoId: 'credA', credenciadoNome: 'Oficina A' } },
  mecA2: { email: 'mec.a2@oficina.com', data: { status: 'ativo', credenciadoId: 'credA', credenciadoNome: 'Oficina A' } },
  mecB: { email: 'mec.b@oficina.com', data: { status: 'ativo', credenciadoId: 'credB', credenciadoNome: 'Oficina B' } },
  // pertence à credA só via credenciados.funcionariosUids
  funA: { email: 'fun.a@oficina.com', data: { status: 'ativo' } },
  pend: { email: 'pend@oficina.com', data: { status: 'pendente' } },
  bloq: { email: 'bloq@oficina.com', data: { status: 'bloqueado', credenciadoId: 'credA' } },
  novo: { email: 'novo@oficina.com', data: { status: 'ativo' } },
  analista: { email: 'analista@seguradora.com', data: { status: 'ativo' } },
  // doc legado: só existe em users/{uid}, nunca em users/{email} (conta de
  // antes da migração pra chave por e-mail).
  mecLegado: { email: 'legado@oficina.com', legacyUid: true, data: { status: 'ativo', credenciadoId: 'credA' } },
};

function ctx(env, uid, extraClaims = {}) {
  const u = USERS[uid];
  return env.authenticatedContext(uid, { email: u ? u.email : `${uid}@x.com`, ...extraClaims });
}

async function seed(env) {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (c) => {
    const db = c.firestore();
    for (const [uid, u] of Object.entries(USERS)) {
      const docId = u.legacyUid ? uid : u.email;
      await setDoc(doc(db, 'users', docId), {
        uid, authUid: uid, email: u.email, emailKey: u.email, nome: uid, ...u.data,
      });
    }
    await setDoc(doc(db, 'admins', 'analista'), { nome: 'Analista' });

    await setDoc(doc(db, 'credenciados', 'credA'), {
      name: 'Oficina A', funcionariosUids: ['mecA', 'funA'], valoresHoraMaoObra: { funilaria: 100 }, status: 'Ativo',
    });
    await setDoc(doc(db, 'credenciados', 'credB'), {
      name: 'Oficina B', funcionariosUids: ['mecB'], status: 'Ativo',
    });

    await setDoc(doc(db, 'sinistro', 'SIN-A'), {
      protocol: 'SIN-A', credenciadoId: 'credA', assignedToUid: '', status: 'AGUARDANDO', checkInAt: null, priority: 'alta',
    });
    await setDoc(doc(db, 'sinistro', 'SIN-A2'), {
      protocol: 'SIN-A2', credenciadoId: 'credA', assignedToUid: 'mecA', assignedToName: 'mecA', status: 'EM_ANDAMENTO',
      checkInAt: '2026-10-01T10:00:00', vistoriaAtualId: 'VIS-2026-0003', vistoriaAtualStatus: 'REJEITADA',
    });
    await setDoc(doc(db, 'sinistro', 'SIN-B'), {
      protocol: 'SIN-B', credenciadoId: 'credB', assignedToUid: 'mecB', status: 'EM_ANDAMENTO',
    });

    await setDoc(doc(db, 'vistorias', 'VIS-2026-0001'), {
      idvistoria: 'VIS-2026-0001', sinistroId: 'SIN-A', credenciadoId: 'credA', inspectorId: 'mecA',
      status: 'EM_ANDAMENTO', tipoVistoria: 'ORIGINAL', laudo: '',
      chatmessages: [{ role: 'user', text: 'oi' }], images: [], lastAudioNumber: 0,
    });
    await setDoc(doc(db, 'vistorias', 'VIS-2026-0002'), {
      idvistoria: 'VIS-2026-0002', sinistroId: 'SIN-B', credenciadoId: 'credB', inspectorId: 'mecB',
      status: 'EM_ANDAMENTO', chatmessages: [], images: [],
    });
    await setDoc(doc(db, 'vistorias', 'VIS-2026-0003'), {
      idvistoria: 'VIS-2026-0003', sinistroId: 'SIN-A2', credenciadoId: 'credA', inspectorId: 'mecA',
      status: 'REJEITADA', motivoRejeicao: 'Faltou foto', ajustesNecessarios: 'Foto traseira', chatmessages: [], images: [],
    });
    // vistoria legada sem credenciadoId: só visível pelo sinistro / inspetor
    await setDoc(doc(db, 'vistorias', 'VIS-2026-0004'), {
      idvistoria: 'VIS-2026-0004', sinistroId: 'SIN-A', inspectorId: 'outro', status: 'FINALIZADA',
    });
    await setDoc(doc(db, 'vistorias', 'VIS-2026-0001', 'audios', 'AUD_01'), { transcricao: 'teste' });
    // vistoria do mecânico com doc legado em users/{uid}
    await setDoc(doc(db, 'vistorias', 'VIS-2026-LEGADO'), {
      idvistoria: 'VIS-2026-LEGADO', sinistroId: 'SIN-A', credenciadoId: 'credA', inspectorId: 'mecLegado',
      status: 'EM_ANDAMENTO', chatmessages: [], images: [],
    });

    await setDoc(doc(db, 'counters', 'vistorias_2026'), { lastNumber: 4, year: 2026 });
    await setDoc(doc(db, 'tabelaPrecos', 'leve', 'pecas', 'parachoque'), { valorPeca: 500, horasMaoObra: 2 });
    await setDoc(doc(db, 'clientes', 'C1'), { nome: 'Cliente' });
    await setDoc(doc(db, 'veiculos', 'V1'), { placa: 'ABC1D23' });
    await setDoc(doc(db, 'alertas', 'A1'), { titulo: 'x' });
    await setDoc(doc(db, 'userDevices', 'mecA', 'tokens', 't1'), { token: 't1' });
  });
}

module.exports = { getEnv, seed, ctx, USERS, PROJECT_ID };

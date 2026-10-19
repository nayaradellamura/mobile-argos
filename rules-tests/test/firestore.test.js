// Testes das regras do Firestore (firestore.rules) no emulador.
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, getDocs, setDoc, updateDoc, deleteDoc, collection, query, where, orderBy, limit,
  writeBatch, arrayUnion, serverTimestamp, deleteField, runTransaction,
} = require('firebase/firestore');
const { getEnv, seed, ctx, USERS } = require('./setup');

describe('Firestore rules', function () {
  let env;

  before(async () => { env = await getEnv(); });
  beforeEach(async () => { await seed(env); });

  const db = (uid, claims) => ctx(env, uid, claims).firestore();
  const anon = () => env.unauthenticatedContext().firestore();

  // ---------------------------------------------------------------------
  describe('sem autenticação', () => {
    it('não lê sinistro, vistorias, credenciados, tabelaPrecos, counters', async () => {
      const d = anon();
      await assertFails(getDoc(doc(d, 'sinistro', 'SIN-A')));
      await assertFails(getDoc(doc(d, 'vistorias', 'VIS-2026-0001')));
      await assertFails(getDocs(collection(d, 'credenciados')));
      await assertFails(getDocs(collection(d, 'tabelaPrecos', 'leve', 'pecas')));
      await assertFails(getDoc(doc(d, 'counters', 'vistorias_2026')));
    });

    it('não lê users ativos nem lista users', async () => {
      await assertFails(getDoc(doc(anon(), 'users', USERS.mecA.email)));
      await assertFails(getDocs(collection(anon(), 'users')));
    });

    it('primeiro acesso: consulta e-mail inexistente e cria solicitação pendente', async () => {
      const d = anon();
      const ref = doc(d, 'users', 'nova.pessoa@gmail.com');
      await assertSucceeds(getDoc(ref));
      await assertSucceeds(setDoc(ref, {
        uid: '', authUid: '', email: 'nova.pessoa@gmail.com', emailKey: 'nova.pessoa@gmail.com',
        nome: '', displayName: '', photoURL: '', foto: '', telefone: '', empresa: '', departamento: '',
        provider: 'password', tipoAcesso: 'email_senha', providers: arrayUnion('email_senha'),
        authProviderIds: arrayUnion('password'), status: 'pendente', origem: 'primeiro_acesso',
        origens: arrayUnion('primeiro_acesso'), criadoEm: serverTimestamp(), atualizadoEm: serverTimestamp(),
      }, { merge: true }));
      // a solicitação pendente pode ser consultada de novo (mensagem "já pendente")
      await assertSucceeds(getDoc(ref));
    });

    it('não cria users já ativo, com credenciadoId ou com uid', async () => {
      const base = { email: 'x@y.com', origem: 'primeiro_acesso', uid: '', authUid: '' };
      await assertFails(setDoc(doc(anon(), 'users', 'x@y.com'), { ...base, status: 'ativo' }));
      await assertFails(setDoc(doc(anon(), 'users', 'x@y.com'), { ...base, status: 'pendente', credenciadoId: 'credA' }));
      await assertFails(setDoc(doc(anon(), 'users', 'x@y.com'), { ...base, status: 'pendente', uid: 'mecA' }));
      await assertFails(setDoc(doc(anon(), 'users', 'x@y.com'), { ...base, status: 'pendente', role: 'admin' }));
    });

    it('não altera users existente', async () => {
      await assertFails(updateDoc(doc(anon(), 'users', USERS.pend.email), { status: 'ativo' }));
    });
  });

  // ---------------------------------------------------------------------
  describe('users', () => {
    it('login cria o próprio doc só como pendente', async () => {
      const d = ctx(env, 'u1', { email: 'u1@gmail.com' }).firestore();
      const ref = doc(d, 'users', 'u1@gmail.com');
      await assertFails(setDoc(ref, { uid: 'u1', email: 'u1@gmail.com', status: 'ativo' }));
      await assertFails(setDoc(ref, { uid: 'u1', email: 'u1@gmail.com', status: 'pendente', credenciadoId: 'credA' }));
      await assertFails(setDoc(ref, { uid: 'outro', email: 'u1@gmail.com', status: 'pendente' }));
      await assertFails(setDoc(ref, { uid: 'u1', email: 'u1@gmail.com', status: 'pendente', isAdmin: true }));
      await assertSucceeds(setDoc(ref, {
        uid: 'u1', authUid: 'u1', email: 'u1@gmail.com', emailKey: 'u1@gmail.com', nome: 'U1', displayName: 'U1',
        photoURL: '', foto: '', telefone: '', empresa: '', departamento: '', provider: 'google',
        tipoAcesso: 'sso_google', providers: arrayUnion('sso_google'), authProviderIds: arrayUnion('google.com'),
        status: 'pendente', origem: 'sso_google', origens: arrayUnion('sso_google'),
        criadoEm: serverTimestamp(), atualizadoEm: serverTimestamp(),
      }, { merge: true }));
    });

    it('não cria doc de outro e-mail', async () => {
      await assertFails(setDoc(doc(db('mecA'), 'users', 'alguem@x.com'), { uid: 'mecA', status: 'pendente' }));
    });

    it('usuário pendente não se auto-ativa', async () => {
      const ref = doc(db('pend'), 'users', USERS.pend.email);
      await assertFails(updateDoc(ref, { status: 'ativo' }));
      await assertFails(setDoc(ref, { status: 'ativo' }, { merge: true }));
      // mas o merge de login (sem status) funciona e ele lê o próprio doc
      await assertSucceeds(setDoc(ref, {
        uid: 'pend', authUid: 'pend', provider: 'password', ultimoLoginEm: serverTimestamp(), atualizadoEm: serverTimestamp(),
      }, { merge: true }));
      await assertSucceeds(getDoc(ref));
    });

    it('bloqueado não se desbloqueia', async () => {
      await assertFails(updateDoc(doc(db('bloq'), 'users', USERS.bloq.email), { status: 'ativo' }));
    });

    it('ativo não muda status, papel, aprovação nem credenciadoId', async () => {
      const ref = doc(db('mecA'), 'users', USERS.mecA.email);
      await assertFails(updateDoc(ref, { status: 'pendente' }));
      await assertFails(updateDoc(ref, { role: 'admin' }));
      await assertFails(updateDoc(ref, { aprovadoPor: 'mecA' }));
      await assertFails(updateDoc(ref, { credenciadoId: 'credB' }));
      await assertFails(updateDoc(ref, { uid: 'outro' }));
      await assertSucceeds(updateDoc(ref, { nome: 'Novo Nome', telefone: '11999999999', cpf: '12345678909', ultimoAcesso: serverTimestamp() }));
    });

    it('lê o próprio doc (e-mail, uid legado, query por uid) mas não o de outros', async () => {
      const d = db('mecA');
      await assertSucceeds(getDoc(doc(d, 'users', USERS.mecA.email)));
      await assertSucceeds(getDoc(doc(d, 'users', 'mecA')));
      await assertSucceeds(getDocs(query(collection(d, 'users'), where('uid', '==', 'mecA'), limit(1))));
      await assertSucceeds(getDocs(query(collection(d, 'users'), where('authUid', '==', 'mecA'), limit(1))));
      await assertSucceeds(getDocs(query(collection(d, 'users'), where('email', '==', USERS.mecA.email), limit(1))));
      await assertFails(getDoc(doc(d, 'users', USERS.mecB.email)));
      await assertFails(getDocs(collection(d, 'users')));
      await assertFails(getDocs(query(collection(d, 'users'), where('uid', '==', 'mecB'))));
    });

    it('onboarding: vincula credenciado uma única vez + adiciona o próprio uid', async () => {
      const d = db('novo');
      const batch = writeBatch(d);
      batch.set(doc(d, 'users', USERS.novo.email), {
        uid: 'novo', authUid: 'novo', email: USERS.novo.email, emailKey: USERS.novo.email, nome: 'Novo',
        credenciadoId: 'credA', credenciadoNome: 'Oficina A', empresa: 'Oficina A', cadastroCompleto: true,
        primeiroAcessoConcluido: true, cadastroFinalizadoEm: serverTimestamp(), atualizadoEm: serverTimestamp(),
      }, { merge: true });
      batch.set(doc(d, 'credenciados', 'credA'), {
        funcionariosUids: arrayUnion('novo'), atualizadoEm: serverTimestamp(),
      }, { merge: true });
      await assertSucceeds(batch.commit());

      // depois de vinculado, não troca de oficina
      await assertFails(updateDoc(doc(d, 'users', USERS.novo.email), { credenciadoId: 'credB' }));
      await assertFails(updateDoc(doc(d, 'credenciados', 'credB'), { funcionariosUids: arrayUnion('novo') }));

      // re-salvar o perfil (uid já presente) continua funcionando
      const again = writeBatch(d);
      again.set(doc(d, 'users', USERS.novo.email), { nome: 'Novo 2', credenciadoId: 'credA', atualizadoEm: serverTimestamp() }, { merge: true });
      again.set(doc(d, 'credenciados', 'credA'), { funcionariosUids: arrayUnion('novo'), atualizadoEm: serverTimestamp() }, { merge: true });
      await assertSucceeds(again.commit());
    });

    it('onboarding: não adiciona uid de outro, nem se inclui numa oficina diferente da do users', async () => {
      const d = db('novo');
      await assertFails(updateDoc(doc(d, 'credenciados', 'credA'), { funcionariosUids: arrayUnion('intruso') }));
      // users.credenciadoId ainda vazio -> não pode se incluir sozinho
      await assertFails(updateDoc(doc(d, 'credenciados', 'credA'), { funcionariosUids: arrayUnion('novo') }));
      // vincula credA no users mas tenta entrar na credB
      const b = writeBatch(d);
      b.set(doc(d, 'users', USERS.novo.email), { credenciadoId: 'credA' }, { merge: true });
      b.set(doc(d, 'credenciados', 'credB'), { funcionariosUids: arrayUnion('novo') }, { merge: true });
      await assertFails(b.commit());
      // vínculo com credenciado inexistente
      await assertFails(updateDoc(doc(d, 'users', USERS.novo.email), { credenciadoId: 'naoExiste' }));
    });

    it('usuário não apaga o próprio doc', async () => {
      await assertFails(deleteDoc(doc(db('mecA'), 'users', USERS.mecA.email)));
    });

    it('mecânico com doc legado em users/{uid} (sem doc por e-mail) atualiza o próprio perfil', async () => {
      const ref = doc(db('mecLegado'), 'users', 'mecLegado');
      await assertSucceeds(updateDoc(ref, { nome: 'Legado Atualizado', telefone: '11999999999' }));
      await assertFails(updateDoc(ref, { status: 'bloqueado' }));
    });
  });

  // ---------------------------------------------------------------------
  describe('credenciados', () => {
    it('qualquer autenticado lista (onboarding), inclusive pendente', async () => {
      await assertSucceeds(getDocs(query(collection(db('pend'), 'credenciados'), orderBy('name'))));
      await assertSucceeds(getDocs(query(collection(db('novo'), 'credenciados'), orderBy('name'))));
    });

    it('funcionário grava valoresHoraMaoObra da própria oficina', async () => {
      await assertSucceeds(setDoc(doc(db('mecA'), 'credenciados', 'credA'), {
        valoresHoraMaoObra: { funilaria: 120, pintura: 90 }, valoresHoraAtualizadoEm: serverTimestamp(),
      }, { merge: true }));
      // funcionário só via funcionariosUids
      await assertSucceeds(setDoc(doc(db('funA'), 'credenciados', 'credA'), {
        valoresHoraMaoObra: { funilaria: 130 }, valoresHoraAtualizadoEm: serverTimestamp(),
      }, { merge: true }));
    });

    it('funcionário não altera outros campos nem outra oficina', async () => {
      await assertFails(updateDoc(doc(db('mecA'), 'credenciados', 'credA'), { name: 'Hackeada' }));
      await assertFails(updateDoc(doc(db('mecA'), 'credenciados', 'credA'), { valoresHoraMaoObra: { x: 1 }, score: 10 }));
      await assertFails(updateDoc(doc(db('mecA'), 'credenciados', 'credA'), { funcionariosUids: ['mecA'] }));
      await assertFails(updateDoc(doc(db('mecB'), 'credenciados', 'credA'), { valoresHoraMaoObra: { funilaria: 1 } }));
      await assertFails(updateDoc(doc(db('bloq'), 'credenciados', 'credA'), { valoresHoraMaoObra: { funilaria: 1 } }));
      await assertFails(deleteDoc(doc(db('mecA'), 'credenciados', 'credA')));
      await assertFails(setDoc(doc(db('mecA'), 'credenciados', 'nova'), { name: 'Nova' }));
    });
  });

  // ---------------------------------------------------------------------
  describe('sinistro', () => {
    it('mecânico lista os sinistros da própria oficina e não os de outra', async () => {
      const d = db('mecA');
      await assertSucceeds(getDocs(query(collection(d, 'sinistro'), where('credenciadoId', '==', 'credA'))));
      await assertFails(getDocs(query(collection(d, 'sinistro'), where('credenciadoId', '==', 'credB'))));
      await assertFails(getDocs(collection(d, 'sinistro')));
      await assertSucceeds(getDoc(doc(d, 'sinistro', 'SIN-A')));
      await assertFails(getDoc(doc(d, 'sinistro', 'SIN-B')));
      await assertSucceeds(getDocs(query(collection(d, 'sinistro'), where('assignedToUid', '==', 'mecA'))));
    });

    it('membro só via funcionariosUids também lista', async () => {
      await assertSucceeds(getDocs(query(collection(db('funA'), 'sinistro'), where('credenciadoId', '==', 'credA'))));
    });

    it('pendente/bloqueado não lê sinistro', async () => {
      await assertFails(getDoc(doc(db('pend'), 'sinistro', 'SIN-A')));
      await assertFails(getDocs(query(collection(db('bloq'), 'sinistro'), where('credenciadoId', '==', 'credA'))));
    });

    it('check-in: assume sinistro livre da própria oficina', async () => {
      const d = db('mecA');
      await assertSucceeds(runTransaction(d, async (tx) => {
        const ref = doc(d, 'sinistro', 'SIN-A');
        await tx.get(ref);
        tx.set(ref, {
          assignedToUid: 'mecA', assignedToName: 'Mec A', assignedToEmail: USERS.mecA.email, assignedToPhotoURL: '',
          assignedAt: serverTimestamp(), assignedByAction: 'check_in', isAssigned: true, status: 'EM_ANDAMENTO',
          chatEnabled: true, chatStatus: 'Aberto', checkInAt: new Date().toISOString(), statusUpdatedAt: new Date().toISOString(),
        }, { merge: true });
      }));
    });

    it('não assume sinistro de outro mecânico nem de outra oficina', async () => {
      await assertFails(setDoc(doc(db('mecA2'), 'sinistro', 'SIN-A2'), { assignedToUid: 'mecA2', status: 'EM_ANDAMENTO' }, { merge: true }));
      await assertFails(setDoc(doc(db('mecA'), 'sinistro', 'SIN-B'), { assignedToUid: 'mecA' }, { merge: true }));
      // não atribui para terceiros
      await assertFails(setDoc(doc(db('mecA'), 'sinistro', 'SIN-A'), { assignedToUid: 'mecA2' }, { merge: true }));
    });

    it('só grava os campos do app (sem status final, oficina, laudo...)', async () => {
      const ref = doc(db('mecA'), 'sinistro', 'SIN-A2');
      await assertFails(updateDoc(ref, { status: 'FINALIZADO' }));
      await assertFails(updateDoc(ref, { credenciadoId: 'credB' }));
      await assertFails(updateDoc(ref, { priority: 'baixa' }));
      await assertFails(updateDoc(ref, { laudoTecnico: { url: 'x' } }));
      await assertFails(updateDoc(ref, { vistoriaAtualStatus: 'FINALIZADA' }));
      await assertSucceeds(setDoc(ref, {
        vistoriaAtualId: 'VIS-2026-0001', vistoriaAtualStatus: 'EM_ANALISE_OPERACIONAL', vistoriaAtualTipo: 'ORIGINAL',
        vistoriaAtualOrigemId: deleteField(), ultimaVistoriaAt: serverTimestamp(),
      }, { merge: true }));
      // presença (resumo) pode ser gravada por qualquer membro
      await assertSucceeds(setDoc(doc(db('mecA2'), 'sinistro', 'SIN-A2'), {
        activeViewers: [{ uid: 'mecA2' }], activeViewersCount: 1, activeViewersUpdatedAt: serverTimestamp(),
      }, { merge: true }));
      // replicar nome/foto no sinistro atribuído a mim (profile_page)
      await assertSucceeds(setDoc(ref, { assignedToName: 'Novo', assignedToEmail: 'e', assignedToPhotoURL: 'p', assignedProfileUpdatedAt: serverTimestamp() }, { merge: true }));
      await assertFails(setDoc(doc(db('mecA2'), 'sinistro', 'SIN-A2'), { assignedToName: 'Outro' }, { merge: true }));
    });

    it('mecânico não cria nem exclui sinistro', async () => {
      await assertFails(deleteDoc(doc(db('mecA'), 'sinistro', 'SIN-A')));
      await assertFails(setDoc(doc(db('mecA'), 'sinistro', 'SIN-NOVO'), { credenciadoId: 'credA' }));
    });

    it('viewers: membro grava/apaga só o próprio viewer', async () => {
      const viewer = { uid: 'mecA', name: 'A', active: true, lastSeenAtMillis: Date.now(), presenceSessionId: 's' };
      await assertSucceeds(setDoc(doc(db('mecA'), 'sinistro', 'SIN-A', 'viewers', 'mecA'), viewer, { merge: true }));
      await assertSucceeds(getDocs(query(collection(db('mecA2'), 'sinistro', 'SIN-A', 'viewers'), where('lastSeenAtMillis', '>', 0), limit(10))));
      await assertFails(setDoc(doc(db('mecA'), 'sinistro', 'SIN-A', 'viewers', 'mecA2'), { ...viewer, uid: 'mecA2' }));
      await assertFails(setDoc(doc(db('mecB'), 'sinistro', 'SIN-A', 'viewers', 'mecB'), { ...viewer, uid: 'mecB' }));
      await assertFails(getDocs(collection(db('mecB'), 'sinistro', 'SIN-A', 'viewers')));
      await assertFails(deleteDoc(doc(db('mecA2'), 'sinistro', 'SIN-A', 'viewers', 'mecA')));
      await assertSucceeds(deleteDoc(doc(db('mecA'), 'sinistro', 'SIN-A', 'viewers', 'mecA')));
    });
  });

  // ---------------------------------------------------------------------
  describe('vistorias', () => {
    it('mecânico lê vistorias da própria oficina e não de outra', async () => {
      const d = db('mecA2');
      await assertSucceeds(getDoc(doc(d, 'vistorias', 'VIS-2026-0001')));
      await assertFails(getDoc(doc(d, 'vistorias', 'VIS-2026-0002')));
      await assertSucceeds(getDocs(query(collection(d, 'vistorias'), where('credenciadoId', '==', 'credA'))));
      await assertFails(getDocs(query(collection(d, 'vistorias'), where('credenciadoId', '==', 'credB'))));
      await assertFails(getDocs(collection(d, 'vistorias')));
      await assertFails(getDoc(doc(db('mecB'), 'vistorias', 'VIS-2026-0001')));
    });

    it('queries por sinistroId e por inspectorId+status (telas do app)', async () => {
      const d = db('mecA2');
      await assertSucceeds(getDocs(query(collection(d, 'vistorias'), where('sinistroId', '==', 'SIN-A'))));
      await assertSucceeds(getDocs(query(collection(d, 'vistorias'), where('sinistroId', '==', 'SIN-A'), limit(6))));
      await assertFails(getDocs(query(collection(d, 'vistorias'), where('sinistroId', '==', 'SIN-B'))));
      await assertSucceeds(getDocs(query(collection(db('mecA'), 'vistorias'),
        where('inspectorId', '==', 'mecA'), where('status', '==', 'EM_ANDAMENTO'), limit(10))));
      await assertSucceeds(getDocs(query(collection(db('mecA'), 'vistorias'),
        where('inspectorId', '==', 'mecA'), where('status', '==', 'EM_ANDAMENTO'), where('coletaModo', '==', 'em_massa'))));
      await assertFails(getDocs(query(collection(db('mecB'), 'vistorias'), where('inspectorId', '==', 'mecA'))));
      // vistoria legada sem credenciadoId: visível via sinistro
      await assertSucceeds(getDoc(doc(d, 'vistorias', 'VIS-2026-0004')));
    });

    it('mecânico com doc legado em users/{uid} (sem doc por e-mail) ainda escreve na própria vistoria', async () => {
      const ref = doc(db('mecLegado'), 'vistorias', 'VIS-2026-LEGADO');
      await assertSucceeds(setDoc(ref, {
        chatmessages: arrayUnion({ role: 'user', text: 'oi' }),
      }, { merge: true }));
    });

    it('grava os campos do fluxo do app', async () => {
      const ref = doc(db('mecA'), 'vistorias', 'VIS-2026-0001');
      await assertSucceeds(setDoc(ref, {
        chatmessages: arrayUnion({ role: 'user', text: 'nova mensagem' }),
        agentLastTurnAt: serverTimestamp(), agentBusinessExpiresAt: new Date(), updatedAt: serverTimestamp(),
      }, { merge: true }));
      await assertSucceeds(setDoc(ref, { coletaModo: 'em_massa', updatedAt: serverTimestamp() }, { merge: true }));
      await assertSucceeds(setDoc(ref, { envioEmMassaRascunho: { l1: { status: 'pendente', tipo: 'foto' } } }, { merge: true }));
      await assertSucceeds(updateDoc(ref, { 'envioEmMassaRascunho.l1.status': 'enviado' }));
      await assertSucceeds(updateDoc(ref, { envioEmMassaRascunho: deleteField(), envioEmMassaConfirmadoOffline: deleteField() }));
      await assertSucceeds(setDoc(ref, { orcamentoRascunho: [{ id: 'i1', origem: 'mecanico', valor: 10 }] }, { merge: true }));
      await assertSucceeds(setDoc(ref, { orcamentoItensFinais: [{ id: 'i1', valor: 10 }] }, { merge: true }));
      await assertSucceeds(setDoc(ref, { images: arrayUnion({ imageId: 'img_1', url: 'u' }) }, { merge: true }));
      await assertSucceeds(setDoc(ref, { lastAudioNumber: 1 }, { merge: true }));
      // outro mecânico da mesma oficina também grava (mesma regra das Functions)
      await assertSucceeds(setDoc(doc(db('funA'), 'vistorias', 'VIS-2026-0001'), {
        chatmessages: arrayUnion({ role: 'ai', text: 'ok' }),
      }, { merge: true }));
    });

    it('não reescreve histórico (chatmessages/images são só-acréscimo)', async () => {
      const ref = doc(db('mecA'), 'vistorias', 'VIS-2026-0001');
      await assertFails(updateDoc(ref, { chatmessages: [] }));
      await assertFails(updateDoc(ref, { chatmessages: [{ role: 'user', text: 'forjado' }] }));
    });

    it('transições de status permitidas e proibidas', async () => {
      const ref = doc(db('mecA'), 'vistorias', 'VIS-2026-0001');
      await assertFails(updateDoc(ref, { status: 'FINALIZADA' }));
      await assertFails(updateDoc(ref, { status: 'REJEITADA' }));
      await assertFails(updateDoc(ref, { status: 'APROVADA' }));
      await assertSucceeds(updateDoc(ref, { status: 'EM_ANALISE_OPERACIONAL', submittedAt: serverTimestamp() }));
      // depois de enviada, não volta pra EM_ANDAMENTO
      await assertFails(updateDoc(ref, { status: 'EM_ANDAMENTO' }));
    });

    it('expirar e abandonar', async () => {
      const ref = doc(db('mecA'), 'vistorias', 'VIS-2026-0001');
      await assertSucceeds(updateDoc(ref, { status: 'EXPIRADA', expiredAt: serverTimestamp() }));
      await assertSucceeds(updateDoc(ref, { status: 'ABANDONADA', abandonedAt: serverTimestamp() }));
    });

    it('não altera campos de vínculo/laudo', async () => {
      const ref = doc(db('mecA'), 'vistorias', 'VIS-2026-0001');
      await assertFails(updateDoc(ref, { credenciadoId: 'credB' }));
      await assertFails(updateDoc(ref, { sinistroId: 'SIN-B' }));
      await assertFails(updateDoc(ref, { inspectorId: 'mecB' }));
      await assertFails(updateDoc(ref, { laudo: 'forjado' }));
      await assertFails(updateDoc(ref, { analisadoPorUid: 'mecA' }));
    });

    it('outra oficina não escreve; ninguém exclui', async () => {
      await assertFails(updateDoc(doc(db('mecB'), 'vistorias', 'VIS-2026-0001'), { chatmessages: arrayUnion({ t: 1 }) }));
      await assertFails(deleteDoc(doc(db('mecA'), 'vistorias', 'VIS-2026-0001')));
      await assertFails(deleteDoc(doc(db('mecB'), 'vistorias', 'VIS-2026-0002')));
    });

    it('cria vistoria (contador + vistoria + espelho no sinistro) num batch', async () => {
      const d = db('mecA');
      await assertSucceeds(runTransaction(d, async (tx) => {
        const c = doc(d, 'counters', 'vistorias_2026');
        const snap = await tx.get(c);
        tx.set(c, { lastNumber: snap.data().lastNumber + 1, year: 2026, updatedAt: serverTimestamp() }, { merge: true });
      }));
      const b = writeBatch(d);
      b.set(doc(d, 'vistorias', 'VIS-2026-0005'), {
        idvistoria: 'VIS-2026-0005', sinistroId: 'SIN-A2', status: 'EM_ANDAMENTO', credenciadoId: 'credA',
        inspectorId: 'mecA', tipoVistoria: 'ORIGINAL', chatmessages: [], images: [], audios: [], laudo: '',
        pdfLaudoUrl: '', createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
      });
      b.set(doc(d, 'sinistro', 'SIN-A2'), {
        vistoriaAtualId: 'VIS-2026-0005', vistoriaAtualStatus: 'EM_ANDAMENTO', vistoriaAtualTipo: 'ORIGINAL',
        vistoriaAtualOrigemId: deleteField(), retificacaoAtualId: deleteField(), ultimaVistoriaAt: serverTimestamp(),
      }, { merge: true });
      await assertSucceeds(b.commit());
    });

    it('não cria vistoria para sinistro/oficina alheios ou em nome de outro', async () => {
      const d = db('mecA');
      const base = { idvistoria: 'VIS-2026-0009', status: 'EM_ANDAMENTO', inspectorId: 'mecA', credenciadoId: 'credA', sinistroId: 'SIN-A' };
      await assertFails(setDoc(doc(d, 'vistorias', 'VIS-2026-0009'), { ...base, sinistroId: 'SIN-B' }));
      await assertFails(setDoc(doc(d, 'vistorias', 'VIS-2026-0009'), { ...base, credenciadoId: 'credB', sinistroId: 'SIN-B' }));
      await assertFails(setDoc(doc(d, 'vistorias', 'VIS-2026-0009'), { ...base, inspectorId: 'mecA2' }));
      await assertFails(setDoc(doc(d, 'vistorias', 'VIS-2026-0009'), { ...base, status: 'FINALIZADA' }));
      await assertFails(setDoc(doc(d, 'vistorias', 'VIS-2026-0009'), { ...base, analisadoPorUid: 'mecA' }));
      await assertFails(setDoc(doc(d, 'vistorias', 'OUTRO-ID'), { ...base }));
      await assertFails(setDoc(doc(db('pend'), 'vistorias', 'VIS-2026-0009'), { ...base, inspectorId: 'pend' }));
    });

    it('retificação: marca a original REJEITADA e cria a nova', async () => {
      const d = db('mecA');
      const b = writeBatch(d);
      b.set(doc(d, 'vistorias', 'VIS-2026-0006'), {
        idvistoria: 'VIS-2026-0006', sinistroId: 'SIN-A2', status: 'EM_ANDAMENTO', credenciadoId: 'credA',
        inspectorId: 'mecA', tipoVistoria: 'RETIFICACAO', vistoriaOrigemId: 'VIS-2026-0003',
        ajustesNecessarios: 'Foto traseira', contextoVistoriaAnterior: '', chatmessages: [],
      });
      b.set(doc(d, 'vistorias', 'VIS-2026-0003'), {
        status: 'REJEITADA', retificacaoAtualId: 'VIS-2026-0006', ajustesNecessarios: 'Foto traseira',
        motivoRejeicao: 'Foto traseira', rejeitadaEm: serverTimestamp(), updatedAt: serverTimestamp(),
      }, { merge: true });
      b.set(doc(d, 'sinistro', 'SIN-A2'), {
        vistoriaAtualId: 'VIS-2026-0006', vistoriaAtualStatus: 'EM_ANDAMENTO', vistoriaAtualTipo: 'RETIFICACAO',
        vistoriaAtualOrigemId: 'VIS-2026-0003', retificacaoAtualId: 'VIS-2026-0006', ultimaVistoriaAt: serverTimestamp(),
      }, { merge: true });
      await assertSucceeds(b.commit());
    });

    it('campos de retificação não podem ser gravados numa vistoria não rejeitada', async () => {
      await assertFails(updateDoc(doc(db('mecA'), 'vistorias', 'VIS-2026-0001'), { motivoRejeicao: 'x', retificacaoAtualId: 'y' }));
    });

    it('reconciliação offline: troca VIS-OFFLINE-NNNN pelo id definitivo (apaga o provisório no mesmo batch)', async () => {
      const temp = {
        idvistoria: 'VIS-OFFLINE-1234', sinistroId: 'SIN-A2', status: 'EM_ANDAMENTO', coletaModo: 'em_massa',
        credenciadoId: 'credA', inspectorId: 'mecA', chatmessages: [], images: [],
      };
      const d = db('mecA');
      await assertSucceeds(setDoc(doc(d, 'vistorias', 'VIS-OFFLINE-1234'), temp));
      // exclusão isolada do provisório: negada
      await assertFails(deleteDoc(doc(d, 'vistorias', 'VIS-OFFLINE-1234')));
      const b = writeBatch(d);
      b.set(doc(d, 'vistorias', 'VIS-2026-0007'), { ...temp, idvistoria: 'VIS-2026-0007', status: 'EM_ANALISE_OPERACIONAL' });
      b.update(doc(d, 'sinistro', 'SIN-A2'), { vistoriaAtualId: 'VIS-2026-0007' });
      b.delete(doc(d, 'vistorias', 'VIS-OFFLINE-1234'));
      await assertSucceeds(b.commit());
    });

    it('outro mecânico não apaga o provisório de alguém', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), 'vistorias', 'VIS-OFFLINE-5555'), {
          idvistoria: 'VIS-OFFLINE-5555', sinistroId: 'SIN-A2', status: 'EM_ANDAMENTO', credenciadoId: 'credA', inspectorId: 'mecA',
        });
      });
      const d = db('mecA2');
      const b = writeBatch(d);
      b.set(doc(d, 'vistorias', 'VIS-2026-0008'), {
        idvistoria: 'VIS-2026-0008', sinistroId: 'SIN-A2', status: 'EM_ANDAMENTO', credenciadoId: 'credA', inspectorId: 'mecA2',
      });
      b.update(doc(d, 'sinistro', 'SIN-A2'), { vistoriaAtualId: 'VIS-2026-0008' });
      b.delete(doc(d, 'vistorias', 'VIS-OFFLINE-5555'));
      await assertFails(b.commit());
    });

    it('audios: membro lê, ninguém escreve pelo cliente', async () => {
      await assertSucceeds(getDocs(collection(db('mecA2'), 'vistorias', 'VIS-2026-0001', 'audios')));
      await assertFails(getDocs(collection(db('mecB'), 'vistorias', 'VIS-2026-0001', 'audios')));
      await assertFails(setDoc(doc(db('mecA'), 'vistorias', 'VIS-2026-0001', 'audios', 'AUD_02'), { x: 1 }));
    });
  });

  // ---------------------------------------------------------------------
  describe('counters', () => {
    it('incrementa de 1 em 1, só contadores vistorias_AAAA', async () => {
      const d = db('mecA');
      await assertFails(updateDoc(doc(d, 'counters', 'vistorias_2026'), { lastNumber: 10 }));
      await assertFails(updateDoc(doc(d, 'counters', 'vistorias_2026'), { lastNumber: 4 }));
      await assertFails(setDoc(doc(d, 'counters', 'outro'), { lastNumber: 1 }));
      await assertSucceeds(setDoc(doc(d, 'counters', 'vistorias_2027'), { lastNumber: 1, year: 2027, updatedAt: serverTimestamp() }, { merge: true }));
      await assertFails(deleteDoc(doc(d, 'counters', 'vistorias_2026')));
      await assertFails(updateDoc(doc(db('pend'), 'counters', 'vistorias_2026'), { lastNumber: 5 }));
    });
  });

  // ---------------------------------------------------------------------
  describe('tabelaPrecos', () => {
    it('leitura por ativos; ninguém escreve pelo cliente', async () => {
      await assertSucceeds(getDocs(collection(db('mecA'), 'tabelaPrecos', 'leve', 'pecas')));
      await assertFails(getDocs(collection(db('pend'), 'tabelaPrecos', 'leve', 'pecas')));
      await assertFails(setDoc(doc(db('mecA'), 'tabelaPrecos', 'leve', 'pecas', 'parachoque'), { valorPeca: 1 }));
      await assertFails(setDoc(doc(db('analista'), 'tabelaPrecos', 'leve', 'pecas', 'novo'), { valorPeca: 1 }));
    });
  });

  // ---------------------------------------------------------------------
  describe('userDevices', () => {
    it('só o dono mexe nos próprios tokens', async () => {
      await assertSucceeds(setDoc(doc(db('mecA'), 'userDevices', 'mecA', 'tokens', 't2'), { token: 't2', uid: 'mecA' }));
      await assertSucceeds(deleteDoc(doc(db('mecA'), 'userDevices', 'mecA', 'tokens', 't1')));
      await assertFails(getDocs(collection(db('mecB'), 'userDevices', 'mecA', 'tokens')));
      await assertFails(setDoc(doc(db('mecB'), 'userDevices', 'mecA', 'tokens', 't3'), { token: 'x' }));
    });
  });

  // ---------------------------------------------------------------------
  describe('analista (painel web)', () => {
    it('via admins/{uid}: lista users, sinistro, vistorias, clientes, veiculos', async () => {
      const d = db('analista');
      await assertSucceeds(getDocs(collection(d, 'users')));
      await assertSucceeds(getDocs(collection(d, 'sinistro')));
      await assertSucceeds(getDoc(doc(d, 'sinistro', 'SIN-B')));
      await assertSucceeds(getDocs(collection(d, 'vistorias')));
      await assertSucceeds(getDocs(collection(d, 'vistorias', 'VIS-2026-0002', 'audios')));
      await assertSucceeds(getDocs(collection(d, 'clientes')));
      await assertSucceeds(getDocs(collection(d, 'veiculos')));
      await assertSucceeds(getDoc(doc(d, 'admins', 'analista')));
    });

    it('via custom claim analista=true', async () => {
      const d = ctx(env, 'outroAnalista', { email: 'oa@seguradora.com', analista: true }).firestore();
      await assertSucceeds(getDocs(collection(d, 'users')));
      await assertSucceeds(getDocs(collection(d, 'sinistro')));
    });

    it('aprova/bloqueia usuário só pelos campos de aprovação', async () => {
      const d = db('analista');
      await assertSucceeds(updateDoc(doc(d, 'users', USERS.pend.email), {
        status: 'ativo', atualizadoEm: serverTimestamp(), aprovadoEm: serverTimestamp(), aprovadoPor: 'analista',
      }));
      await assertSucceeds(updateDoc(doc(d, 'users', USERS.mecB.email), {
        status: 'bloqueado', atualizadoEm: serverTimestamp(), bloqueadoEm: serverTimestamp(), bloqueadoPor: 'analista',
      }));
      await assertFails(updateDoc(doc(d, 'users', USERS.mecA.email), { credenciadoId: 'credB' }));
      await assertFails(updateDoc(doc(d, 'users', USERS.mecA.email), { status: 'superadmin' }));
      await assertFails(deleteDoc(doc(d, 'users', USERS.mecA.email)));
    });

    it('analista não escreve sinistro/vistorias pelo cliente (painel usa /api)', async () => {
      await assertFails(updateDoc(doc(db('analista'), 'sinistro', 'SIN-A'), { status: 'FINALIZADO' }));
      await assertFails(updateDoc(doc(db('analista'), 'vistorias', 'VIS-2026-0001'), { status: 'FINALIZADA' }));
    });

    it('não-analista não lista users/clientes nem lê admins de outro', async () => {
      const d = db('mecA');
      await assertFails(getDocs(collection(d, 'users')));
      await assertFails(getDocs(collection(d, 'clientes')));
      await assertFails(getDocs(collection(d, 'veiculos')));
      await assertFails(getDoc(doc(d, 'admins', 'analista')));
      await assertFails(setDoc(doc(d, 'admins', 'mecA'), { x: 1 }));
      await assertFails(updateDoc(doc(d, 'users', USERS.pend.email), { status: 'ativo' }));
    });

    it('coleções sem regra ficam fechadas', async () => {
      await assertFails(getDocs(collection(db('analista'), 'alertas')));
      await assertFails(getDocs(collection(db('mecA'), 'alertas')));
    });
  });
});

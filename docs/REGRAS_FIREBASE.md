# Regras de segurança do Firebase (Firestore + Storage)

Projeto: `fho-argos`. Arquivos:

- `firestore.rules`: regras do Firestore.
- `storage.rules`: regras do Cloud Storage.
- `firestore.indexes.json`: índice composto usado pela function `expireStaleVistorias`.
- `rules-tests/`: testes automatizados no emulador (59 casos).

Os arquivos estão referenciados em `firebase.json`, nos blocos `firestore` e `storage`.

> **Importante:** estas regras valem só para o **SDK cliente**, ou seja, o app Flutter e o navegador do painel web.
> Cloud Functions (`functions/index.js`), `services/laudo-service`, `adk_agents` e as rotas `/api` do painel usam Admin SDK ou credencial de servidor. Por isso **ignoram** as regras e continuam funcionando como antes.

---

## 1. Papéis

| Papel | Como é identificado |
|---|---|
| **Não autenticado** | Sem `request.auth`. |
| **Autenticado** | Tem conta no Firebase Auth, com qualquer status. |
| **Pendente / bloqueado** | `users/{email}.status` é `pendente` ou `bloqueado`. |
| **Ativo** | `users/{email}.status == 'ativo'`. O e-mail do token, em minúsculas, é o id do doc. |
| **Mecânico da oficina X** | É ativo e atende a uma das condições: `users/{email}.credenciadoId == X`, **ou** o uid está em `credenciados/X.funcionariosUids`. É a mesma regra do `assertCanAccessVistoria` das Functions. |
| **Analista / admin (painel)** | Atende a uma das condições: custom claim `analista: true` **ou** `admin: true`, **ou** existe o documento `admins/{uid}`. |

---

## 2. Matriz de acesso (Firestore)

Legenda: ✅ permitido · ❌ negado · ⚠️ permitido com restrições (ver coluna "Restrições")

| Coleção | Não autenticado | Autenticado (pendente/bloqueado) | Mecânico ativo | Analista | Restrições |
|---|---|---|---|---|---|
| `users/{email}`: ler | ⚠️ | ⚠️ | ⚠️ | ✅ (lista tudo) | **Não autenticado:** só `get` de e-mail inexistente ou de solicitação `pendente` com `origem: 'primeiro_acesso'`. **Demais:** só o próprio doc (id = e-mail, legado id = uid, ou queries `uid`/`authUid`/`email` == o próprio). |
| `users/{email}`: criar | ⚠️ | ⚠️ | ⚠️ | ⚠️ | **Sempre:** `status: 'pendente'` e sem `credenciadoId`. **Logado:** só o doc do próprio e-mail, com `uid`/`authUid` próprios. **Sem login:** só `origem: 'primeiro_acesso'` com `uid` e `authUid` vazios. |
| `users/{email}`: atualizar | ❌ | ⚠️ | ⚠️ | ⚠️ | **Próprio usuário:** só campos de perfil/login (nunca `status`, `aprovado*`, `bloqueado*` ou papéis). `credenciadoId`/`credenciadoNome` só podem ser definidos **uma vez** (quando vazios), e o credenciado tem que existir. **Analista:** só `status` (`pendente`/`ativo`/`bloqueado`), `atualizadoEm`, `aprovadoEm/Por` e `bloqueadoEm/Por`. |
| `users`: excluir | ❌ | ❌ | ❌ | ❌ | |
| `admins/{uid}` | ❌ | ⚠️ | ⚠️ | ⚠️ | Só `get` do próprio doc. Escrita só pelo console ou Admin SDK. |
| `credenciados`: ler | ❌ | ✅ | ✅ | ✅ | O onboarding lista as oficinas. |
| `credenciados`: atualizar | ❌ | ❌ | ⚠️ | ❌ | **Membro da oficina:** só `valoresHoraMaoObra` + `valoresHoraAtualizadoEm`. **Onboarding:** acrescentar **só o próprio uid** em `funcionariosUids` (+ `atualizadoEm`), e só se `users/{email}.credenciadoId` apontar para essa oficina após o batch. |
| `credenciados`: criar/excluir | ❌ | ❌ | ❌ | ❌ | Painel via `/api` (Admin SDK). |
| `sinistro`: ler | ❌ | ❌ | ⚠️ | ✅ | **Mecânico:** só sinistros da própria oficina (`credenciadoId`) ou atribuídos a ele (`assignedToUid`). |
| `sinistro`: atualizar | ❌ | ❌ | ⚠️ | ❌ | **Campos permitidos:** espelho da vistoria (`vistoriaAtual*`, `retificacaoAtualId`, `ultimaVistoriaAt`), presença (`activeViewers*`) e check-in (`assignedTo*`, `assignedAt`, `assignedByAction`, `isAssigned`, `status`, `chatEnabled`, `chatStatus`, `checkInAt`, `statusUpdatedAt`). **Check-in:** só assume sinistro livre ou já seu, sempre para si. **`status`:** só `EM_ANDAMENTO`. **`vistoriaAtualStatus`:** só `EM_ANDAMENTO`, `EM_ANALISE_OPERACIONAL`, `EXPIRADA` ou `ABANDONADA`. |
| `sinistro`: criar/excluir | ❌ | ❌ | ❌ | ❌ | Painel via `/api`. |
| `sinistro/{id}/viewers/{uid}` | ❌ | ❌ | ⚠️ | ✅ (ler) | Lê quem enxerga o sinistro. Cada um grava/apaga só o próprio doc. |
| `vistorias`: ler | ❌ | ❌ | ⚠️ | ✅ | **Mecânico:** só se for o inspetor, se for da oficina da vistoria, ou se for da oficina do sinistro da vistoria. |
| `vistorias`: criar | ❌ | ❌ | ⚠️ | ❌ | `id == idvistoria`, `inspectorId == uid`, oficina = a do mecânico e a do sinistro. `status` `EM_ANDAMENTO` (ou `EM_ANALISE_OPERACIONAL`, por causa da reconciliação offline). Sem campos de análise. |
| `vistorias`: atualizar | ❌ | ❌ | ⚠️ | ❌ | **Campos permitidos:** `chatmessages`, `images`, `orcamentoRascunho`, `orcamentoItensFinais`, `envioEmMassaRascunho`, `envioEmMassaConfirmadoOffline`, `coletaModo`, `lastAudioNumber`, `agentLastTurnAt`, `agentBusinessExpiresAt`, `updatedAt`, `submittedAt`/`expiredAt`/`abandonedAt` e `status`. **`chatmessages`/`images`:** só acréscimo. **`status`:** `EM_ANDAMENTO` → `EXPIRADA`/`ABANDONADA`/`EM_ANALISE_OPERACIONAL`, e `EXPIRADA` → `ABANDONADA`. **Campos de retificação** (`retificacaoAtualId`, `motivoRejeicao`, `ajustesNecessarios`, `rejeitadaEm`): só em vistoria `REJEITADA`. |
| `vistorias`: excluir | ❌ | ❌ | ⚠️ | ❌ | **Só** o doc provisório `VIS-OFFLINE-NNNN` do próprio inspetor. Tem que ser no mesmo batch que cria a vistoria definitiva `VIS-AAAA-NNNN` e aponta o sinistro para ela. |
| `vistorias/{id}/audios` | ❌ | ❌ | ⚠️ ler | ✅ ler | Escrita só pela Cloud Function. |
| `counters/vistorias_AAAA` | ❌ | ❌ | ⚠️ | ✅ ler | Ler; criar com `lastNumber: 1`; atualizar só com `lastNumber + 1`. Outros contadores são negados. |
| `userDevices/{uid}/tokens/*` | ❌ | ⚠️ | ⚠️ | ⚠️ | Só o dono, em qualquer status. Igual à regra publicada. |
| `tabelaPrecos/**` | ❌ | ❌ | ✅ ler | ✅ ler | Nenhuma escrita pelo cliente. |
| `clientes`, `veiculos` | ❌ | ❌ | ❌ | ✅ ler | Lidos no navegador pelo painel (`lib/services/registros.ts`). |
| Demais (`alertas`, `seguradoras`, `_processedEvents`, `usuarios`, ...) | ❌ | ❌ | ❌ | ❌ | Só Admin SDK. Não existe regra genérica `/{document=**}`. |

### Storage

| Caminho | Quem lê (SDK) | Quem envia | Limites |
|---|---|---|---|
| `vistorias/{id}/images/{arquivo}` | Analista, ou mecânico com acesso à vistoria | Mecânico com acesso à vistoria (só criação, sem sobrescrever) | `image/(jpeg\|png\|webp\|heic\|heif)`, entre 1 byte e 15 MB |
| `vistorias/{id}/audio/{arquivo}` | idem | idem | `audio/(mpeg\|mp4\|aac\|m4a\|wav\|ogg\|webm)`, até 25 MB |
| `vistorias/{id}/vistorias/*.pdf` (laudo/orçamento) | idem | Ninguém pelo cliente (gravado pelo `laudo-service`) | n/a |
| `users/{e-mail codificado}/profile_<ts>.jpg` | O próprio usuário ou analista | O próprio usuário (só criação) | `image/(jpeg\|png\|webp)`, até 5 MB |
| Qualquer outro caminho | ❌ | ❌ | n/a |

"Acesso à vistoria" no Storage significa ser ativo e o inspetor dela, ou ser membro da oficina gravada na vistoria. As regras leem `vistorias/{id}`, `users/{email}`, `credenciados/{id}` e `admins/{uid}` no Firestore.

> URLs com `?token=` (geradas por `getDownloadURL` ou pelo `laudo-service`) **não passam pelas regras**: quem tem a URL baixa o arquivo. Isso continua igual e é o que o painel usa para exibir fotos, áudios e PDFs.

---

## 3. O que muda em relação às regras publicadas

| Antes (publicado) | Agora |
|---|---|
| Firestore: `match /{document=**} allow read, write: if request.time < 2026-12-28`. Leitura e escrita **sem login** em tudo até 28/12/2026; depois disso, tudo negado, inclusive o app. | Sem regra genérica. Cada coleção tem regra própria, sem data de expiração. |
| `counters/*`: qualquer autenticado lê e escreve qualquer contador. | Só usuário ativo, só `vistorias_AAAA`, só incremento de 1. |
| `sinistro/*/viewers/*`: qualquer autenticado lê e escreve qualquer viewer. | Só quem enxerga o sinistro; cada um escreve apenas o próprio viewer. |
| `userDevices/{uid}/tokens/*`: só o dono. | Igual. |
| Storage: `allow read, write: if request.auth != null` em todo o bucket. | Por caminho, com checagem de vistoria/oficina, tipo e tamanho; sem sobrescrita. |
| Usuário podia se auto-ativar (`status: 'ativo'`) e trocar `credenciadoId`. | `status` só muda pelo analista (ou Admin SDK). `credenciadoId` só é definido uma vez. |
| Mecânico podia apagar ou editar qualquer sinistro ou vistoria. | Só campos do fluxo do app, só da própria oficina, sem exclusões (exceto o provisório offline). |

---

## 4. Setup obrigatório ANTES do deploy (analistas do painel)

O painel web hoje **não tem nenhum controle de papel**. Em `components/registros/parceiros-table.tsx` existe `BYPASS_ADMIN_CHECK = true`, e o código menciona um `admins/{uid}` que nunca é lido. Ainda assim, ele lê pelo navegador `users`, `sinistro`, `vistorias`, `clientes` e `veiculos` inteiros, e grava `users.status`.

Com as regras novas, **quem não for analista verá o painel vazio ou com erro de permissão.** Antes de publicar, marque cada analista de uma destas formas:

**Opção A (mais simples): documento `admins/{uid}`**

1. Pegue o UID do analista em Firebase Console › Authentication.
2. Em Firestore, crie o documento `admins/{UID}` com qualquer conteúdo, por exemplo `{ nome: "Fulano", criadoEm: <timestamp> }`.
3. O efeito é imediato e não precisa de novo login.

**Opção B: custom claim**

Rode um script com Admin SDK:

```js
await admin.auth().setCustomUserClaims(uid, { analista: true }); // ou { admin: true }
```

O analista precisa sair e entrar de novo (ou o token renovar, em até 1 h).

Sugestão para o painel, que não está nestas regras: trocar `BYPASS_ADMIN_CHECK` por uma leitura de `admins/{auth.currentUser.uid}`, que as regras já permitem para o próprio uid.

### Permissão do Storage para ler o Firestore

`storage.rules` usa `firestore.get()`. No primeiro `firebase deploy` com essas regras, o CLI pergunta se pode conceder ao agente de serviço do Storage o papel **Firebase Rules Firestore Service Agent**. Responda **sim**. Sem isso, todo acesso do app ao Storage é negado.

---

## 5. Deploy (executar manualmente; não foi executado)

```bash
# 1) Rodar os testes no emulador (precisa de Java 11+)
cd rules-tests && npm install && npm run test:emu && cd ..

# 2) Publicar só as regras
firebase deploy --only firestore:rules,storage --project fho-argos

# 3) (Opcional) Publicar o índice composto usado por expireStaleVistorias
#    O comando mantém os índices já existentes no projeto que não estão no arquivo, mas pergunta antes de apagar.
firebase deploy --only firestore:indexes --project fho-argos
```

O índice em `firestore.indexes.json` é `vistorias (status ASC, agentBusinessExpiresAt ASC)`, exigido pela query `where status == 'EM_ANDAMENTO' && agentBusinessExpiresAt <= now` da function agendada. Se ele não existir, a function falha com `FAILED_PRECONDITION` e um link para criá-lo. As demais queries do app e das functions são de igualdade ou de campo único e não precisam de índice composto.

---

## 6. Rollback

Para voltar às regras que estavam publicadas, use os rulesets atuais:

- Firestore: `projects/fho-argos/rulesets/1e2cf5bd-3580-4b7b-afa5-444a23e634da`
- Storage: `projects/fho-argos/rulesets/1eaad164-b0d4-410d-aea3-b4054909dd18`

Há duas formas de fazer isso:

- **Pelo console:** Firestore › Regras › Histórico (e Storage › Regras › Histórico). Selecione a versão anterior e clique em "Publicar".
- **Pela API:** atualize o release apontando para o ruleset antigo:
  ```bash
  curl -X PATCH -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    "https://firebaserules.googleapis.com/v1/projects/fho-argos/releases/cloud.firestore" \
    -d '{"release":{"name":"projects/fho-argos/releases/cloud.firestore","rulesetName":"projects/fho-argos/rulesets/1e2cf5bd-3580-4b7b-afa5-444a23e634da"}}'
  ```
  Para o Storage, o release se chama `firebase.storage/fho-argos.firebasestorage.app`.

Lembre que as regras antigas de Firestore expiram em **28/12/2026**.

---

## 7. Riscos residuais / decisões conscientes

1. **Fluxos sem login no `login_page.dart`.** "Primeiro acesso" e "senha errada → vincular Google" consultam `users/{email}` antes de autenticar, e o primeiro acesso cria a solicitação.
   - Para não quebrar esses fluxos, ficou permitido sem login:
     - `get` de e-mail inexistente ou de solicitação `pendente` com `origem: 'primeiro_acesso'`;
     - criar solicitação pendente vazia.
   - **Riscos:**
     - spam de solicitações;
     - descobrir se um e-mail tem cadastro: a leitura negada indica que o cadastro existe e não é do primeiro acesso.
   - **O que deixou de funcionar:** com conta ativa, a mensagem "e-mail já liberado" e a dica "esta conta usa Google" passam a cair no erro genérico.
   - **Ideal:** mover essas checagens para uma Cloud Function `onCall` com App Check.
2. **Onboarding define a oficina.** Um usuário **ativo** sem `credenciadoId` pode escolher **qualquer** oficina, uma única vez, e passa a ver os sinistros dela. É assim que o app funciona hoje, porque o perfil só é completado depois da aprovação.
   - **Mitigação:** o analista define `credenciadoId` ao aprovar, via Admin SDK, ou confere a oficina escolhida.
   - Depois de definida, a oficina não pode ser trocada pelo próprio usuário. Só o Admin SDK troca.
3. **Contas e-mail/senha não verificadas.** Se um admin aprovar `users/{email}` antes de a pessoa criar a conta, quem criar primeiro uma conta Auth com aquele e-mail herda o doc.
   - **Mitigação:** exigir verificação de e-mail no app ou aprovar só depois do primeiro login. Na rota do painel, a conta é criada pelo próprio admin.
4. **Presença e espelho no sinistro.** Qualquer membro da oficina pode reescrever `activeViewers` e os campos `vistoriaAtual*` (com status restrito) de sinistros da oficina. As regras não validam o conteúdo dessas listas.
5. **Criação de vistoria aceita campos livres** (exceto os de análise), porque a reconciliação offline copia o doc inteiro. Um mecânico pode gravar, por exemplo, `laudo` na criação. Status final e aprovação continuam fora do alcance dele.
6. **Mecânico pode gravar orçamento e chat em qualquer status da vistoria.** Isso inclui vistorias já em análise; o fluxo de orçamento depende disso.
7. **Sinistros legados** com a oficina só em `workshopId`/`oficinaId`/`credenciadoID` (sem `credenciadoId`) não aparecem para mecânicos. O app já filtra por `credenciadoId`.
8. **Custo:** cada operação do mecânico faz 1–3 leituras extras de documento (`users`, `credenciados`, `sinistro`, `admins`), cobradas como leituras.
9. **Fora das regras, no painel web** (rotas com Admin SDK):
   - `POST /api/parceiros/aprovar-email` **não tem autenticação**: qualquer pessoa pode aprovar um e-mail pendente e recebe o link de redefinição de senha.
   - `/api/laudo-proxy` também não tem autenticação.
   - As demais rotas só exigem login, sem papel.
   - **Isso precisa ser corrigido no painel; as regras não protegem Admin SDK.**
10. **Métodos do app que as regras bloqueiam.** `markAsFinalizada`, `rejectVistoria`, `cancelVistoria`, `finishVistoria`, `discardVistoria(hardDelete)` e `cleanupRootTranscriptionFields` existem no `vistoria_chat_session_service.dart`, mas não são chamados. As regras bloqueiam esses métodos se alguém voltar a usá-los do app.

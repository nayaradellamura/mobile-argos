# Argos

![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/plataforma-Android-3DDC84?logo=android&logoColor=white)
![Firebase](https://img.shields.io/badge/backend-Firebase-FFCA28?logo=firebase&logoColor=white)
![TCC](https://img.shields.io/badge/projeto-TCC%20FHO-6f42c1)

Aplicativo Flutter para vistorias automotivas inteligentes — o módulo de campo do ecossistema **Argos**, usado por mecânicos e oficinas credenciadas para coletar evidências de sinistros com apoio de IA.

## Sobre o projeto

O Argos é o Trabalho de Conclusão de Curso do grupo *"Triagem Inteligente de Sinistros Automotivos em Ambiente Cloud-Native"* (Sistemas de Informação, FHO — Centro Universitário Hermínio Ometto).

**O problema:** no fluxo tradicional de FNOL (First Notice of Loss) das seguradoras, o próprio segurado tira as fotos do sinistro. O resultado costuma ser baixa qualidade e fácil de fraudar — o clássico *garbage in, garbage out*.

**A proposta:** inverter o modelo para **B2B**. A seguradora atribui o sinistro a uma **oficina credenciada**, e é o mecânico quem faz a coleta técnica das evidências — guiado por um agente de IA multimodal (Gemini) que cruza fotos com a narração falada do mecânico para identificar danos que a câmera sozinha não pega (problemas estruturais, por exemplo), e gera um laudo técnico estruturado e explicável (XAI). A classificação de severidade segue as categorias da **Resolução CONTRAN nº 810/2020** (pequena/média/grande monta).

### Arquitetura do ecossistema

O ecossistema do TCC é dividido em várias partes; este repositório cobre o app mobile e os serviços de backend que ele usa diretamente (Cloud Functions e a geração de documentos).

| Parte | Onde vive | O que faz |
|---|---|---|
| Painel web | repo separado (Next.js) | seguradora simula o FNOL, despacha vistorias, acompanha o Kanban de sinistros, revisa/aprova laudos |
| **App mobile (este repo)** | Flutter, Android | check-in da vistoria, coleta de evidências (guiada por IA ou tudo de uma vez), acompanhamento dos sinistros atribuídos |
| Agente de IA | Cloud Run, Python (ADK) | conduz a conversa guiada com o mecânico, aplica os guardrails de escopo da vistoria e decide quando liberar cada etapa (fotos, orçamento) |
| Backend serverless | Cloud Functions | processamento de áudio/imagem, notificações push, orquestração de status, texto-para-voz das respostas do agente |
| Geração de documentos | Cloud Run (`services/laudo-service`) | gera, em PDF, o laudo técnico, o relatório para o cliente final e o orçamento aprovado, a partir das evidências e do Gemini |

### Fluxo principal no app

1. Login com e-mail/senha ou Google.
2. Conclusão do perfil e vinculação com a oficina credenciada.
3. Listagem dos sinistros atribuídos ao mecânico.
4. Check-in da vistoria.
5. Coleta das evidências em dois modos: **passo a passo** (chat guiado por IA, foto a foto) ou **enviar tudo de uma vez** (fotos, áudios, texto e orçamento soltos, sem conversa). Funciona offline — o que for coletado sem rede sincroniza sozinho quando ela voltar.
6. Processamento das evidências e geração do laudo técnico pelo `services/laudo-service`.
7. Se a seguradora rejeitar o laudo, o mecânico recebe uma **retificação** (correção pontual, sempre pelo modo passo a passo).

### Destaques técnicos

- **Offline-first de verdade**: dá pra iniciar uma vistoria do zero sem internet nenhuma — ela recebe um ID provisório local e só é reconciliada com o número sequencial oficial quando a conexão volta, sem perder nada do que já foi coletado em campo.
- **Dois modos de coleta**: passo a passo (o agente de IA conduz a conversa, pede cada foto/áudio na hora certa e libera a tela de orçamento quando faz sentido) ou tudo de uma vez (o mecânico monta o pacote inteiro — fotos, áudios, texto e orçamento — e envia de uma só vez, pensado para quem prefere trabalhar sem o vaivém da conversa).
- **Orçamento assistido**: entrada manual item a item, importação de um orçamento pronto (foto ou arquivo) lida por IA, e tabela de preços de referência por categoria de veículo.
- **Texto-para-voz**: qualquer mensagem do agente pode ser ouvida em voz alta, útil pro mecânico que está com as mãos ocupadas no veículo.
- **Classificação explicável (XAI)**: a severidade do dano (pequena/média/grande monta, CONTRAN 810/2020) vem sempre acompanhada da justificativa do modelo, e o laudo sinaliza explicitamente quando há incongruência entre o relato do mecânico e as evidências, ou quando as fotos enviadas não sustentam a classificação.
- **Atualização OTA via Shorebird**: correções de código chegam ao app instalado sem passar pela loja — o celular atualiza sozinho ao abrir.

## Baixe o app para testar

Não precisa instalar nada de Flutter pra só experimentar o app no celular — o CI já gera um APK assinado a cada build.

1. Acesse a aba [**Actions**](../../actions/workflows/shorebird-release.yml) do repositório (precisa estar logado no GitHub, mesmo o repo sendo público — é assim que o GitHub libera download de artefato).
2. Abra a execução mais recente com o ícone verde (✓) de sucesso.
3. Em **Artifacts**, baixe `argos-release-apk-shorebird` e extraia o `.zip` — dentro está o `app-release.apk`.
4. Transfira o APK pro celular e instale (o Android vai pedir pra liberar "instalar de fontes desconhecidas" na primeira vez).

> Esse é o build que recebe atualizações automáticas depois de instalado (via Shorebird, OTA) — não precisa reinstalar a cada correção pequena, o app se atualiza sozinho ao abrir.

## Rodando o projeto localmente (para dev)

Pré-requisitos: [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ e um dispositivo/emulador Android.

```bash
git clone https://github.com/nayaradellamura/mobile-argos.git argos_app
cd argos_app
flutter pub get
flutter run
```

A configuração do Firebase (`google-services.json`, `firebase_options.dart`) já está versionada no repositório — não precisa criar projeto Firebase próprio pra rodar localmente.

> **Build de release no Windows:** builds `--release` (e por consequência `shorebird patch`/`shorebird release`) podem falhar em alguns ambientes Windows com JDK moderno (`Unable to establish loopback connection`). Se isso acontecer, use os workflows do GitHub Actions (`build-apk`, `shorebird-release`, `shorebird-patch` em `.github/workflows/`) — eles rodam em runner Linux e não têm esse problema. `flutter run` em modo debug funciona normalmente no Windows.

## Testes

Cada parte do projeto tem sua própria suíte, independente das outras:

```bash
# App Flutter (lógica de orçamento, parsing, rascunho de envio em massa...)
flutter test

# Cloud Functions
cd functions && npm test

# Geração de laudo/orçamento (services/laudo-service)
cd services/laudo-service && npm test

# Regras do Firestore/Storage (precisa do emulador do Firebase)
cd rules-tests && npm run test:emu
```

## Estrutura do projeto

- `lib/`: código-fonte do app Flutter
- `test/`: testes do app Flutter
- `android/`: projeto Android nativo
- `assets/`: imagens e ícones do app
- `functions/`: Firebase Cloud Functions (backend serverless) e seus testes
- `services/laudo-service/`: serviço Cloud Run que gera o laudo técnico, o relatório para o cliente e o orçamento aprovado em PDF
- `rules-tests/`: testes das regras de segurança do Firestore e do Storage
- `.github/workflows/`: pipelines de build/release/patch (CI)
- `firebase.json`, `firestore.rules`, `storage.rules`: configuração e regras de segurança do Firebase
- `pubspec.yaml`: dependências Flutter

## Plataforma ativa

- Android

As pastas de outras plataformas Flutter podem ser regeneradas no futuro com `flutter create .`, caso o projeto volte a precisar de iOS, Web ou Desktop.

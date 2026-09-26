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

O TCC é dividido em três partes; este repositório é só o app mobile.

| Parte | Onde vive | O que faz |
|---|---|---|
| Painel web | repo separado (Next.js) | seguradora simula o FNOL, despacha vistorias, acompanha o Kanban de sinistros, revisa/aprova laudos |
| **App mobile (este repo)** | Flutter, Android | check-in da vistoria, chat com IA guiando a coleta de fotos/áudio, acompanhamento dos sinistros atribuídos |
| Backend serverless | Cloud Functions + Vertex AI | processamento de áudio/imagem, geração do laudo, notificações push |

### Fluxo principal no app

1. Login com e-mail/senha ou Google.
2. Conclusão do perfil e vinculação com a oficina credenciada.
3. Listagem dos sinistros atribuídos ao mecânico.
4. Check-in da vistoria.
5. Chat guiado por IA vinculado ao sinistro.
6. Registro de fotos, áudios e mensagens de texto.
7. Processamento do áudio com IA e envio do laudo pro backend.

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

## Estrutura do projeto

- `lib/`: código-fonte do app Flutter
- `android/`: projeto Android nativo
- `assets/`: imagens e ícones do app
- `functions/`: Firebase Cloud Functions (backend serverless)
- `.github/workflows/`: pipelines de build/release/patch (CI)
- `firebase.json`: configuração do projeto Firebase
- `pubspec.yaml`: dependências Flutter

## Plataforma ativa

- Android

As pastas de outras plataformas Flutter podem ser regeneradas no futuro com `flutter create .`, caso o projeto volte a precisar de iOS, Web ou Desktop.

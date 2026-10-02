import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../services/argos_ai_service.dart';
import '../../services/argos_connectivity_service.dart';
import '../../services/bulk_sync_coordinator.dart';
import '../../services/user_audio_storage_service.dart';
import '../../services/vistoria_chat_session_service.dart';
import '../../shared/widgets/ellipsis_text.dart';
import '../camera/camera_page.dart';
import 'bulk_upload_sheet.dart';
import 'eye_processing_animation.dart';

enum ChatMessageType { ai, user, photo, audio }

enum ContinueVistoriaAction { continueNow, continueLater, startNew }

/// Modo de coleta escolhido pelo mecânico ao abrir uma vistoria nova:
/// `guiado` é o fluxo passo a passo de sempre (inalterado); `emMassa` pula a
/// conversa turno-a-turno e deixa o mecânico montar um pacote (fotos, áudio,
/// texto, orçamento) pra enviar de uma vez só.
enum ColetaModo { guiado, emMassa }

class ChatMessage {
  final ChatMessageType type;
  final String text;
  final String? imagePath;
  final String? audioPath;
  final List<int> boldLineIndexes;
  final int? durationSeconds;

  /// ID do registro criado em users/{uid}/audios/{audioId}.
  final String? audioId;

  /// Caminho original enviado para o Storage.
  final String? originalStoragePath;

  /// Caminho do MP3 gerado/enviado para o Storage.
  final String? mp3StoragePath;

  /// URL pública/autenticada do MP3, usada para reproduzir depois que o app reabrir.
  final String? mp3DownloadUrl;

  /// Status visual do áudio no app:
  /// local, uploading, processing, transcribing, done ou error.
  final String? audioStatus;

  /// Horário em que a mensagem foi criada/exibida no chat.
  final DateTime? createdAt;

  /// true só na mensagem da pergunta bifurcada (guiado vs. em massa) --
  /// renderiza os dois botões inline na bolha em vez de um dialog por cima
  /// do chat.
  final bool isColetaModoPrompt;

  /// Preenchido só depois que o mecânico toca numa das opções da pergunta
  /// bifurcada -- registra qual foi escolhida na própria bolha (ver
  /// _handleColetaModoChosen), em vez dos botões simplesmente sumirem sem
  /// deixar rastro nenhum de qual resposta foi dada.
  final ColetaModo? selectedColetaModo;

  const ChatMessage({
    required this.type,
    required this.text,
    this.imagePath,
    this.audioPath,
    this.boldLineIndexes = const [],
    this.durationSeconds,
    this.audioId,
    this.originalStoragePath,
    this.mp3StoragePath,
    this.mp3DownloadUrl,
    this.audioStatus,
    this.createdAt,
    this.isColetaModoPrompt = false,
    this.selectedColetaModo,
  });

  ChatMessage copyWith({String? text, ColetaModo? selectedColetaModo}) {
    return ChatMessage(
      type: type,
      text: text ?? this.text,
      imagePath: imagePath,
      audioPath: audioPath,
      boldLineIndexes: boldLineIndexes,
      durationSeconds: durationSeconds,
      audioId: audioId,
      originalStoragePath: originalStoragePath,
      mp3StoragePath: mp3StoragePath,
      mp3DownloadUrl: mp3DownloadUrl,
      audioStatus: audioStatus,
      createdAt: createdAt,
      isColetaModoPrompt: isColetaModoPrompt,
      selectedColetaModo: selectedColetaModo ?? this.selectedColetaModo,
    );
  }
}

class AiChatPage extends StatefulWidget {
  /// ID do sinistro atual.
  ///
  /// Quando o chat for aberto a partir da tela de vistorias, passe este valor
  /// para vincular mensagens, fotos e áudios ao sinistro correto.
  final String? sinistroId;

  /// Quando true, ao abrir esta página ela não tenta retomar/criar uma
  /// vistoria normal — ela busca a vistoria REJEITADA do sinistro e inicia
  /// uma retificação a partir dela (ver
  /// VistoriaChatSessionService.startRetificacaoFromSinistro). Usado pelo
  /// botão "Iniciar Retificação" na tela de resumo.
  final bool startRetificacao;

  /// Índice da aba selecionada no MainShell (ver `_selectedIndexNotifier`).
  /// Escutado só pra recarregar a lista de veículos com check-in disponível
  /// sempre que o usuário reabre esta aba -- sem isso, a lista só era
  /// buscada uma vez no initState e ficava desatualizada quando o check-in
  /// acontecia depois, na aba de Vistorias (o IndexedStack do MainShell
  /// mantém esta página montada o tempo todo, initState não roda de novo).
  final ValueListenable<int>? selectedTabIndexListenable;

  const AiChatPage({
    super.key,
    this.sinistroId,
    this.startRetificacao = false,
    this.selectedTabIndexListenable,
  });

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final AudioRecorder audioRecorder = AudioRecorder();

  final List<ChatMessage> messages = [];

  VistoriaSession? currentSession;
  StreamSubscription<VistoriaChatCompletionState>?
      vistoriaCompletionSubscription;

  /// Escuta `BulkSyncCoordinator.onPackageSubmitted` -- único jeito
  /// confiável de saber que o pacote em massa desta vistoria terminou de
  /// enviar, já que `watchCompletionState` não serve pro modo em massa
  /// (exige `laudo_analitico`, que só o agente guiado preenche). Dispara
  /// tanto quando o próprio toque em "Enviar" termina quanto quando a
  /// varredura automática em segundo plano (sem esta tela nem montada)
  /// processa esta mesma vistoria primeiro.
  StreamSubscription<String>? _bulkSubmittedSubscription;

  List<SinistroVistoriaOption> availableSinistros = [];
  bool isLoadingSession = true;

  /// Trava de reentrância pra `_bootstrapChatSession` -- ver comentário no
  /// início do método.
  bool _isBootstrapping = false;
  bool isInspectionCompleted = false;
  String completedInspectionStatus = '';

  bool hasText = false;
  bool isRecording = false;
  bool isStartingRecording = false;
  bool isAiTyping = false;

  /// null enquanto o mecânico não escolheu (ou a sessão foi retomada, onde a
  /// escolha já não se aplica mais). Só `emMassa` habilita o botão de envio
  /// em massa no composer.
  ColetaModo? coletaModo;
  bool awaitingColetaModoChoice = false;
  bool isBulkProcessing = false;

  /// true quando, offline, a vistoria em aberto pro sinistro começou pelo
  /// chat guiado (ou ainda não tinha `coletaModo` definido) -- guiado
  /// depende do agente (ADK), que precisa de internet, então não dá pra
  /// prosseguir de jeito nenhum aqui enquanto sem conexão. Esconde o
  /// composer inteiro (ver `_buildComposerArea`), só mostra o aviso.
  bool isBlockedOfflineGuidedHistory = false;

  /// true enquanto abandona a vistoria guiada e cria a nova em massa
  /// offline -- mostra uma tela dedicada de "convertendo" em vez do
  /// "Preparando sessão..." genérico (que parecia travado sem explicação
  /// nenhuma quando essa escrita demorava mais que o normal).
  bool isConvertingToOfflineBulk = false;

  /// true depois que o mecânico toca "Enviar" no modo em massa estando
  /// offline -- o pacote já está seguro (rascunho persistido), só falta a
  /// internet voltar. Troca o botão de envio por um aviso travado (ver
  /// `_buildComposerArea`) pra não deixar reabrir/editar o pacote por
  /// engano enquanto ele já foi "confirmado". Sai sozinho assim que
  /// `_handleConnectivityRestored` retoma o envio de verdade.
  bool isAwaitingBulkSync = false;
  final ValueNotifier<String> bulkStatusText = ValueNotifier<String>(
    'Processando...',
  );

  // Câmera começa travada — só libera quando o agente diz a frase exata de
  // liberação da leva de danos externos (_isPhotoReleaseText). Uma vez
  // liberada, fica liberada pelo resto da sessão (não existe sinal de
  // "re-travar" pras levas seguintes). cameraPulsing acende só no momento
  // em que acabou de liberar, e apaga assim que a câmera for aberta pela
  // primeira vez (botão fixo ou ação dentro da própria bolha).
  bool cameraUnlocked = false;
  bool cameraPulsing = false;

  Timer? recordingTimer;
  int recordingSeconds = 0;
  String? currentRecordingPath;

  @override
  void initState() {
    super.initState();

    messageController.addListener(() {
      final currentHasText = messageController.text.trim().isNotEmpty;

      if (currentHasText != hasText) {
        setState(() {
          hasText = currentHasText;
        });
      }
    });

    widget.selectedTabIndexListenable?.addListener(_onSelectedTabIndexChanged);

    // O envio de verdade (upload + finalização) é feito pelo
    // BulkSyncCoordinator, que já se retoma sozinho ao reconectar
    // independente desta tela estar montada -- aqui só precisamos saber
    // QUANDO isso termina, pra virar a UI pra "concluído" se for esta
    // mesma vistoria.
    _bulkSubmittedSubscription =
        BulkSyncCoordinator.instance.onPackageSubmitted.listen(
      _handleBulkPackageSubmitted,
    );

    // Vistoria guiada bloqueada offline -- assim que a conexão volta, isso
    // ainda precisa de um retry local (refazer o bootstrap pra cair no
    // ramo online de verdade), diferente do envio em massa.
    ArgosConnectivityService.instance.isOnline.addListener(
      _handleConnectivityRestored,
    );

    // Adiado pro pós-frame -- `_bootstrapChatSession` pode abrir um
    // `showDialog` (aviso offline), que precisa de um `context` com as
    // dependências (Theme/Localizations) já resolvidas. Chamado direto
    // aqui, ainda dentro do `initState`, estourava "dependOnInherited...
    // called before initState() completed" (bug real, achado testando no
    // aparelho). `isLoadingSession` já nasce `true`, então não muda nada
    // visualmente adiar por um frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bootstrapChatSession();
    });
  }

  @override
  void dispose() {
    widget.selectedTabIndexListenable
        ?.removeListener(_onSelectedTabIndexChanged);
    ArgosConnectivityService.instance.isOnline.removeListener(
      _handleConnectivityRestored,
    );
    _bulkSubmittedSubscription?.cancel();

    bulkStatusText.dispose();
    vistoriaCompletionSubscription?.cancel();
    recordingTimer?.cancel();

    if (isRecording) {
      audioRecorder.stop();
    }

    audioRecorder.dispose();
    messageController.dispose();
    scrollController.dispose();

    super.dispose();
  }

  static const int _kChatTabIndex = 1;

  // Só recarrega quando: esta aba acabou de ficar visível, é a tela de
  // escolha de veículo (sem sinistroId fixo) e não tem sessão/carregamento
  // em andamento -- nunca interrompe uma conversa já aberta.
  void _onSelectedTabIndexChanged() {
    if (!mounted) return;
    if (widget.selectedTabIndexListenable?.value != _kChatTabIndex) return;
    if (widget.sinistroId != null) return;
    if (isLoadingSession || currentSession != null) return;

    _loadAvailableSinistros();
  }

  void _showSnack(
    String message, {
    Color backgroundColor = const Color(0xFF0057C0),
  }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!scrollController.hasClients) return;

      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  String _normalizeMessage(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _isPhotoReleaseText(String value) {
    final normalized = _normalizeMessage(value);

    return normalized.contains('identificação recebida') &&
        normalized.contains('liberei') &&
        normalized.contains('fotos dos danos externos');
  }

  ChatMessage _aiMessageFromText(String text, {DateTime? createdAt}) {
    final boldLineIndexes = <int>[];
    final cleanLines = text.split('\n').asMap().entries.map((entry) {
      final line = entry.value;

      if (line.contains('*')) {
        boldLineIndexes.add(entry.key);
      }

      return line.replaceAll('*', '');
    }).toList();

    return ChatMessage(
      type: ChatMessageType.ai,
      text: cleanLines.join('\n').trim(),
      boldLineIndexes: boldLineIndexes,
      createdAt: createdAt,
    );
  }

  // Não abre mais a câmera sozinha — só destrava o botão (fixo na barra de
  // composição) e acende o pulso, deixando o mecânico decidir quando tocar.
  void _openCameraAfterPhotoRelease(String text) {
    if (cameraUnlocked) return;
    if (!_isPhotoReleaseText(text)) return;

    setState(() {
      cameraUnlocked = true;
      cameraPulsing = true;
    });
  }

  void _listenToVistoriaCompletion(VistoriaSession session) {
    vistoriaCompletionSubscription?.cancel();
    vistoriaCompletionSubscription = VistoriaChatSessionService.instance
        .watchCompletionState(vistoriaDocId: session.docId)
        .listen(
      (completionState) {
        if (!completionState.isCompleted || isInspectionCompleted) return;

        _completeChatFromVistoriaUpdate(completionState.status);
      },
      onError: (error) {
        debugPrint('Erro ao escutar conclusão da vistoria: $error');
      },
    );
  }

  Future<void> _completeChatFromVistoriaUpdate(String status) async {
    vistoriaCompletionSubscription?.cancel();
    vistoriaCompletionSubscription = null;

    if (isRecording) {
      await _cancelRecording();
    }

    if (!mounted) return;

    FocusScope.of(context).unfocus();

    setState(() {
      isInspectionCompleted = true;
      completedInspectionStatus = status;
      isAiTyping = false;
      isStartingRecording = false;
      hasText = false;
      messageController.clear();
    });
  }

  Future<void> _bootstrapChatSession() async {
    // Reentrância: `_handleConnectivityRestored` pode chamar isto de novo
    // (retry do bloqueio guiado) -- se a conexão "piscar" (confirma true,
    // cai, confirma true de novo) rápido o bastante, duas execuções
    // concorrentes tentando mostrar diálogo/mexer no mesmo estado ao
    // mesmo tempo é exatamente o tipo de corrida que pode deixar a tela
    // presa em "Carregando sessão..." pra sempre. Só a execução em
    // andamento tem permissão de mexer em `isLoadingSession`/diálogos.
    if (_isBootstrapping) return;
    _isBootstrapping = true;

    setState(() {
      isLoadingSession = true;
    });

    try {
      // Nada de aviso genérico aqui antes de saber o que o mecânico quer
      // fazer -- chegou a existir um diálogo bloqueando a ENTRADA inteira
      // da aba offline (mesmo sem nenhuma vistoria escolhida ainda), mas
      // isso era pura fricção: a lista abaixo (`_loadAvailableSinistros`)
      // já funciona 100% do cache sem precisar de decisão nenhuma, e quem
      // sabe de verdade o que fazer com uma vistoria específica offline é
      // `_startVistoriaOffline` (bloqueia/retoma/cria conforme o histórico
      // de CADA sinistro, com a mensagem certa pra cada caso) -- chamado
      // logo abaixo, dentro de `_startVistoriaFromSinistro`, só quando o
      // mecânico de fato escolheu um veículo.
      final directSinistroId = widget.sinistroId?.trim();

      if (directSinistroId != null && directSinistroId.isNotEmpty) {
        await _startVistoriaFromSinistro(
          directSinistroId,
          fromDirectSinistro: true,
        );
        return;
      }

      await _loadAvailableSinistros();
    } catch (e) {
      debugPrint('Erro ao iniciar sessão de vistoria: $e');

      if (!mounted) return;

      setState(() {
        isLoadingSession = false;
        messages
          ..clear()
          ..add(
            ChatMessage(
              type: ChatMessageType.ai,
              text:
                  'Não consegui preparar a sessão da vistoria. Detalhe: $e',
            ),
          );
      });
    } finally {
      _isBootstrapping = false;
    }
  }

  Future<void> _loadAvailableSinistros({String? message}) async {
    await vistoriaCompletionSubscription?.cancel();
    vistoriaCompletionSubscription = null;

    final options = await VistoriaChatSessionService.instance
        .listCheckedInSinistrosForCurrentUser();

    if (!mounted) return;

    setState(() {
      currentSession = null;
      availableSinistros = options;
      isLoadingSession = false;
      isInspectionCompleted = false;
      completedInspectionStatus = '';
      isAwaitingBulkSync = false;
      isBlockedOfflineGuidedHistory = false;
      isAiTyping = false;
      messages
        ..clear()
        ..add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: message ??
                'Selecione uma placa com check-in realizado para iniciar ou continuar a vistoria.',
          ),
        );
    });
  }

  /// Pergunta bifurcada mostrada só uma vez, ao abrir uma vistoria nova de
  /// verdade (nunca em retomada nem em retificação, que já saem antes deste
  /// ponto em `_startVistoriaFromSinistro`/`_startRetificacaoFromSinistro`).
  /// Vem como mensagem do próprio bot no chat (botões inline na bolha, ver
  /// `_AiBubble`), não um dialog por cima -- e esconde o composer normal
  /// enquanto a escolha não é feita (`awaitingColetaModoChoice`).
  void _offerColetaModoChoice() {
    if (currentSession == null) return;

    setState(() {
      awaitingColetaModoChoice = true;
      messages.add(
        ChatMessage(
          type: ChatMessageType.ai,
          text: 'Como você quer coletar essa vistoria?',
          createdAt: DateTime.now(),
          isColetaModoPrompt: true,
        ),
      );
    });

    _scrollToBottom();
  }

  Future<void> _handleColetaModoChosen(ColetaModo escolha) async {
    final session = currentSession;

    if (session == null || !awaitingColetaModoChoice) return;

    setState(() {
      coletaModo = escolha;
      awaitingColetaModoChoice = false;

      // Registra a escolha na própria bolha da pergunta -- sem isso os
      // botões só somem (onChooseColetaModo vira null pro resto da tela
      // assim que awaitingColetaModoChoice fica false) sem deixar
      // nenhum rastro visível de qual opção foi tocada (bug real,
      // reportado pelo usuário).
      final promptIndex = messages.lastIndexWhere(
        (m) => m.isColetaModoPrompt && m.selectedColetaModo == null,
      );

      if (promptIndex != -1) {
        messages[promptIndex] = messages[promptIndex].copyWith(
          selectedColetaModo: escolha,
        );
      }
    });

    unawaited(
      VistoriaChatSessionService.instance.setColetaModo(
        vistoriaDocId: session.docId,
        coletaModo: escolha == ColetaModo.emMassa ? 'em_massa' : 'guiado',
      ),
    );

    if (escolha == ColetaModo.emMassa) {
      setState(() {
        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text:
                'Beleza! Toque no botão "Montar envio em massa" aqui embaixo '
                'pra juntar fotos, áudio, observações e orçamento e mandar '
                'tudo de uma vez.',
            createdAt: DateTime.now(),
          ),
        );
      });

      _scrollToBottom();
      return;
    }

    await _sendInitialOiToAgent();
  }

  /// Só pra vistorias em modo em massa ainda não enviadas -- oferece
  /// continuar montando o pacote ou trocar pro chat guiado, em vez do
  /// diálogo "continuar agora/mais tarde/nova" (que pressupõe um papo em
  /// andamento, e aqui não tem nenhum).
  Future<ColetaModo?> _askResumeBulkMode(VistoriaSession session) {
    final placa = session.placa.trim().isEmpty ? 'Sem placa' : session.placa;

    return showDialog<ColetaModo>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE5F6FF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.upload_file_rounded,
                      color: Color(0xFF0057C0),
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Envio em massa em andamento',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Você tinha começado a montar um pacote pra $placa e ainda '
                  'não enviou. O que você quer fazer?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 20),
                _VistoriaActionTile(
                  icon: Icons.upload_file_rounded,
                  title: 'Continuar envio em massa',
                  subtitle: 'Volta pro botão de montar o pacote.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () =>
                      Navigator.of(dialogContext).pop(ColetaModo.emMassa),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.chat_bubble_rounded,
                  title: 'Mudar para o chat guiado',
                  subtitle: 'Descarta o pacote e conversa comigo passo a passo.',
                  color: const Color(0xFF0057C0),
                  onTap: () =>
                      Navigator.of(dialogContext).pop(ColetaModo.guiado),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<ContinueVistoriaAction?> _askVistoriaAction(
    VistoriaSession session,
  ) {
    final placa = session.placa.trim().isEmpty ? 'Sem placa' : session.placa;
    final veiculo =
        session.veiculo.trim().isEmpty ? 'Não informado' : session.veiculo;

    return showDialog<ContinueVistoriaAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE5F6FF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.pending_actions_rounded,
                      color: Color(0xFF0057C0),
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Vistoria em andamento',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Você já começou a vistoria deste veículo e ainda não terminou.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3FBFF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _VistoriaInfoRow(
                        icon: Icons.badge_outlined,
                        label: 'Vistoria',
                        value: session.idvistoria,
                      ),
                      const SizedBox(height: 8),
                      _VistoriaInfoRow(
                        icon: Icons.directions_car_outlined,
                        label: 'Veículo',
                        value: '$placa • $veiculo',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Padding(
                  padding: EdgeInsets.only(bottom: 10, left: 2),
                  child: Text(
                    'O que você quer fazer?',
                    style: TextStyle(
                      color: Color(0xFF1F2937),
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                _VistoriaActionTile(
                  icon: Icons.play_circle_fill_rounded,
                  title: 'Continuar agora',
                  subtitle: 'Volta pro ponto exato onde você parou.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.continueNow),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.schedule_rounded,
                  title: 'Continuar mais tarde',
                  subtitle: 'Fecha por agora — o progresso fica salvo.',
                  color: const Color(0xFF0057C0),
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.continueLater),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.restart_alt_rounded,
                  title: 'Começar nova',
                  subtitle: 'Descarta o progresso atual e recomeça do zero.',
                  color: Colors.deepOrange,
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.startNew),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Mostrado no lugar de _askVistoriaAction quando a checagem em tempo
  /// real (checkVistoriaExpiration) já confirmou que a sessão passou das 24h
  /// úteis — não faz sentido oferecer "Continuar agora" pra uma vistoria que
  /// acabou de ser marcada EXPIRADA no backend.
  Future<ContinueVistoriaAction?> _showVistoriaExpiredDialog(
    VistoriaSession session,
  ) {
    final placa = session.placa.trim().isEmpty ? 'Sem placa' : session.placa;
    final veiculo =
        session.veiculo.trim().isEmpty ? 'Não informado' : session.veiculo;

    return showDialog<ContinueVistoriaAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFF0E5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.timer_off_rounded,
                      color: Colors.deepOrange,
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Vistoria expirada',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Essa vistoria ficou mais de 24h úteis sem atividade e '
                  'não pode mais ser continuada de onde parou.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3FBFF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _VistoriaInfoRow(
                        icon: Icons.badge_outlined,
                        label: 'Vistoria',
                        value: session.idvistoria,
                      ),
                      const SizedBox(height: 8),
                      _VistoriaInfoRow(
                        icon: Icons.directions_car_outlined,
                        label: 'Veículo',
                        value: '$placa • $veiculo',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _VistoriaActionTile(
                  icon: Icons.restart_alt_rounded,
                  title: 'Começar novo chat',
                  subtitle: 'Inicia uma vistoria nova para este veículo.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.startNew),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.schedule_rounded,
                  title: 'Continuar mais tarde',
                  subtitle: 'Volta pra tela de vistorias por agora.',
                  color: const Color(0xFF0057C0),
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.continueLater),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmStartNewVistoria(VistoriaSession session) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('Começar uma nova coleta?'),
          content: Text(
            'A vistoria ${session.idvistoria} será marcada como abandonada -- '
            'isso não cancela o sinistro nem anula nada (só o analista no web '
            'pode fazer isso). O histórico não é apagado, e uma nova coleta '
            'começa agora pra este veículo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white,
              ),
              child: const Text('Abandonar e iniciar nova'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _startVistoriaFromSinistro(
    String sinistroId, {
    bool fromDirectSinistro = false,
  }) async {
    if (widget.startRetificacao) {
      await _startRetificacaoFromSinistro(sinistroId);
      return;
    }

    setState(() {
      isLoadingSession = true;
    });

    try {
      final openSession = await VistoriaChatSessionService.instance
          .findOpenVistoria(sinistroId: sinistroId);

      if (!mounted) return;

      // findOpenVistoria já é 100% offline-safe (query no cache local +
      // expiração calculada localmente, auto-expira via escrita simples,
      // não transação) -- diferente do resto deste método, que depende de
      // checkVistoriaExpiration (Cloud Function) e createOrResumeFromSinistro
      // (transação pro número sequencial), nenhum dos dois funciona sem
      // rede. Por isso o ramo offline é tratado à parte, sem reusar esses
      // dois.
      if (!ArgosConnectivityService.instance.isOnline.value) {
        await _startVistoriaOffline(sinistroId, openSession);
        return;
      }

      if (openSession != null) {
        setState(() {
          isLoadingSession = false;
        });

        // Checa em tempo real em vez de confiar só na varredura agendada
        // (agora de 12 em 12h) — sem isso o mecânico podia cair numa sessão
        // que já devia estar expirada só porque o job ainda não tinha
        // passado por ela.
        final alreadyExpired = await ArgosAiService.instance
            .checkVistoriaExpiration(idvistoria: openSession.docId);

        if (!mounted) return;

        // Modo em massa não tem conversa pra "continuar agora"/"mais tarde"
        // -- esse diálogo existe pra retomar um PAPO em andamento, e no modo
        // em massa não existe papo nenhum, só um pacote que ainda não foi
        // enviado. Em vez disso, pergunta só o que faz sentido aqui:
        // continuar montando o pacote ou trocar pro chat guiado.
        if (!alreadyExpired && openSession.isEmMassa) {
          final resumeChoice = await _askResumeBulkMode(openSession);

          if (!mounted) return;

          if (resumeChoice == ColetaModo.guiado) {
            unawaited(
              VistoriaChatSessionService.instance.setColetaModo(
                vistoriaDocId: openSession.docId,
                coletaModo: 'guiado',
              ),
            );

            setState(() {
              coletaModo = ColetaModo.guiado;
              _loadSessionIntoChat(openSession);
              isLoadingSession = false;
            });

            _scrollToBottom();
            await _sendInitialOiToAgent();
            return;
          }

          setState(() {
            coletaModo = ColetaModo.emMassa;
            _loadSessionIntoChat(openSession);
            isLoadingSession = false;
          });

          _scrollToBottom();
          return;
        }

        // Nunca respondeu "Como você quer coletar essa vistoria?" -- não
        // existe papo nenhum pra "continuar agora"/"mais tarde", só a
        // pergunta pendente (o mecânico saiu do app antes de tocar num dos
        // botões). Sem este caso, "continuar agora" carregava um chat
        // vazio sem nenhum jeito de responder de novo -- a única saída era
        // abandonar a vistoria pra gerar outra do zero (bug real,
        // reportado pelo usuário). Reoferece a pergunta direto, igual
        // acontece na criação.
        if (!alreadyExpired &&
            !openSession.isEmMassa &&
            openSession.coletaModo.trim().isEmpty) {
          setState(() {
            _loadSessionIntoChat(openSession);
            isLoadingSession = false;
          });

          _scrollToBottom();
          _offerColetaModoChoice();
          return;
        }

        final action = alreadyExpired
            ? await _showVistoriaExpiredDialog(openSession)
            : await _askVistoriaAction(openSession);

        if (!mounted) return;

        if (!alreadyExpired && action == ContinueVistoriaAction.continueNow) {
          setState(() {
            _loadSessionIntoChat(openSession);
            isLoadingSession = false;
          });

          _scrollToBottom();
          return;
        }

        if (action == ContinueVistoriaAction.continueLater || action == null) {
          await _handleContinueLater(fromDirectSinistro: fromDirectSinistro);
          return;
        }

        if (action == ContinueVistoriaAction.startNew) {
          if (alreadyExpired) {
            // Já foi marcada EXPIRADA pela checagem acima — não há nada pra
            // confirmar nem descartar, só seguir e criar a próxima.
            setState(() {
              isLoadingSession = true;
            });
          } else {
            final confirmed = await _confirmStartNewVistoria(openSession);

            if (!mounted) return;

            if (!confirmed) {
              await _handleContinueLater(fromDirectSinistro: fromDirectSinistro);
              return;
            }

            setState(() {
              isLoadingSession = true;
            });

            await VistoriaChatSessionService.instance.abandonVistoria(
              vistoriaDocId: openSession.docId,
            );
          }
        }
      }

      final session = await VistoriaChatSessionService.instance
          .createOrResumeFromSinistro(sinistroId: sinistroId);

      if (!mounted) return;

      setState(() {
        _loadSessionIntoChat(session);
        isLoadingSession = false;
      });

      _scrollToBottom();

      final shouldSendInitialOi = session.chatMessages.any(
        (message) => message['backgroundStart'] == true,
      );

      final hasAiReply = session.chatMessages.any(
        (message) => message['role'] == 'ai',
      );

      if (shouldSendInitialOi && !hasAiReply) {
        _offerColetaModoChoice();
      }
    } catch (e) {
      debugPrint('Erro ao criar vistoria pelo sinistro: $e');

      if (!mounted) return;

      setState(() {
        isLoadingSession = false;
        messages
          ..clear()
          ..add(
            ChatMessage(
              type: ChatMessageType.ai,
              text:
                  'Não foi possível iniciar a vistoria. Verifique se o veículo possui check-in. Detalhe: $e',
            ),
          );
      });
    }
  }

  /// Ramo offline de `_startVistoriaFromSinistro`. `openSession` já veio de
  /// `findOpenVistoria` (100% local, já descartou sessões expiradas) --
  /// aqui só decide com base na regra de negócio: guiado precisa do agente
  /// (ADK), que não funciona sem internet, então:
  /// - sem histórico nenhum (ou já era em massa) -> pode elaborar offline;
  /// - histórico de chat guiado em aberto -> bloqueia, sem entrar no
  ///   composer.
  Future<void> _startVistoriaOffline(
    String sinistroId,
    VistoriaSession? openSession,
  ) async {
    if (openSession != null && !openSession.isEmMassa) {
      final wantsAbandon =
          await _askAbandonGuidedAndStartOfflineBulk(openSession);

      if (!mounted) return;

      if (wantsAbandon) {
        // Fica NA MESMA TELA mostrando um estado de "convertendo" --
        // precisa de currentSession != null pro build() não voltar pra
        // lista de seleção (que é como o erro ficava "escondido" antes).
        // Essa escrita específica já provou (testando no aparelho) que
        // pode demorar bem mais que o normal, por isso o timeout generoso
        // lá no serviço -- aqui só esperamos honestamente, mostrando que
        // algo está acontecendo, em vez do "Preparando sessão..." genérico
        // que parecia travado sem explicação.
        setState(() {
          isLoadingSession = false;
          isConvertingToOfflineBulk = true;
          currentSession = openSession;
        });

        try {
          // Cria a vistoria NOVA primeiro -- o serviço já resolve rápido
          // offline (não espera mais o Future de rede, só aplica local e
          // segue -- ver `VistoriaChatSessionService._writeNoWaitOffline`).
          // O abandono da antiga vira fire-and-forget logo abaixo: a nova
          // já é a mais recente (`updatedAt`), então `findOpenVistoria` já
          // prefere ela mesmo que o abandono ainda não tenha "chegado".
          //
          // Isso ficou rápido demais pro mecânico ler a mensagem da tela
          // de "Convertendo vistoria" -- garante um tempo mínimo visível
          // nela, mesmo que o trabalho de verdade já tenha terminado.
          final session = await Future.wait([
            VistoriaChatSessionService.instance.createVistoriaOffline(
              sinistroId: sinistroId,
            ),
            Future<void>.delayed(const Duration(seconds: 15)),
          ]).then((results) => results.first as VistoriaSession);

          if (!mounted) return;

          setState(() {
            isConvertingToOfflineBulk = false;
            coletaModo = ColetaModo.emMassa;
            _loadSessionIntoChat(session);
            isLoadingSession = false;
          });

          _scrollToBottom();

          unawaited(
            VistoriaChatSessionService.instance
                .abandonVistoria(vistoriaDocId: openSession.docId)
                .catchError((e) {
              debugPrint('Abandonar vistoria antiga em segundo plano falhou: $e');
            }),
          );

          return;
        } catch (e) {
          debugPrint('Abandonar+criar offline falhou: $e');

          if (!mounted) return;

          setState(() => isConvertingToOfflineBulk = false);

          _showSnack(
            'Isso está demorando mais que o esperado. Tente de novo em '
            'alguns segundos.',
            backgroundColor: Colors.orange,
          );
        }
      }

      setState(() {
        // Precisa setar currentSession -- o build() decide entre a tela de
        // seleção de veículo e o chat com base só em `currentSession ==
        // null`. Sem isso, o aviso de bloqueio nunca chegava a aparecer: a
        // tela ficava presa na lista de seleção, parecendo que "não
        // acontecia nada" ao tocar no veículo (bug real, achado testando
        // no aparelho).
        currentSession = openSession;
        isLoadingSession = false;
        isBlockedOfflineGuidedHistory = true;
        messages
          ..clear()
          ..add(
            ChatMessage(
              type: ChatMessageType.ai,
              text: 'Esta vistoria foi iniciada pelo chat guiado, que '
                  'depende de internet pra funcionar. Conecte-se para '
                  'continuar de onde parou.',
            ),
          );
      });

      return;
    }

    setState(() => isBlockedOfflineGuidedHistory = false);

    if (openSession != null) {
      // Já em massa -- retoma direto, sem o diálogo de "mudar pra guiado"
      // (opção que não existe offline). Se o pacote já tinha sido
      // confirmado ("Enviar" tocado) antes de sair da tela, volta direto
      // pro estado travado de "aguardando sincronização" -- não deixa
      // reabrir o botão de montar um pacote que já foi confirmado.
      setState(() {
        coletaModo = ColetaModo.emMassa;
        _loadSessionIntoChat(openSession);
        isAwaitingBulkSync = openSession.envioEmMassaConfirmadoOffline;
        isLoadingSession = false;
      });

      _scrollToBottom();
      return;
    }

    // Sem histórico nenhum pro sinistro -- cria do zero.
    await _createFreshOfflineVistoria(sinistroId);
  }

  /// Variante offline de `_confirmStartNewVistoria` -- guiado é inviável
  /// sem conexão, então em vez de só bloquear, oferece abandonar a
  /// vistoria guiada em aberto e começar uma nova pelo envio em massa (o
  /// único modo que funciona offline). Mesmo efeito de dados que o botão
  /// "Começar nova" online -- `abandonVistoria` nunca cancela/anula o
  /// sinistro, só o analista no web pode fazer isso.
  Future<bool> _askAbandonGuidedAndStartOfflineBulk(
    VistoriaSession session,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFF7E6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.wifi_off_rounded,
                      color: Color(0xFFB45309),
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Vistoria guiada — sem rede',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'O chat guiado precisa de internet. Offline, só dá pra '
                  'continuar pelo envio em massa.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 20),
                _VistoriaActionTile(
                  icon: Icons.upload_file_rounded,
                  title: 'Abandonar e usar envio em massa',
                  subtitle: 'Começa agora. Não cancela o sinistro.',
                  color: Colors.deepOrange,
                  filled: true,
                  onTap: () => Navigator.of(dialogContext).pop(true),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.schedule_rounded,
                  title: 'Esperar conexão',
                  subtitle: 'Continua o chat guiado quando a rede voltar.',
                  color: const Color(0xFF6B7280),
                  onTap: () => Navigator.of(dialogContext).pop(false),
                ),
              ],
            ),
          ),
        );
      },
    );

    return result ?? false;
  }

  /// Cria uma vistoria do zero offline (ID provisório, direto em modo em
  /// massa) e carrega na tela -- compartilhado entre "sinistro sem
  /// histórico nenhum" e "abandonou a vistoria guiada e quer começar de
  /// novo". Bifurcação não faz sentido aqui: guiado é inviável sem conexão.
  Future<void> _createFreshOfflineVistoria(String sinistroId) async {
    final session = await VistoriaChatSessionService.instance
        .createVistoriaOffline(sinistroId: sinistroId);

    if (!mounted) return;

    setState(() {
      coletaModo = ColetaModo.emMassa;
      _loadSessionIntoChat(session);
      isLoadingSession = false;
    });

    _scrollToBottom();
  }

  /// Caminho separado de propósito de _startVistoriaFromSinistro — não passa
  /// por findOpenVistoria (a vistoria rejeitada não está EM_ANDAMENTO, nunca
  /// seria achada) nem pelo diálogo de continuar/começar de novo. Sempre
  /// cria a vistoria de retificação a partir da rejeitada.
  Future<void> _startRetificacaoFromSinistro(String sinistroId) async {
    setState(() {
      isLoadingSession = true;
    });

    try {
      // Antes disto o botão criava uma retificação nova toda vez que era
      // tocado — mesmo que já existisse uma em andamento — sem nunca
      // perguntar nada pro mecânico. findOpenVistoria acha qualquer vistoria
      // EM_ANDAMENTO do sinistro (original ou retificação), então serve
      // igual ao fluxo normal pra decidir se continua, adia ou descarta.
      final openSession = await VistoriaChatSessionService.instance
          .findOpenVistoria(sinistroId: sinistroId);

      if (!mounted) return;

      if (openSession != null) {
        setState(() {
          isLoadingSession = false;
        });

        final alreadyExpired = await ArgosAiService.instance
            .checkVistoriaExpiration(idvistoria: openSession.docId);

        if (!mounted) return;

        final action = alreadyExpired
            ? await _showVistoriaExpiredDialog(openSession)
            : await _askVistoriaAction(openSession);

        if (!mounted) return;

        if (!alreadyExpired && action == ContinueVistoriaAction.continueNow) {
          setState(() {
            _loadSessionIntoChat(openSession);
            isLoadingSession = false;
          });

          _scrollToBottom();
          return;
        }

        if (action == ContinueVistoriaAction.continueLater || action == null) {
          await _handleContinueLater(fromDirectSinistro: true);
          return;
        }

        if (action == ContinueVistoriaAction.startNew) {
          if (!alreadyExpired) {
            final confirmed = await _confirmStartNewVistoria(openSession);

            if (!mounted) return;

            if (!confirmed) {
              await _handleContinueLater(fromDirectSinistro: true);
              return;
            }

            setState(() {
              isLoadingSession = true;
            });

            await VistoriaChatSessionService.instance.abandonVistoria(
              vistoriaDocId: openSession.docId,
            );
          } else {
            setState(() {
              isLoadingSession = true;
            });
          }

          await _createRetificacaoAfterDiscard(
            sinistroId: sinistroId,
            discardedOrigemId: openSession.vistoriaOrigemId,
          );
          return;
        }
      }

      await _createRetificacaoAfterDiscard(sinistroId: sinistroId);
    } catch (e) {
      debugPrint('Erro ao iniciar retificação pelo sinistro: $e');

      if (!mounted) return;

      setState(() {
        isLoadingSession = false;
        messages
          ..clear()
          ..add(
            ChatMessage(
              type: ChatMessageType.ai,
              text: 'Não foi possível iniciar a retificação. Detalhe: $e',
            ),
          );
      });
    }
  }

  /// Cria a retificação em si. Se `discardedOrigemId` vier preenchido, é
  /// porque acabamos de descartar uma retificação já em andamento — nesse
  /// caso sinistro.vistoriaAtualId aponta pro que acabou de ser descartado,
  /// então busca a vistoria REJEITADA original diretamente por id em vez de
  /// usar startRetificacaoFromSinistro (que leria o ponteiro errado).
  Future<void> _createRetificacaoAfterDiscard({
    required String sinistroId,
    String? discardedOrigemId,
  }) async {
    final service = VistoriaChatSessionService.instance;

    final session = (discardedOrigemId != null && discardedOrigemId.isNotEmpty)
        ? await () async {
            final original = await service.getVistoriaById(discardedOrigemId);
            if (original == null) {
              return service.startRetificacaoFromSinistro(
                sinistroId: sinistroId,
              );
            }
            return service.createRetificacaoFromVistoria(
              original: original,
              ajustesNecessarios: original.ajustesNecessarios,
              contextoVistoriaAnterior: original.contextoVistoriaAnterior,
            );
          }()
        : await service.startRetificacaoFromSinistro(sinistroId: sinistroId);

    if (!mounted) return;

    setState(() {
      _loadSessionIntoChat(session);
      isLoadingSession = false;
    });

    _scrollToBottom();

    final shouldSendInitialOi = session.chatMessages.any(
      (message) => message['backgroundStart'] == true,
    );

    final hasAiReply = session.chatMessages.any(
      (message) => message['role'] == 'ai',
    );

    if (shouldSendInitialOi && !hasAiReply) {
      await _sendInitialOiToAgent();
    }
  }

  Future<void> _handleContinueLater({
    required bool fromDirectSinistro,
  }) async {
    if (fromDirectSinistro) {
      final didPop = await Navigator.of(context).maybePop();

      if (didPop || !mounted) return;
    }

    await _loadAvailableSinistros(
      message:
          'Tudo certo. A vistoria continua salva para mais tarde. Selecione uma placa quando quiser continuar.',
    );
  }

  Future<void> _sendInitialOiToAgent() async {
    final session = currentSession;

    if (session == null || isInspectionCompleted) return;

    setState(() {
      isAiTyping = true;
    });

    try {
      final reply = await ArgosAiService.instance.sendMessage(
        text: 'oi',
        inspectionId: session.idvistoria,
        isRetificacao: session.isRetificacao,
        ajustesNecessarios: session.ajustesNecessarios,
        contextoVistoriaAnterior: session.contextoVistoriaAnterior,
      );

      if (isInspectionCompleted) return;

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: reply,
      );

      if (!mounted) return;

      setState(() {
        isAiTyping = false;
        messages.add(_aiMessageFromText(reply, createdAt: DateTime.now()));
      });

      _openCameraAfterPhotoRelease(reply);
      _scrollToBottom();
    } catch (e) {
      debugPrint('Erro ao enviar oi inicial para IA: $e');

      if (!mounted) return;

      setState(() {
        isAiTyping = false;
      });
    }
  }

  void _loadSessionIntoChat(VistoriaSession session) {
    currentSession = session;
    isInspectionCompleted = false;
    completedInspectionStatus = '';
    // Retificação não repete o roteiro original (identificação → danos
    // externos → estruturais) que emite a frase exata de liberação — o
    // agente já sabe o que existe e pode pedir foto nova a qualquer momento
    // da correção. Travar o botão esperando por uma frase que talvez nunca
    // venha deixaria a câmera bloqueada pro resto da retificação.
    cameraUnlocked = session.isRetificacao;
    cameraPulsing = false;
    _listenToVistoriaCompletion(session);

    // audio_transcription vem do backend como uma entrada separada do
    // chatmessages (role: user, mesmo audioId) — em vez de virar uma bolha
    // de texto solta, anexa na bolha do áudio correspondente, pra dar pra
    // esconder atrás do botão "Transcrever áudio" (estilo WhatsApp).
    final loadedMessages = <ChatMessage>[];

    for (final item in session.chatMessages) {
      if (item['backgroundStart'] == true) continue;

      final type = item['type']?.toString() ?? '';

      if (type == 'audio_transcription') {
        final audioId = item['audioId']?.toString() ?? '';
        final transcript = item['text']?.toString() ?? '';

        if (audioId.isNotEmpty && transcript.isNotEmpty) {
          final index = loadedMessages.lastIndexWhere(
            (m) => m.type == ChatMessageType.audio && m.audioId == audioId,
          );

          if (index >= 0) {
            loadedMessages[index] = loadedMessages[index].copyWith(
              text: transcript,
            );
          }
        }
        continue;
      }

      final message = _chatMessageFromFirestore(item);
      if (message != null) loadedMessages.add(message);
    }

    messages
      ..clear()
      ..addAll(loadedMessages);

    // Retomando uma sessão que já passou desse ponto — destrava sem pulsar
    // (o pulso é só pro momento em que a liberação acabou de acontecer).
    if (messages.any(
      (m) => m.type == ChatMessageType.ai && _isPhotoReleaseText(m.text),
    )) {
      cameraUnlocked = true;
    }

    if (messages.isEmpty) {
      messages.add(
        ChatMessage(
          type: ChatMessageType.ai,
          text:
              'Vistoria ${session.idvistoria} iniciada para ${session.placa.isEmpty ? 'veículo sem placa' : session.placa}. Vamos começar.',
          createdAt: DateTime.now(),
        ),
      );
    }
  }


  DateTime? _dateFromFirestoreValue(dynamic value) {
    if (value == null) return null;

    try {
      final dynamic dynamicValue = value;

      if (dynamicValue is DateTime) return dynamicValue;

      final toDate = dynamicValue.toDate;
      if (toDate is Function) {
        final parsed = toDate.call();
        if (parsed is DateTime) return parsed;
      }
    } catch (_) {}

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }

  ChatMessage? _chatMessageFromFirestore(Map<String, dynamic> data) {
    final role = data['role']?.toString() ?? '';
    final type = data['type']?.toString() ?? '';
    final text = data['text']?.toString() ?? '';
    final imageUrl = data['url']?.toString();
    final createdAt = _dateFromFirestoreValue(data['createdAt']);

    if (text.trim().isEmpty && role != 'audio') return null;

    if (role == 'user') {
      return ChatMessage(
        type: ChatMessageType.user,
        text: text,
        createdAt: createdAt,
      );
    }

    if (role == 'photo') {
      return ChatMessage(
        type: ChatMessageType.photo,
        text: text,
        imagePath: imageUrl,
        createdAt: createdAt,
      );
    }

    if (role == 'audio' || type == 'audio') {
      return ChatMessage(
        type: ChatMessageType.audio,
        text: text,
        audioId: data['audioId']?.toString(),
        originalStoragePath: data['originalStoragePath']?.toString(),
        mp3StoragePath: data['mp3StoragePath']?.toString() ?? data['storagePath']?.toString(),
        mp3DownloadUrl: data['mp3DownloadUrl']?.toString(),
        audioStatus: data['audioStatus']?.toString() ?? 'done',
        createdAt: createdAt,
      );
    }

    return _aiMessageFromText(text, createdAt: createdAt);
  }

  Future<void> _handleSinistroSelected(SinistroVistoriaOption option) async {
    if (option.isRetificacaoPendente) {
      await _startRetificacaoFromSinistro(option.sinistroId);
      return;
    }
    await _startVistoriaFromSinistro(option.sinistroId);
  }

  Future<void> _closeCurrentChatAndBackToSelection() async {
    if (isRecording) {
      await _cancelRecording();
    }

    FocusScope.of(context).unfocus();

    await _loadAvailableSinistros(
      message:
          'Selecione uma placa com check-in realizado para iniciar ou continuar a vistoria.',
    );
  }

  Future<void> _sendTextMessage() async {
    final session = currentSession;
    final text = messageController.text.trim();

    if (text.isEmpty) return;
    if (isInspectionCompleted) return;

    if (session == null) {
      _showSnack(
        'Selecione uma vistoria antes de enviar mensagens.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    // O guiado depende do agente (ADK/Gemini) pra cada turno -- diferente
    // do modo em massa, não tem como enfileirar offline. Falha rápido
    // antes de limpar o campo de texto (senão o mecânico perderia o que
    // escreveu sem nem saber por quê não foi).
    if (!ArgosConnectivityService.instance.isOnline.value) {
      _showSnack(
        'Isso precisa de internet -- sua mensagem não foi enviada.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    setState(() {
      messages.add(ChatMessage(type: ChatMessageType.user, text: text, createdAt: DateTime.now()));

      messageController.clear();
      hasText = false;
      isAiTyping = true;
    });

    _scrollToBottom();

    await VistoriaChatSessionService.instance.appendUserMessage(
      vistoriaDocId: session.docId,
      text: text,
    );

    try {
      if (isInspectionCompleted) return;

      final reply = await ArgosAiService.instance.sendMessage(
        text: text,
        inspectionId: session.idvistoria,
        isRetificacao: session.isRetificacao,
        ajustesNecessarios: session.ajustesNecessarios,
        contextoVistoriaAnterior: session.contextoVistoriaAnterior,
      );

      if (isInspectionCompleted) return;

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: reply,
      );

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(_aiMessageFromText(reply, createdAt: DateTime.now()));
      });

      _openCameraAfterPhotoRelease(reply);
      _scrollToBottom();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('ERRO CLOUD FUNCTION');
      debugPrint('code: ${e.code}');
      debugPrint('message: ${e.message}');
      debugPrint('details: ${e.details}');

      if (!mounted) return;

      final errorText =
          'O assistente Argos está temporariamente indisponível.\nCódigo: ${e.code}';

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: errorText,
      );

      setState(() {
        isAiTyping = false;

        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: errorText,
          ),
        );
      });

      _scrollToBottom();
    } catch (e) {
      debugPrint('ERRO GERAL CHAT IA: $e');

      if (!mounted) return;

      const errorText = 'Erro inesperado ao chamar o assistente.';

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: errorText,
      );

      setState(() {
        isAiTyping = false;

        messages.add(
          const ChatMessage(
            type: ChatMessageType.ai,
            text: errorText,
          ),
        );
      });

      _scrollToBottom();
    }
  }

  Future<void> _openCamera() async {
    final session = currentSession;

    if (isInspectionCompleted) return;

    if (session == null) {
      _showSnack(
        'Selecione uma vistoria antes de anexar fotos.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    // Recusa antes de sequer abrir a câmera -- sem isso o mecânico tirava
    // as fotos e só descobria que falhou (sem aviso nenhum, só um log) na
    // hora do upload.
    if (!ArgosConnectivityService.instance.isOnline.value) {
      _showSnack(
        'Isso precisa de internet para anexar fotos.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    if (cameraPulsing) {
      setState(() {
        cameraPulsing = false;
      });
    }

    FocusScope.of(context).unfocus();

    final List<XFile>? photos = await Navigator.of(
      context,
    ).push<List<XFile>?>(MaterialPageRoute(builder: (_) => const CameraPage()));

    if (photos == null || photos.isEmpty) return;

    setState(() {
      for (final photo in photos) {
        messages.add(
          ChatMessage(
            type: ChatMessageType.photo,
            text: 'Foto anexada à vistoria',
            imagePath: photo.path,
            createdAt: DateTime.now(),
          ),
        );
      }
    });

    _scrollToBottom();

    var uploadedAnyPhoto = false;

    for (final photo in photos) {
      try {
        final uploadedImage =
            await VistoriaChatSessionService.instance.uploadImageFile(
          vistoriaDocId: session.docId,
          imagePath: photo.path,
        );

        await VistoriaChatSessionService.instance.appendImageEvidence(
          vistoriaDocId: session.docId,
          imageUrl: uploadedImage.downloadUrl,
          imagePath: photo.path,
          imageId: uploadedImage.imageId,
          storagePath: uploadedImage.storagePath,
          fileName: uploadedImage.fileName,
          contentType: uploadedImage.contentType,
          sizeBytes: uploadedImage.sizeBytes,
        );

        await VistoriaChatSessionService.instance.appendChatMessage(
          vistoriaDocId: session.docId,
          role: 'photo',
          text: 'Foto anexada à vistoria',
          extraData: {
            'imageId': uploadedImage.imageId,
            'url': uploadedImage.downloadUrl,
            'storagePath': uploadedImage.storagePath,
            'fileName': uploadedImage.fileName,
          },
        );

        uploadedAnyPhoto = true;
      } catch (e) {
        debugPrint('Erro ao salvar foto da vistoria no Storage: $e');
      }
    }

    if (!uploadedAnyPhoto) return;

    await _analyzePhotosWithAgent(session: session, quantity: photos.length);
  }

  /// Avisa o agente que a leva de fotos subiu e MOSTRA a resposta dele.
  ///
  /// Antes isto era `unawaited(...)` com a reply descartada, e a tela exibia
  /// um texto fixo montado aqui. Fazia sentido com o Dialogflow CX, que não
  /// enxerga imagem. Com o ADK, este é o turno em que `AnalistaDanosVisao` e
  /// `VerificadorConsistencia` rodam — descartar a resposta esconderia
  /// exatamente o que a troca de backend veio entregar.
  Future<void> _analyzePhotosWithAgent({
    required VistoriaSession session,
    required int quantity,
  }) async {
    if (!mounted) return;

    setState(() => isAiTyping = true);
    _scrollToBottom();

    final plural = quantity > 1 ? 's' : '';
    final fallback =
        '$quantity foto$plural recebida$plural. Essas evidências foram vinculadas à vistoria.';

    String aiText;

    try {
      final reply = await ArgosAiService.instance.sendBackgroundMessage(
        text: 'Fotos enviadas ($quantity).',
        inspectionId: session.idvistoria,
        isRetificacao: session.isRetificacao,
        ajustesNecessarios: session.ajustesNecessarios,
        contextoVistoriaAnterior: session.contextoVistoriaAnterior,
      );

      aiText = reply.trim().isEmpty ? fallback : reply.trim();
    } catch (e) {
      debugPrint('Erro ao notificar envio de fotos para IA: $e');
      aiText = fallback;
    }

    await VistoriaChatSessionService.instance.appendAiMessage(
      vistoriaDocId: session.docId,
      text: aiText,
    );

    if (!mounted) return;

    setState(() {
      isAiTyping = false;
      messages.add(_aiMessageFromText(aiText));
    });

    _scrollToBottom();
  }

  /// Abre o modal de composição do modo "enviar tudo de uma vez"
  /// (`BulkUploadSheet`) e, se o mecânico confirmar o envio, orquestra o
  /// upload -- reaproveitando literalmente as mesmas chamadas de serviço que
  /// o fluxo guiado já usa por item, só que em loop e sem notificar o
  /// agente a cada foto/áudio.
  /// Chamado toda vez que `ArgosConnectivityService.isOnline` muda -- só
  /// nos interessa a borda offline→online, e só quando tem um pacote em
  /// massa parado esperando conexão nesta vistoria (o rascunho persistido
  /// é a fonte da verdade, não o `BulkUploadSheet`, que pode nem estar
  /// aberto nesse momento).
  void _handleConnectivityRestored() {
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    // Tela bloqueada (vistoria guiada em aberto, offline) -- assim que a
    // conexão volta, refaz o bootstrap do zero: agora cai no ramo online
    // normal (`_askVistoriaAction`/diálogo de retomada), que é quem
    // realmente sabe lidar com uma sessão guiada em aberto. O envio em
    // massa pendente NÃO é tratado aqui -- isso é o `BulkSyncCoordinator`
    // (singleton, sobrevive a troca de tela) que faz sozinho, pra TODAS as
    // vistorias pendentes do mecânico, não só a que porventura estiver
    // montada nesta tela (ver `_handleBulkPackageSubmitted`).
    if (isBlockedOfflineGuidedHistory) {
      unawaited(_bootstrapChatSession());
    }
  }

  /// Chamado pelo `BulkSyncCoordinator` quando QUALQUER pacote em massa
  /// termina de enviar -- só reage se for a vistoria que esta tela está
  /// mostrando agora. Cobre tanto o envio disparado pelo próprio toque em
  /// "Enviar" (`_submitBulkPackage`) quanto o que a varredura automática em
  /// segundo plano processou sozinha, sem esta tela ter feito nada.
  void _handleBulkPackageSubmitted(String vistoriaDocId) {
    if (!mounted) return;
    if (currentSession?.docId != vistoriaDocId) return;
    if (isInspectionCompleted) return;

    unawaited(vistoriaCompletionSubscription?.cancel());
    vistoriaCompletionSubscription = null;

    setState(() {
      isBulkProcessing = false;
      isAwaitingBulkSync = false;
      isInspectionCompleted = true;
      completedInspectionStatus =
          VistoriaChatSessionService.statusEmAnaliseOperacional;
    });
  }

  Future<void> _openBulkUploadSheet() async {
    if (isInspectionCompleted || isBulkProcessing) return;

    final session = currentSession;

    if (session == null) return;

    FocusScope.of(context).unfocus();

    // Busca direto do servidor (não confia no snapshot em memória de
    // `session`) -- é exatamente o cenário que essa fila existe pra cobrir:
    // uma tentativa anterior pode ter deixado itens marcados no Firestore
    // depois que esta sessão já tinha sido carregada.
    final draft = await VistoriaChatSessionService.instance
        .fetchEnvioEmMassaRascunho(session.docId);

    if (!mounted) return;

    final result = await BulkUploadSheet.show(
      context,
      vistoriaDocId: session.docId,
      initialDraft: draft,
    );

    if (result == null || !mounted) return;

    final hasAnything = result.photos.isNotEmpty ||
        result.audios.isNotEmpty ||
        result.text.trim().isNotEmpty ||
        result.orcamentoItems.isNotEmpty;

    if (!hasAnything) return;

    await _submitBulkPackage(session: session, result: result);
  }

  /// O upload de verdade (fotos/áudios/texto/orçamento + finalização) mora
  /// inteiro no `BulkSyncCoordinator` -- um singleton que sobrevive a troca
  /// de tela, igual o `ArgosConnectivityService`. Isso é o que permite a
  /// retomada automática funcionar mesmo que o mecânico saia desta tela
  /// entre o "Enviar offline" e a reconexão (limitação real que existia
  /// antes, quando esse código vivia só aqui dentro). A transição pra
  /// "concluído" não acontece aqui dentro -- acontece em
  /// `_handleBulkPackageSubmitted`, disparada pelo
  /// `onPackageSubmitted` do coordenador, pra funcionar igual nos dois
  /// casos (enviado por este toque ou por uma varredura em segundo plano
  /// que ganhou a corrida).
  Future<void> _submitBulkPackage({
    required VistoriaSession session,
    required BulkUploadResult result,
  }) async {
    // O rascunho já está seguro no Firestore (cada item foi sincronizado
    // assim que entrou no BulkUploadSheet, isso funciona offline sozinho).
    // O que NÃO funciona offline é o upload de verdade pro Storage nem a
    // chamada ao agente pra transcrever áudio -- diferente de escrita
    // Firestore comum, essas não enfileiram. Sem essa checagem, tocar
    // "Enviar" offline subia nada, falhava calado (só um debugPrint) e
    // ainda assim finalizava a vistoria como se tivesse dado tudo certo.
    if (!ArgosConnectivityService.instance.isOnline.value) {
      setState(() => isAwaitingBulkSync = true);

      // Persistido (não só em memória nesta tela) -- se o mecânico sair e
      // voltar antes de reconectar, uma instância nova do AiChatPage
      // precisa saber que este pacote já foi confirmado, pra mostrar a
      // tela travada em vez do botão de montar de novo.
      unawaited(
        VistoriaChatSessionService.instance.markEnvioEmMassaConfirmadoOffline(
          vistoriaDocId: session.docId,
        ),
      );

      _showSnack(
        'Sem conexão — o pacote já está salvo e vai ser enviado sozinho '
        'assim que a internet voltar.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    setState(() {
      isAwaitingBulkSync = false;
      isBulkProcessing = true;
    });
    bulkStatusText.value = 'Enviando fotos...';

    try {
      await BulkSyncCoordinator.instance.submitPackage(
        vistoriaDocId: session.docId,
        sinistroId: session.sinistroId,
        idvistoria: session.idvistoria,
        result: result,
        onStatus: (status) => bulkStatusText.value = status,
      );
    } catch (e) {
      debugPrint('Erro ao enviar pacote em massa: $e');

      if (!mounted) return;

      setState(() => isBulkProcessing = false);

      _showSnack(
        'Não foi possível concluir o envio. Tente novamente.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  Future<String> _createAudioFilePath() async {
    final directory = await getApplicationDocumentsDirectory();

    final audioDirectory = Directory('${directory.path}/argos_audios');

    if (!await audioDirectory.exists()) {
      await audioDirectory.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;

    return '${audioDirectory.path}/argos_audio_$timestamp.m4a';
  }

  Future<void> _startRecording() async {
    if (isRecording || isStartingRecording) return;
    if (isInspectionCompleted) return;

    // Recusa antes de gravar -- transcrição e envio dependem do backend,
    // gravar pra descobrir depois que falhou só desperdiça o áudio.
    if (!ArgosConnectivityService.instance.isOnline.value) {
      _showSnack(
        'Isso precisa de internet para gravar áudio.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isStartingRecording = true;
    });

    try {
      final hasPermission = await audioRecorder.hasPermission();

      if (!hasPermission) {
        _showSnack(
          'Permissão de microfone necessária para gravar áudio.',
          backgroundColor: Colors.orange,
        );
        return;
      }

      final path = await _createAudioFilePath();

      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );

      if (!mounted) return;

      setState(() {
        isRecording = true;
        recordingSeconds = 0;
        currentRecordingPath = path;
      });

      recordingTimer?.cancel();
      recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;

        setState(() {
          recordingSeconds++;
        });
      });
    } catch (e) {
      debugPrint('Start recording error: $e');

      _showSnack(
        'Erro ao iniciar gravação de áudio.',
        backgroundColor: Colors.redAccent,
      );
    } finally {
      if (mounted) {
        setState(() {
          isStartingRecording = false;
        });
      }
    }
  }

  Future<void> _cancelRecording() async {
    recordingTimer?.cancel();

    if (isRecording) {
      try {
        await audioRecorder.stop();
      } catch (_) {}
    }

    final path = currentRecordingPath;

    if (path != null) {
      final file = File(path);

      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    if (!mounted) return;

    setState(() {
      isRecording = false;
      isStartingRecording = false;
      recordingSeconds = 0;
      currentRecordingPath = null;
    });
  }

  Future<void> _finishRecording() async {
    if (!isRecording) return;
    if (isInspectionCompleted) {
      await _cancelRecording();
      return;
    }

    final session = currentSession;

    if (session == null) {
      _showSnack(
        'Selecione uma vistoria antes de enviar áudio.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    final duration = recordingSeconds;
    final fallbackPath = currentRecordingPath;

    recordingTimer?.cancel();

    String? recordedPath;

    try {
      recordedPath = await audioRecorder.stop();
    } catch (e) {
      debugPrint('Stop recording error: $e');
    }

    final path = recordedPath ?? fallbackPath;

    if (!mounted) return;

    setState(() {
      isRecording = false;
      recordingSeconds = 0;
      currentRecordingPath = null;
    });

    if (path == null) {
      _showSnack(
        'Não foi possível salvar o áudio.',
        backgroundColor: Colors.redAccent,
      );
      return;
    }

    final file = File(path);

    if (!await file.exists()) {
      _showSnack(
        'Arquivo de áudio não encontrado.',
        backgroundColor: Colors.redAccent,
      );
      return;
    }

    if (duration <= 0) {
      try {
        await file.delete();
      } catch (_) {}

      _showSnack(
        'Gravação muito curta. Grave novamente.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    setState(() {
      messages.add(
        ChatMessage(
          type: ChatMessageType.audio,
          text: '',
          audioPath: path,
          durationSeconds: duration,
          audioStatus: 'uploading',
          createdAt: DateTime.now(),
        ),
      );
    });

    _scrollToBottom();

    try {
      final uploadedAudio = await UserAudioStorageService.instance
          .uploadOriginalAudioForMp3Conversion(
            localAudioPath: path,
      idvistoria: session.idvistoria,
            sinistroId: session.sinistroId,
            duration: Duration(seconds: duration),
          );
      if (!mounted) return;

      setState(() {
        final index = messages.lastIndexWhere(
          (message) =>
              message.type == ChatMessageType.audio &&
              message.audioPath == path,
        );

        if (index >= 0) {
          messages[index] = ChatMessage(
            type: ChatMessageType.audio,
            text: '',
            audioPath: path,
            durationSeconds: duration,
            audioId: uploadedAudio.audioId,
            originalStoragePath: uploadedAudio.originalStoragePath,
            mp3StoragePath: uploadedAudio.mp3StoragePath,
            mp3DownloadUrl: uploadedAudio.mp3DownloadUrl,
            audioStatus: 'transcribing',
            createdAt: messages[index].createdAt,
          );
        }

        isAiTyping = true;
      });

      _scrollToBottom();

      if (isInspectionCompleted) return;

      final audioResult = await ArgosAiService.instance.sendAudioMessage(
        idvistoria: session.idvistoria,
        sinistroId: session.sinistroId,
        audioId: uploadedAudio.audioId,
        storagePath: uploadedAudio.mp3StoragePath,
        durationSeconds: duration,
      );

      if (isInspectionCompleted) return;

      if (!mounted) return;

      setState(() {
        final index = messages.lastIndexWhere(
          (message) =>
              message.type == ChatMessageType.audio &&
              message.audioPath == path,
        );

        if (index >= 0) {
          messages[index] = ChatMessage(
            type: ChatMessageType.audio,
            // Fica escondida por padrão — a bolha mostra um botão
            // "Transcrever áudio" (estilo WhatsApp) que revela isso ali
            // dentro, em vez de virar uma mensagem separada sempre visível.
            text: audioResult.revisedTranscript,
            audioPath: path,
            durationSeconds: duration,
            audioId: uploadedAudio.audioId,
            originalStoragePath: uploadedAudio.originalStoragePath,
            mp3StoragePath: uploadedAudio.mp3StoragePath,
            mp3DownloadUrl: uploadedAudio.mp3DownloadUrl,
            audioStatus: 'done',
            createdAt: messages[index].createdAt,
          );
        }

        messages.add(
          _aiMessageFromText(audioResult.reply, createdAt: DateTime.now()),
        );

        isAiTyping = false;
      });

      _openCameraAfterPhotoRelease(audioResult.reply);
      _scrollToBottom();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('ERRO CLOUD FUNCTION AUDIO');
      debugPrint('code: ${e.code}');
      debugPrint('message: ${e.message}');
      debugPrint('details: ${e.details}');

      if (!mounted) return;

      setState(() {
        final index = messages.lastIndexWhere(
          (message) =>
              message.type == ChatMessageType.audio &&
              message.audioPath == path,
        );

        if (index >= 0) {
          messages[index] = ChatMessage(
            type: ChatMessageType.audio,
            text: '',
            audioPath: path,
            durationSeconds: duration,
            audioStatus: 'error',
            createdAt: messages[index].createdAt,
          );
        }

        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text:
                'Recebi o áudio, mas não consegui transcrever agora. Código: ${e.code}',
          ),
        );

        isAiTyping = false;
      });

      _scrollToBottom();
    } catch (e) {
      debugPrint('Upload/transcrição audio error: $e');

      if (!mounted) return;

      setState(() {
        final index = messages.lastIndexWhere(
          (message) =>
              message.type == ChatMessageType.audio &&
              message.audioPath == path,
        );

        if (index >= 0) {
          messages[index] = ChatMessage(
            type: ChatMessageType.audio,
            text: '',
            audioPath: path,
            durationSeconds: duration,
            audioStatus: 'error',
            createdAt: messages[index].createdAt,
          );
        }

        messages.add(
          const ChatMessage(
            type: ChatMessageType.ai,
            text:
                'Não consegui processar o áudio. Verifique sua conexão e tente novamente.',
          ),
        );

        isAiTyping = false;
      });

      _scrollToBottom();

      _showSnack('Erro ao processar áudio.', backgroundColor: Colors.redAccent);
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  /// Três estados possíveis embaixo do chat:
  /// 1. Pergunta bifurcada pendente -- nada aqui, os botões ficam inline na
  ///    própria bolha (ver `_ChatBubble`/`_AiBubble`).
  /// 2. Modo em massa escolhido e ainda não enviado -- some com
  ///    câmera/texto/mic (não fazem sentido fora do modal) e mostra um único
  ///    botão grande que abre o `BulkUploadSheet`.
  /// 3. Guiado (ou vistoria antiga sem esse campo) -- composer de sempre.
  Widget _buildComposerArea(String duration) {
    if (awaitingColetaModoChoice || isBlockedOfflineGuidedHistory) {
      return const SizedBox.shrink(key: ValueKey('awaiting_choice'));
    }

    if (coletaModo == ColetaModo.emMassa) {
      return _BulkComposerButton(
        key: const ValueKey('bulk_composer'),
        onTap: _openBulkUploadSheet,
      );
    }

    if (isRecording) {
      return _RecordingComposer(
        key: const ValueKey('recording'),
        duration: duration,
        onCancel: _cancelRecording,
        onSend: _finishRecording,
      );
    }

    return _TextComposer(
      key: const ValueKey('composer'),
      controller: messageController,
      hasText: hasText,
      isStartingRecording: isStartingRecording,
      cameraUnlocked: cameraUnlocked,
      cameraPulsing: cameraPulsing,
      onCameraTap: _openCamera,
      onSendTap: _sendTextMessage,
      onMicTap: _startRecording,
    );
  }

  @override
  Widget build(BuildContext context) {
    final duration = _formatDuration(recordingSeconds);

    if (isLoadingSession) {
      return const SafeArea(child: _ChatSessionLoading());
    }

    return Stack(
      children: [
        SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final offsetAnimation = Tween<Offset>(
            begin: const Offset(-0.08, 0),
            end: Offset.zero,
          ).animate(animation);

          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: offsetAnimation,
              child: child,
            ),
          );
        },
        child: currentSession == null
            ? _SinistroSelectionView(
                key: const ValueKey('sinistro_selection'),
                options: availableSinistros,
                onSelect: _handleSinistroSelected,
              )
            : isConvertingToOfflineBulk
                ? Column(
                    key: ValueKey(
                      'chat_converting_${currentSession!.idvistoria}',
                    ),
                    children: [
                      _ChatHeader(
                        session: currentSession,
                        onCloseChat: null,
                      ),
                      Expanded(
                        child: _ConvertingToOfflineBulkScreen(
                          placa: currentSession!.placa,
                        ),
                      ),
                    ],
                  )
                : isAwaitingBulkSync
                ? Column(
                    key: ValueKey(
                      'chat_awaiting_sync_${currentSession!.idvistoria}',
                    ),
                    children: [
                      _ChatHeader(
                        session: currentSession,
                        onCloseChat: _closeCurrentChatAndBackToSelection,
                      ),
                      Expanded(
                        child: _BulkAwaitingSyncScreen(
                          session: currentSession!,
                          onBackToSelection:
                              _closeCurrentChatAndBackToSelection,
                        ),
                      ),
                    ],
                  )
                : isInspectionCompleted
                ? Column(
                    key: ValueKey(
                      'chat_completed_${currentSession!.idvistoria}',
                    ),
                    children: [
                      _ChatHeader(
                        session: currentSession,
                        onCloseChat: _closeCurrentChatAndBackToSelection,
                      ),
                      Expanded(
                        child: _InspectionCompletedView(
                          session: currentSession!,
                          status: completedInspectionStatus,
                          onBackToSelection:
                              _closeCurrentChatAndBackToSelection,
                        ),
                      ),
                    ],
                  )
                : Column(
                    key: ValueKey('chat_${currentSession!.idvistoria}'),
                    children: [
                      _ChatHeader(
                        session: currentSession,
                        onCloseChat: _closeCurrentChatAndBackToSelection,
                      ),
                      if (currentSession!.isRetificacao)
                        _RetificacaoBanner(
                          ajustesNecessarios: currentSession!.ajustesNecessarios,
                        ),
                      Expanded(
                        child: ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                          itemCount: messages.length + (isAiTyping ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (isAiTyping && index == messages.length) {
                              return const Padding(
                                padding: EdgeInsets.only(bottom: 16),
                                child: _TypingBubble(),
                              );
                            }

                            final message = messages[index];
                            final isCameraReleaseMessage =
                                message.type == ChatMessageType.ai &&
                                _isPhotoReleaseText(message.text);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: _ChatBubble(
                                message: message,
                                onOpenCamera:
                                    isCameraReleaseMessage ? _openCamera : null,
                                onChooseColetaModo: message.isColetaModoPrompt &&
                                        awaitingColetaModoChoice
                                    ? _handleColetaModoChosen
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, animation) {
                          return SizeTransition(
                            sizeFactor: animation,
                            axisAlignment: -1,
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          );
                        },
                        child: _buildComposerArea(duration),
                      ),
                    ],
                  ),
          ),
        ),
        if (isBulkProcessing)
          Positioned.fill(
            child: Container(
              color: Colors.white.withOpacity(.94),
              child: Center(
                child: EyeProcessingAnimation(statusText: bulkStatusText),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChatSessionLoading extends StatelessWidget {
  const _ChatSessionLoading();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _ChatHeader(),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Color(0xFF0057C0)),
                const SizedBox(height: 18),
                Text(
                  'Preparando sessão da vistoria...',
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF0057C0),
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InspectionCompletedView extends StatefulWidget {
  final VistoriaSession session;
  final String status;
  final VoidCallback onBackToSelection;

  const _InspectionCompletedView({
    required this.session,
    required this.status,
    required this.onBackToSelection,
  });

  @override
  State<_InspectionCompletedView> createState() =>
      _InspectionCompletedViewState();
}

class _InspectionCompletedViewState extends State<_InspectionCompletedView>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Animation<double> pulseAnimation;
  late final Animation<double> checkAnimation;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    pulseAnimation = Tween<double>(begin: .92, end: 1.08).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic),
    );

    checkAnimation = Tween<double>(begin: .82, end: 1).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  // O status que chega aqui é o valor cru do Firestore (vistorias.status) —
  // nunca deve aparecer pro mecânico sem tradução (ex: "EM_ANALISE_OPERACIONAL").
  static String _friendlyStatus(String rawStatus) {
    final normalized = rawStatus.trim().toUpperCase();

    switch (normalized) {
      case 'EM_ANALISE_OPERACIONAL':
        return 'Em análise pelo time de operações';
      case 'FINALIZADA':
        return 'Vistoria finalizada';
      case 'REJEITADA':
        return 'Vistoria rejeitada';
      case 'CANCELADA':
        return 'Vistoria cancelada';
      case 'EXPIRADA':
        return 'Vistoria expirada';
      case 'ABANDONADA':
        return 'Vistoria abandonada';
    }

    if (normalized.isEmpty) return '';

    // Fallback pra qualquer status novo que a gente ainda não mapeou aqui:
    // pelo menos humaniza (sem underscore, sem caixa alta) em vez de
    // mostrar a constante do banco crua.
    return normalized
        .split('_')
        .map((word) => word.isEmpty
            ? word
            : '${word[0]}${word.substring(1).toLowerCase()}')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final status = _friendlyStatus(widget.status);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      decoration: const BoxDecoration(
        color: Color(0xFFF3FBFF),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              return Transform.scale(
                scale: pulseAnimation.value,
                child: child,
              );
            },
            child: Container(
              width: 116,
              height: 116,
              decoration: BoxDecoration(
                color: const Color(0xFFE5F6FF),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00A36C).withOpacity(.18),
                    blurRadius: 28,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: checkAnimation.value,
                      child: child,
                    );
                  },
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00A36C),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 46,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
          Text(
            'Vistoria concluida',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
              fontSize: 26,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Aguarde a proxima etapa.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF414755),
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE5F6FF)),
            ),
            child: Column(
              children: [
                Text(
                  widget.session.placa.isEmpty
                      ? widget.session.idvistoria
                      : widget.session.placa,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF0057C0),
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: widget.onBackToSelection,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0057C0),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text(
              'Ver outras vistorias',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _SinistroSelectionView extends StatefulWidget {
  final List<SinistroVistoriaOption> options;
  final ValueChanged<SinistroVistoriaOption> onSelect;

  const _SinistroSelectionView({
    super.key,
    required this.options,
    required this.onSelect,
  });

  @override
  State<_SinistroSelectionView> createState() =>
      _SinistroSelectionViewState();
}

class _SinistroSelectionViewState extends State<_SinistroSelectionView> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _matchesSearch(SinistroVistoriaOption option) {
    final query = _normalize(_query);
    if (query.isEmpty) return true;

    return _normalize(option.placa).contains(query) ||
        _normalize(option.veiculo).contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final options =
        widget.options.where(_matchesSearch).toList(growable: false);

    return Column(
      children: [
        const _ChatHeader(),
        if (widget.options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
            child: Row(
              children: [
                Expanded(
                  child: _isSearching
                      ? TextField(
                          controller: _searchController,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onChanged: (value) =>
                              setState(() => _query = value),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1F2937),
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Buscar por placa ou modelo',
                            hintStyle: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        )
                      : const Text(
                          'Selecione o veículo',
                          style: TextStyle(
                            color: Color(0xFF414755),
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: _isSearching ? 'Fechar busca' : 'Buscar placa',
                    child: Material(
                      color: _isSearching
                          ? const Color(0xFF0057C0)
                          : const Color(0xFFE5F6FF),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _isSearching = !_isSearching;
                            if (!_isSearching) {
                              _searchController.clear();
                              _query = '';
                            }
                          });
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Icon(
                            _isSearching ? Icons.close : Icons.search,
                            color: _isSearching
                                ? Colors.white
                                : const Color(0xFF0057C0),
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: options.isEmpty
                ? Center(
                    child: Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        widget.options.isEmpty
                            ? 'Nenhum veículo com check-in disponível para iniciar vistoria.'
                            : 'Nenhum veículo encontrado para essa busca.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF414755),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: options.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final option = options[index];
                      final isRetificacao = option.isRetificacaoPendente;
                      final accentColor = isRetificacao
                          ? Colors.deepOrange
                          : const Color(0xFF0057C0);

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => widget.onSelect(option),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: isRetificacao
                                        ? Colors.deepOrange.withOpacity(.10)
                                        : const Color(0xFFE5F6FF),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    isRetificacao
                                        ? Icons.rate_review_outlined
                                        : Icons.directions_car,
                                    color: accentColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: EllipsisText(
                                              option.placa.isEmpty
                                                  ? 'Sem placa'
                                                  : option.placa,
                                              style: const TextStyle(
                                                color: Color(0xFF1F2937),
                                                fontWeight: FontWeight.w900,
                                                fontSize: 16,
                                              ),
                                            ),
                                          ),
                                          if (isRetificacao) ...[
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.deepOrange
                                                    .withOpacity(.12),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: const Text(
                                                'RETIFICAÇÃO',
                                                style: TextStyle(
                                                  color: Colors.deepOrange,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      EllipsisText(
                                        option.veiculo.isEmpty
                                            ? 'Veículo não informado'
                                            : option.veiculo,
                                        style: const TextStyle(
                                          color: Color(0xFF414755),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: accentColor,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _VistoriaInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _VistoriaInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF0057C0)),
        const SizedBox(width: 10),
        Text(
          '$label: ',
          style: const TextStyle(
            color: Color(0xFF6B7280),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
        Expanded(
          child: EllipsisText(
            value,
            style: const TextStyle(
              color: Color(0xFF1F2937),
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _VistoriaActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool filled;
  final VoidCallback onTap;

  const _VistoriaActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? color : color.withOpacity(.07),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                color: filled ? Colors.white : color,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: filled ? Colors.white : const Color(0xFF1F2937),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: filled
                            ? Colors.white.withOpacity(.85)
                            : const Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        fontSize: 11.5,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: filled ? Colors.white : color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fica fixo no topo do chat de retificação, pra nunca deixar o mecânico
/// esquecer o que o analista pediu pra corrigir — mesma cor/ícone da aba
/// "Revisão" da listagem (inspection_filter.dart), de propósito.
class _RetificacaoBanner extends StatelessWidget {
  final String ajustesNecessarios;

  const _RetificacaoBanner({required this.ajustesNecessarios});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: Colors.deepOrange.withOpacity(.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.rate_review_outlined, size: 18, color: Colors.deepOrange),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Retificação — corrija o que o analista apontou',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.deepOrange,
                  ),
                ),
                if (ajustesNecessarios.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    ajustesNecessarios.trim(),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF5A4034),
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  final VistoriaSession? session;
  final VoidCallback? onCloseChat;

  const _ChatHeader({
    this.session,
    this.onCloseChat,
  });

  @override
  Widget build(BuildContext context) {
    final idvistoria = session?.idvistoria.trim() ?? '';
    final placa = session?.placa.trim() ?? '';

    // O formato VIS-OFFLINE-NNNN já é autoexplicativo -- não precisa de
    // selo extra avisando que é provisório.
    final subtitle = [
      if (idvistoria.isNotEmpty) idvistoria,
      if (placa.isNotEmpty) placa,
    ].join(' • ');

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.03),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          if (onCloseChat != null) ...[
            Material(
              color: const Color(0xFFE5F6FF),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: onCloseChat,
                borderRadius: BorderRadius.circular(16),
                child: const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.keyboard_arrow_left_rounded,
                    color: Color(0xFF0057C0),
                    size: 30,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0057C0), Color(0xFF0474FB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0057C0).withOpacity(.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.smart_toy_outlined,
              color: Colors.white,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Argos IA',
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF1F2937),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                EllipsisText(
                  subtitle.isEmpty
                      ? 'Assistente de vistoria inteligente'
                      : subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
class _ChatBubble extends StatelessWidget {
  final ChatMessage message;

  /// Só não-nulo na bolha exata que liberou a câmera (calculado pelo
  /// chamador com _isPhotoReleaseText, que é um método de estado e não dá
  /// pra chamar direto daqui, já que esta é uma StatelessWidget à parte).
  final VoidCallback? onOpenCamera;

  /// Só não-nulo na bolha da pergunta bifurcada
  /// (`message.isColetaModoPrompt`) -- renderiza os dois botões inline.
  final void Function(ColetaModo)? onChooseColetaModo;

  const _ChatBubble({
    required this.message,
    this.onOpenCamera,
    this.onChooseColetaModo,
  });

  @override
  Widget build(BuildContext context) {
    switch (message.type) {
      case ChatMessageType.ai:
        return _AiBubble(
          text: message.text,
          boldLineIndexes: message.boldLineIndexes,
          createdAt: message.createdAt,
          onOpenCamera: onOpenCamera,
          isColetaModoPrompt: message.isColetaModoPrompt,
          selectedColetaModo: message.selectedColetaModo,
          onChooseColetaModo: onChooseColetaModo,
        );

      case ChatMessageType.user:
        return _UserBubble(text: message.text, createdAt: message.createdAt);

      case ChatMessageType.photo:
        return _PhotoBubble(
          text: message.text,
          imagePath: message.imagePath,
          createdAt: message.createdAt,
        );

      case ChatMessageType.audio:
        return _AudioBubble(
          text: message.text,
          audioPath: message.audioPath,
          audioStatus: message.audioStatus,
          audioId: message.audioId,
          durationSeconds: message.durationSeconds,
          mp3DownloadUrl: message.mp3DownloadUrl,
          profilePhotoUrl: FirebaseAuth.instance.currentUser?.photoURL,
          createdAt: message.createdAt,
        );
    }
  }
}

class _AiBubble extends StatelessWidget {
  final String text;
  final List<int> boldLineIndexes;
  final DateTime? createdAt;
  final VoidCallback? onOpenCamera;
  final bool isColetaModoPrompt;
  final ColetaModo? selectedColetaModo;
  final void Function(ColetaModo)? onChooseColetaModo;

  const _AiBubble({
    required this.text,
    this.boldLineIndexes = const [],
    this.createdAt,
    this.onOpenCamera,
    this.isColetaModoPrompt = false,
    this.selectedColetaModo,
    this.onChooseColetaModo,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CircleAvatar(
          radius: 18,
          backgroundColor: Color(0xFF0057C0),
          child: Icon(Icons.smart_toy, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            decoration: const BoxDecoration(
              color: Color(0xFFE5F6FF),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(22),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      color: Color(0xFF1F2937),
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                    children: _buildLineSpans(),
                  ),
                ),
                if (onOpenCamera != null) ...[
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: onOpenCamera,
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0057C0),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Abrir câmera',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (isColetaModoPrompt) ...[
                  const SizedBox(height: 12),
                  _ColetaModoChoiceButton(
                    icon: Icons.chat_bubble_rounded,
                    label: 'Passo a passo',
                    selected: selectedColetaModo == ColetaModo.guiado,
                    // Enquanto não respondida (selectedColetaModo == null),
                    // os dois botões ficam tocáveis. Depois de respondida,
                    // os dois ficam só-leitura -- mostrando qual foi
                    // escolhida em vez de sumirem sem deixar rastro (bug
                    // reportado pelo usuário: a resposta não ficava
                    // registrada na tela).
                    onTap: selectedColetaModo == null &&
                            onChooseColetaModo != null
                        ? () => onChooseColetaModo!(ColetaModo.guiado)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  _ColetaModoChoiceButton(
                    icon: Icons.upload_file_rounded,
                    label: 'Enviar tudo de uma vez',
                    selected: selectedColetaModo == ColetaModo.emMassa,
                    onTap: selectedColetaModo == null &&
                            onChooseColetaModo != null
                        ? () => onChooseColetaModo!(ColetaModo.emMassa)
                        : null,
                  ),
                ],
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMessageTime(createdAt),
                    style: TextStyle(
                      color: const Color(0xFF414755).withOpacity(.60),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<TextSpan> _buildLineSpans() {
    final lines = text.split('\n');

    return lines.asMap().entries.expand((entry) {
      final isBold = boldLineIndexes.contains(entry.key);

      return [
        TextSpan(
          text: entry.value,
          style: TextStyle(
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
        if (entry.key < lines.length - 1) const TextSpan(text: '\n'),
      ];
    }).toList();
  }
}

class _ColetaModoChoiceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;

  /// Null enquanto a pergunta já foi respondida (ver _handleColetaModoChosen)
  /// -- o botão vira só-leitura, sem InkWell nenhum.
  final VoidCallback? onTap;

  const _ColetaModoChoiceButton({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final answered = onTap == null;
    final showsAsChosen = selected && answered;

    final background = showsAsChosen
        ? const Color(0xFF0057C0)
        : answered
            ? const Color(0xFFE5F6FF)
            : const Color(0xFF0057C0);
    final foreground =
        showsAsChosen || !answered ? Colors.white : const Color(0xFF8A94A6);

    return SizedBox(
      width: double.infinity,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 16),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              if (showsAsChosen) ...[
                const SizedBox(width: 8),
                const Icon(Icons.check_circle_rounded,
                    color: Colors.white, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  final String text;
  final DateTime? createdAt;

  const _UserBubble({required this.text, this.createdAt});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 330),
            child: IntrinsicWidth(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 14, 7),
                decoration: const BoxDecoration(
                  color: Color(0xFF0057C0),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      text,
                      style: const TextStyle(
                        color: Colors.white,
                        height: 1.30,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _formatMessageTime(createdAt),
                        style: TextStyle(
                          color: Colors.white.withOpacity(.72),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhotoBubble extends StatelessWidget {
  final String text;
  final String? imagePath;
  final DateTime? createdAt;

  const _PhotoBubble({
    required this.text,
    required this.imagePath,
    this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    final path = imagePath;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            width: 240,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0057C0),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (path != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      File(path),
                      height: 170,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.image, color: Colors.white, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          text,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      _formatMessageTime(createdAt),
                      style: TextStyle(
                        color: Colors.white.withOpacity(.72),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioBubble extends StatefulWidget {
  final String text;
  final String? audioPath;
  final String? audioStatus;
  final String? audioId;
  final int? durationSeconds;
  final String? mp3DownloadUrl;
  final String? profilePhotoUrl;
  final DateTime? createdAt;

  const _AudioBubble({
    required this.text,
    required this.audioPath,
    this.audioStatus,
    this.audioId,
    this.durationSeconds,
    this.mp3DownloadUrl,
    this.profilePhotoUrl,
    this.createdAt,
  });

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final AudioPlayer player = AudioPlayer();

  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completeSubscription;

  bool isPlaying = false;
  Duration currentPosition = Duration.zero;
  Duration totalDuration = Duration.zero;
  bool _showTranscript = false;

  @override
  void initState() {
    super.initState();

    totalDuration = Duration(seconds: widget.durationSeconds ?? 0);

    _durationSubscription = player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => totalDuration = duration);
    });

    _positionSubscription = player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => currentPosition = position);
    });

    _completeSubscription = player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        isPlaying = false;
        currentPosition = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _completeSubscription?.cancel();
    player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final status = widget.audioStatus ?? 'local';

    final isProcessing =
        status == 'uploading' ||
        status == 'processing' ||
        status == 'transcribing';

    if (isProcessing) return;

    try {
      if (isPlaying) {
        await player.pause();
        if (!mounted) return;
        setState(() => isPlaying = false);
        return;
      }

      final remoteUrl = widget.mp3DownloadUrl?.trim() ?? '';
      final localPath = widget.audioPath?.trim() ?? '';

      if (remoteUrl.isNotEmpty) {
        await player.play(UrlSource(remoteUrl));
      } else if (localPath.isNotEmpty) {
        await player.play(DeviceFileSource(localPath));
      } else {
        return;
      }

      if (!mounted) return;
      setState(() => isPlaying = true);
    } catch (e) {
      debugPrint('Erro ao reproduzir áudio: $e');
      if (!mounted) return;
      setState(() => isPlaying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.audioStatus ?? 'local';

    final isProcessing =
        status == 'uploading' ||
        status == 'processing' ||
        status == 'transcribing';

    final isDone = status == 'done';
    final isError = status == 'error';

    final baseDuration = totalDuration.inSeconds > 0
        ? totalDuration
        : Duration(seconds: widget.durationSeconds ?? 0);

    final durationLabel = isPlaying && currentPosition.inSeconds > 0
        ? _formatAudioBubbleDuration(currentPosition.inSeconds)
        : _formatAudioBubbleDuration(baseDuration.inSeconds);

    const bubbleColor = Color(0xFF0057C0);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _AudioProfileAvatar(
                        photoUrl: widget.profilePhotoUrl,
                        bubbleColor: bubbleColor,
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _togglePlay,
                        child: _AudioPlayButton(
                          isProcessing: isProcessing,
                          isError: isError,
                          isPlaying: isPlaying,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 34,
                              child: _WhatsappWaveform(
                                isProcessing: isProcessing,
                                isError: isError,
                                isPlaying: isPlaying,
                                progress: _audioProgress,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Text(
                                  durationLabel,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(.75),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _formatMessageTime(widget.createdAt),
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(.75),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                _AudioStatusIcon(
                                  isProcessing: isProcessing,
                                  isDone: isDone,
                                  isError: isError,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (widget.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          setState(() => _showTranscript = !_showTranscript),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 2,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.subtitles_outlined,
                              size: 14,
                              color: Colors.white.withOpacity(.85),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              _showTranscript
                                  ? 'Ocultar transcrição'
                                  : 'Transcrever áudio',
                              style: TextStyle(
                                color: Colors.white.withOpacity(.85),
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              _showTranscript
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 16,
                              color: Colors.white.withOpacity(.85),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showTranscript) ...[
                      const SizedBox(height: 2),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          widget.text,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  double get _audioProgress {
    final totalMs = totalDuration.inMilliseconds;

    if (totalMs <= 0) return 0;

    final progress = currentPosition.inMilliseconds / totalMs;

    if (progress.isNaN || progress.isInfinite) return 0;

    return progress.clamp(0, 1);
  }
}

class _AudioProfileAvatar extends StatelessWidget {
  final String? photoUrl;
  final Color bubbleColor;

  const _AudioProfileAvatar({
    required this.photoUrl,
    required this.bubbleColor,
  });

  @override
  Widget build(BuildContext context) {
    final cleanUrl = photoUrl?.trim() ?? '';

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: Colors.white.withOpacity(.18),
          backgroundImage: cleanUrl.isNotEmpty ? NetworkImage(cleanUrl) : null,
          child: cleanUrl.isEmpty
              ? const Icon(
                  Icons.person_rounded,
                  color: Colors.white,
                  size: 28,
                )
              : null,
        ),
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: bubbleColor,
              shape: BoxShape.circle,
              border: Border.all(color: bubbleColor, width: 2),
            ),
            child: const Icon(
              Icons.mic_rounded,
              color: Colors.white,
              size: 15,
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioPlayButton extends StatelessWidget {
  final bool isProcessing;
  final bool isError;
  final bool isPlaying;

  const _AudioPlayButton({
    required this.isProcessing,
    required this.isError,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    if (isProcessing) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.16),
          shape: BoxShape.circle,
        ),
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            color: Colors.white,
          ),
        ),
      );
    }

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.16),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isError
            ? Icons.refresh_rounded
            : isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
        color: Colors.white.withOpacity(.92),
        size: 30,
      ),
    );
  }
}

class _AudioStatusIcon extends StatelessWidget {
  final bool isProcessing;
  final bool isDone;
  final bool isError;

  const _AudioStatusIcon({
    required this.isProcessing,
    required this.isDone,
    required this.isError,
  });

  @override
  Widget build(BuildContext context) {
    if (isProcessing) {
      return SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white.withOpacity(.78),
        ),
      );
    }

    if (isError) {
      return const Icon(
        Icons.error_outline_rounded,
        color: Color(0xFFFFD166),
        size: 17,
      );
    }

    return Icon(
      isDone ? Icons.done_all_rounded : Icons.done_rounded,
      color: isDone ? const Color(0xFF8FD3FF) : Colors.white.withOpacity(.75),
      size: 18,
    );
  }
}

class _WhatsappWaveform extends StatefulWidget {
  final bool isProcessing;
  final bool isError;
  final bool isPlaying;
  final double progress;
  final Color color;

  const _WhatsappWaveform({
    required this.isProcessing,
    required this.isError,
    required this.isPlaying,
    required this.progress,
    required this.color,
  });

  @override
  State<_WhatsappWaveform> createState() => _WhatsappWaveformState();
}

class _WhatsappWaveformState extends State<_WhatsappWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  final List<double> heights = const [
    8,
    14,
    22,
    12,
    28,
    18,
    10,
    26,
    32,
    16,
    22,
    12,
    30,
    20,
    14,
    25,
    34,
    19,
    11,
    27,
    16,
    24,
    31,
    13,
    20,
    29,
    15,
    23,
    10,
    18,
  ];

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );

    if (widget.isProcessing || widget.isPlaying) {
      controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _WhatsappWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);

    final shouldAnimate = widget.isProcessing || widget.isPlaying;

    if (shouldAnimate && !controller.isAnimating) {
      controller.repeat();
    }

    if (!shouldAnimate && controller.isAnimating) {
      controller.stop();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.isError
        ? const Color(0xFFFFD166)
        : widget.color.withOpacity(.48);

    final playedColor = widget.color.withOpacity(.95);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(heights.length, (index) {
            final progress = widget.isProcessing
                ? ((controller.value + index * .045) % 1)
                : 0.0;

            final pulse = widget.isProcessing
                ? 0.72 + (sin(progress * pi * 2).abs() * .45)
                : 1.0;

            final barProgress = (index + 1) / heights.length;
            final isPlayed = widget.progress >= barProgress;

            return Expanded(
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  width: 3.2,
                  height: heights[index] * pulse,
                  margin: const EdgeInsets.symmetric(horizontal: 1.25),
                  decoration: BoxDecoration(
                    color: isPlayed ? playedColor : baseColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

String _formatMessageTime(DateTime? date) {
  final value = date ?? DateTime.now();
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');

  return '$hour:$minute';
}

String _formatAudioBubbleDuration(int seconds) {
  if (seconds <= 0) return '0:00';

  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;

  return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
}

class _BulkComposerButton extends StatelessWidget {
  final VoidCallback onTap;

  const _BulkComposerButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.96),
        border: Border(top: BorderSide(color: Colors.black.withOpacity(.05))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text(
            'Montar envio em massa',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0057C0),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tela cheia mostrada no lugar do chat quando o pacote em massa já foi
/// "confirmado" estando offline -- não é mais um rascunho editável, é um
/// envio pendente esperando rede. Mesmo padrão visual/estrutural de
/// `_InspectionCompletedView` (ícone grande num círculo, título, card com
/// a placa, botão pra voltar), só que em tom âmbar (aguardando) em vez de
/// verde (concluído). Sem nenhum botão de reabrir o pacote de propósito: o
/// mecânico não deve conseguir editar o pacote por engano depois de já ter
/// confirmado o envio; a retomada de verdade acontece sozinha
/// (`_handleConnectivityRestored`) assim que a conexão voltar.
/// Tela cheia mostrada enquanto abandona a vistoria guiada e cria a nova
/// em massa offline -- essa escrita específica pode demorar bem mais que
/// o normal neste tipo de cenário (já confirmado testando no aparelho).
/// Fica NA MESMA TELA em vez de navegar pra outro lugar, mostrando um
/// spinner de verdade em vez do "Preparando sessão..." genérico, que
/// parecia travado sem explicação nenhuma do que estava acontecendo.
class _ConvertingToOfflineBulkScreen extends StatefulWidget {
  final String placa;

  const _ConvertingToOfflineBulkScreen({required this.placa});

  @override
  State<_ConvertingToOfflineBulkScreen> createState() =>
      _ConvertingToOfflineBulkScreenState();
}

class _ConvertingToOfflineBulkScreenState
    extends State<_ConvertingToOfflineBulkScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      decoration: const BoxDecoration(color: Color(0xFFF3FBFF)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 116,
            height: 116,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7E6),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB45309).withOpacity(.18),
                  blurRadius: 28,
                  spreadRadius: 8,
                ),
              ],
            ),
            // Vira de cabeça pra baixo na metade de cada volta -- simula
            // a ampulheta sendo virada assim que a areia "acaba".
            child: Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final t = _controller.value;

                  return Transform.rotate(
                    angle: t * 2 * 3.14159265,
                    child: Icon(
                      t < 0.5
                          ? Icons.hourglass_top_rounded
                          : Icons.hourglass_bottom_rounded,
                      color: const Color(0xFFB45309),
                      size: 48,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 30),
          Text(
            'Convertendo vistoria',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.placa.isEmpty
                ? 'Abandonando o chat guiado e criando o envio em massa. '
                    'Isso pode levar alguns instantes.'
                : 'Abandonando o chat guiado de ${widget.placa} e criando '
                    'o envio em massa. Isso pode levar alguns instantes.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF414755),
              fontWeight: FontWeight.w700,
              fontSize: 15,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _BulkAwaitingSyncScreen extends StatelessWidget {
  final VistoriaSession session;
  final VoidCallback onBackToSelection;

  const _BulkAwaitingSyncScreen({
    required this.session,
    required this.onBackToSelection,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      decoration: const BoxDecoration(color: Color(0xFFF3FBFF)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 116,
              height: 116,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB45309).withOpacity(.18),
                    blurRadius: 28,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.lock_clock_rounded,
                  color: Color(0xFFB45309),
                  size: 56,
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              'Envio guardado no aparelho',
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                color: const Color(0xFF0F172A),
                fontWeight: FontWeight.w900,
                fontSize: 24,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Assim que a internet voltar, o envio é concluído sozinho. '
              'Pode continuar trabalhando normalmente.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF414755),
                fontWeight: FontWeight.w700,
                fontSize: 15,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 22),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 360),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFFBBF24)),
              ),
              child: Text(
                session.placa.isEmpty ? session.idvistoria : session.placa,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF0057C0),
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onBackToSelection,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0057C0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Ver outras vistorias',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool hasText;
  final bool isStartingRecording;
  final bool cameraUnlocked;
  final bool cameraPulsing;
  final VoidCallback onCameraTap;
  final VoidCallback onSendTap;
  final VoidCallback onMicTap;

  const _TextComposer({
    super.key,
    required this.controller,
    required this.hasText,
    required this.isStartingRecording,
    required this.cameraUnlocked,
    required this.cameraPulsing,
    required this.onCameraTap,
    required this.onSendTap,
    required this.onMicTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.96),
        border: Border(top: BorderSide(color: Colors.black.withOpacity(.05))),
      ),
      child: Row(
        children: [
          _CameraReleaseButton(
            unlocked: cameraUnlocked,
            pulsing: cameraPulsing,
            onTap: onCameraTap,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                if (hasText) onSendTap();
              },
              decoration: InputDecoration(
                hintText: 'Descreva os danos...',
                filled: true,
                fillColor: const Color(0xFFE5F6FF),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) {
              return ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: hasText
                ? _RoundActionButton(
                    key: const ValueKey('send'),
                    icon: Icons.send,
                    onTap: onSendTap,
                  )
                : _RoundActionButton(
                    key: const ValueKey('mic'),
                    icon: Icons.mic,
                    onTap: onMicTap,
                    isLoading: isStartingRecording,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Botão de câmera da barra de composição: travado (cinza, sem ação) até o
/// agente liberar a leva de fotos; ao liberar, acende um pulso discreto que
/// só apaga quando a câmera é aberta de fato (por aqui ou pela ação dentro
/// da própria bolha de chat que liberou — ver _AiBubble).
class _CameraReleaseButton extends StatefulWidget {
  final bool unlocked;
  final bool pulsing;
  final VoidCallback onTap;

  const _CameraReleaseButton({
    required this.unlocked,
    required this.pulsing,
    required this.onTap,
  });

  @override
  State<_CameraReleaseButton> createState() => _CameraReleaseButtonState();
}

class _CameraReleaseButtonState extends State<_CameraReleaseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _glow = Tween<double>(begin: .12, end: .5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _CameraReleaseButton oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.pulsing && !oldWidget.pulsing) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && oldWidget.pulsing) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.pulsing
                ? const Color(0xFF0057C0).withOpacity(_glow.value)
                : Colors.transparent,
          ),
          child: child,
        );
      },
      child: IconButton(
        onPressed: widget.unlocked ? widget.onTap : null,
        icon: Icon(
          widget.unlocked ? Icons.camera_alt : Icons.camera_alt_outlined,
        ),
        color: widget.unlocked ? const Color(0xFF0057C0) : null,
        disabledColor: const Color(0xFFB5C3D6),
        tooltip: widget.unlocked
            ? 'Anexar fotos'
            : 'A câmera libera quando o assistente pedir as fotos',
      ),
    );
  }
}

class _RecordingComposer extends StatelessWidget {
  final String duration;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  const _RecordingComposer({
    super.key,
    required this.duration,
    required this.onCancel,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.98),
        border: Border(top: BorderSide(color: Colors.black.withOpacity(.05))),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.delete_outline),
            color: Colors.redAccent,
          ),
          Expanded(
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE5F6FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.redAccent),
                  const SizedBox(width: 10),
                  Text(
                    duration,
                    style: const TextStyle(
                      color: Color(0xFF414755),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: _AnimatedAudioWaves()),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RoundActionButton(icon: Icons.send, onTap: onSend),
        ],
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isLoading;

  const _RoundActionButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0057C0),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: isLoading ? null : onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 21),
          ),
        ),
      ),
    );
  }
}

class _AnimatedAudioWaves extends StatefulWidget {
  const _AnimatedAudioWaves();

  @override
  State<_AnimatedAudioWaves> createState() => _AnimatedAudioWavesState();
}

class _AnimatedAudioWavesState extends State<_AnimatedAudioWaves>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const barCount = 18;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(barCount, (index) {
            final wave = sin((controller.value * 2 * pi) + index * .55);
            final normalized = (wave + 1) / 2;
            final height = 8 + normalized * 24;

            return Container(
              width: 3,
              height: height,
              decoration: BoxDecoration(
                color: const Color(0xFF0057C0).withOpacity(.75),
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        );
      },
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CircleAvatar(
          radius: 18,
          backgroundColor: Color(0xFF0057C0),
          child: Icon(Icons.smart_toy, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: const BoxDecoration(
            color: Color(0xFFE5F6FF),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(22),
              bottomLeft: Radius.circular(22),
              bottomRight: Radius.circular(22),
            ),
          ),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (index) {
                  final progress = (controller.value + (index * .18)) % 1;
                  final opacity = progress < .5
                      ? progress * 2
                      : (1 - progress) * 2;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(
                        0xFF0057C0,
                      ).withOpacity(.35 + (.65 * opacity)),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../orcamento/orcamento_calculo.dart';
import '../orcamento/orcamento_table_page.dart';
import 'bulk_upload_sheet.dart';
import 'eye_processing_animation.dart';

enum ChatMessageType { ai, user, photo, audio }

enum ContinueVistoriaAction { continueNow, continueLater, startNew }

/// Modo de coleta da vistoria: passo a passo (guiado) ou tudo de uma vez (em massa).
enum ColetaModo { guiado, emMassa }

/// Representa uma mensagem renderizada no chat (IA, usuário, foto ou áudio).
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

  /// Status visual do áudio no app (local, uploading, processing, transcribing, done ou error).
  final String? audioStatus;

  /// Horário em que a mensagem foi criada/exibida no chat.
  final DateTime? createdAt;

  /// true na mensagem que pergunta o modo de coleta, pra renderizar os botões inline na bolha.
  final bool isColetaModoPrompt;

  /// Modo escolhido pelo mecânico na pergunta bifurcada, registrado na própria bolha.
  final ColetaModo? selectedColetaModo;

  /// Envio da foto: null quando já subiu, [fotoReenviando] enquanto o app
  /// tenta de novo sozinho e [fotoFalhou] quando não dá para reenviar sem
  /// o mecânico (arquivo sumiu, sem permissão).
  final String? photoStatus;

  /// Cartão de resumo do orçamento (peça e valor de cada linha), mostrado
  /// junto da confirmação final. Não-nulo só nessa bolha.
  final List<MapEntry<String, double>>? orcamentoLinhas;
  final double? orcamentoTotal;

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
    this.photoStatus,
    this.orcamentoLinhas,
    this.orcamentoTotal,
  });

  static const fotoReenviando = 'reenviando';
  static const fotoFalhou = 'falhou';

  ChatMessage copyWith({
    String? text,
    ColetaModo? selectedColetaModo,
    String? photoStatus,
    bool limparPhotoStatus = false,
  }) {
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
      photoStatus:
          limparPhotoStatus ? null : (photoStatus ?? this.photoStatus),
      orcamentoLinhas: orcamentoLinhas,
      orcamentoTotal: orcamentoTotal,
    );
  }
}

/// Tela de chat/coleta de vistoria, guiada (com agente) ou em massa, incluindo retificação.
class AiChatPage extends StatefulWidget {
  /// ID do sinistro vinculado a esta vistoria.
  final String? sinistroId;

  /// Quando true, abre esta página já em fluxo de retificação de uma vistoria rejeitada.
  final bool startRetificacao;

  /// Índice da aba selecionada no MainShell; recarrega a lista de veículos ao reabrir esta aba.
  final ValueListenable<int>? selectedTabIndexListenable;

  /// Callback pra voltar a aba do MainShell para "Vistorias".
  final VoidCallback? onGoToInspections;

  const AiChatPage({
    super.key,
    this.sinistroId,
    this.startRetificacao = false,
    this.selectedTabIndexListenable,
    this.onGoToInspections,
  });

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

/// Orquestra bootstrap de sessão, envio de mensagens/fotos/áudio, modos online/offline e UI do chat.
class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final AudioRecorder audioRecorder = AudioRecorder();

  final List<ChatMessage> messages = [];

  VistoriaSession? currentSession;
  StreamSubscription<VistoriaChatCompletionState>?
      vistoriaCompletionSubscription;

  /// Assinatura que detecta quando o pacote em massa desta vistoria terminou de enviar.
  StreamSubscription<String>? _bulkSubmittedSubscription;

  List<SinistroVistoriaOption> availableSinistros = [];
  bool isLoadingSession = true;

  /// Trava de reentrância para `_bootstrapChatSession`.
  bool _isBootstrapping = false;
  bool isInspectionCompleted = false;
  String completedInspectionStatus = '';

  /// true quando concluiu antes do laudo técnico ficar pronto.
  bool completedLaudoPending = false;

  bool hasText = false;
  bool isRecording = false;
  bool isStartingRecording = false;
  bool isAiTyping = false;

  /// Modo de coleta escolhido para a vistoria atual; null até o mecânico decidir.
  ColetaModo? coletaModo;
  bool awaitingColetaModoChoice = false;
  bool isBulkProcessing = false;

  /// true após já ter oferecido trocar pra envio em massa nesta queda de conexão.
  bool _offlineGuidedPromptShown = false;

  /// true quando a vistoria guiada em aberto está bloqueada por falta de conexão.
  bool isBlockedOfflineGuidedHistory = false;

  /// true quando a retificação foi tentada offline; retificação não tem modo degradado.
  bool isBlockedOfflineRetificacao = false;

  /// true enquanto troca a vistoria guiada pela nova vistoria em massa offline.
  bool isConvertingToOfflineBulk = false;

  /// true quando o pacote em massa já foi confirmado offline e aguarda conexão para enviar.
  bool isAwaitingBulkSync = false;
  final ValueNotifier<String> bulkStatusText = ValueNotifier<String>(
    'Processando...',
  );

  /// Controla o travamento da câmera e o pulso visual de "recém-liberada".
  bool cameraUnlocked = false;
  bool cameraPulsing = false;
  bool autoOrcamentoOpenedForRelease = false;

  Timer? recordingTimer;
  int recordingSeconds = 0;
  String? currentRecordingPath;

  @override
  void initState() {
    super.initState();

    _falaPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _falaTexto = null);
    });

    messageController.addListener(() {
      final currentHasText = messageController.text.trim().isNotEmpty;

      if (currentHasText != hasText) {
        setState(() {
          hasText = currentHasText;
        });
      }
    });

    widget.selectedTabIndexListenable?.addListener(_onSelectedTabIndexChanged);

    _bulkSubmittedSubscription =
        BulkSyncCoordinator.instance.onPackageSubmitted.listen(
      _handleBulkPackageSubmitted,
    );

    ArgosConnectivityService.instance.isOnline.addListener(
      _handleConnectivityRestored,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bootstrapChatSession();
    });
  }

  @override
  void dispose() {
    _falaPlayer.dispose();
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

  /// Recarrega a lista de veículos quando esta aba fica visível, sem sessão em andamento.
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

    // "liberei a câmera" é o gatilho do agente ADK (ver Passo 4 em
    // adk_agents/vistoria_team/agent.py); a outra frase é a do antigo
    // playbook do Dialogflow, mantida para históricos já gravados.
    return normalized.contains('liberei a câmera') ||
        (normalized.contains('identificação recebida') &&
            normalized.contains('liberei') &&
            normalized.contains('fotos dos danos externos'));
  }

  bool _isOrcamentoReleaseText(String value) {
    final normalized = _normalizeMessage(value);

    return normalized.contains('liberei') &&
        normalized.contains('tela de orçamento');
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

  /// Destrava o botão de câmera e acende o pulso ao detectar a frase de liberação.
  void _openCameraAfterPhotoRelease(String text) {
    if (cameraUnlocked) return;
    if (!_isPhotoReleaseText(text)) return;

    setState(() {
      cameraUnlocked = true;
      cameraPulsing = true;
    });
  }

  bool _isResumoOrcamentoText(String value) {
    return _normalizeMessage(value).contains('total do orçamento');
  }

  /// Monta a bolha do cartão de resumo a partir do registro gravado no
  /// histórico (`role: orcamento_resumo`).
  ChatMessage? _resumoOrcamentoMessage(
    Map<String, dynamic> data, {
    DateTime? createdAt,
  }) {
    final itens = data['itens'];
    if (itens is! List || itens.isEmpty) return null;

    final linhas = [
      for (final item in itens.whereType<Map>())
        MapEntry(
          item['peca']?.toString() ?? '',
          (item['valor'] is num) ? (item['valor'] as num).toDouble() : 0.0,
        ),
    ];
    final total = data['total'];

    return ChatMessage(
      type: ChatMessageType.ai,
      text: '',
      orcamentoLinhas: linhas,
      orcamentoTotal: total is num
          ? total.toDouble()
          : linhas.fold<double>(0, (soma, linha) => soma + linha.value),
      createdAt: createdAt,
    );
  }

  /// Na confirmação final ("Total do orçamento: ..."), mostra acima dela o
  /// cartão com os itens que o agente acabou de salvar em
  /// `agentParameters.itens_orcamento`, para o mecânico conferir antes do
  /// "sim". Vale para o orçamento feito na conversa e na tabela.
  Future<void> _mostrarResumoOrcamento(String texto) async {
    final session = currentSession;
    if (session == null || !_isResumoOrcamentoText(texto)) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('vistorias')
          .doc(session.docId)
          .get();
      final params = doc.data()?['agentParameters'];
      if (params is! Map) return;

      final itens = params['itens_orcamento'];
      if (itens is! List || itens.isEmpty) return;

      double numero(dynamic v) =>
          v is num ? v.toDouble() : (parseValorDecimal('${v ?? ''}') ?? 0);

      final linhas = <Map<String, dynamic>>[];
      var soma = 0.0;
      for (final item in itens.whereType<Map>()) {
        final quantidade = max(1, numero(item['quantidade']).round());
        final valorHora = item['valor_hora'] == null
            ? kValorHoraLegado
            : numero(item['valor_hora']);
        final valor = numero(item['valor_peca']) * quantidade +
            numero(item['horas_mao_obra']) * valorHora;
        final peca = item['peca']?.toString().trim() ?? '';

        soma += valor;
        linhas.add({
          'peca': quantidade > 1 ? '$peca (x$quantidade)' : peca,
          'valor': valor,
        });
      }

      final totalAgente = params['valor_total_final'];
      final dados = <String, dynamic>{
        'itens': linhas,
        'total': totalAgente is num ? totalAgente.toDouble() : soma,
      };

      await VistoriaChatSessionService.instance.appendChatMessage(
        vistoriaDocId: session.docId,
        role: 'orcamento_resumo',
        text: '',
        extraData: dados,
      );

      final card = _resumoOrcamentoMessage(dados, createdAt: DateTime.now());
      if (!mounted || card == null) return;

      setState(() {
        final indice = messages.lastIndexWhere(
          (m) => m.type == ChatMessageType.ai && m.orcamentoLinhas == null,
        );
        if (indice >= 0) {
          messages.insert(indice, card);
        } else {
          messages.add(card);
        }
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('Erro ao montar o resumo do orçamento: $e');
    }
  }

  void _openOrcamentoAfterRelease(String text) {
    if (autoOrcamentoOpenedForRelease) return;
    if (!_isOrcamentoReleaseText(text)) return;

    autoOrcamentoOpenedForRelease = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || isInspectionCompleted) return;
      _openOrcamentoTable();
    });
  }

  void _listenToVistoriaCompletion(VistoriaSession session) {
    vistoriaCompletionSubscription?.cancel();
    vistoriaCompletionSubscription = VistoriaChatSessionService.instance
        .watchCompletionState(vistoriaDocId: session.docId)
        .listen(
      (completionState) {
        if (!completionState.isCompleted || isInspectionCompleted) return;

        _completeChatFromVistoriaUpdate(
          completionState.status,
          laudoPending: !completionState.hasAnalyticalReport,
        );
      },
      onError: (error) {
        debugPrint('Erro ao escutar conclusão da vistoria: $error');
      },
    );
  }

  Future<void> _completeChatFromVistoriaUpdate(
    String status, {
    bool laudoPending = false,
  }) async {
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
      completedLaudoPending = laudoPending;
      // No envio em massa o status muda antes do aviso do coordenador.
      isBulkProcessing = false;
      isAwaitingBulkSync = false;
      isAiTyping = false;
      isStartingRecording = false;
      hasText = false;
      messageController.clear();
    });
  }

  /// Inicializa a sessão de vistoria (direto por sinistro ou lista de seleção).
  Future<void> _bootstrapChatSession() async {
    if (_isBootstrapping) return;
    _isBootstrapping = true;

    setState(() {
      isLoadingSession = true;
    });

    try {
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
            const ChatMessage(
              type: ChatMessageType.ai,
              text: 'Não consegui preparar a sessão da vistoria. Verifique '
                  'a conexão e tente novamente.',
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
      completedLaudoPending = false;
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

  /// Pergunta o modo de coleta ao abrir uma vistoria nova, como mensagem do bot no chat.
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
                'Certo. Toque no botão "Enviar tudo de uma vez" abaixo para '
                'reunir fotos, áudio, observações e orçamento e enviar '
                'tudo junto.',
            createdAt: DateTime.now(),
          ),
        );
      });

      _scrollToBottom();
      return;
    }

    await _sendInitialOiToAgent();
  }

  /// Pergunta se o mecânico quer continuar montando o pacote em massa ou trocar pro guiado.
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
                  'Pacote ainda não enviado',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Você tinha começado a montar um pacote para $placa e ainda '
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
                  title: 'Continuar enviando tudo de uma vez',
                  subtitle: 'Volta para o botão de montar o pacote.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () =>
                      Navigator.of(dialogContext).pop(ColetaModo.emMassa),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.chat_bubble_rounded,
                  title: 'Mudar para o passo a passo',
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

  /// Confirma a troca do envio em massa para o passo a passo, mostrando o
  /// que já está montado no pacote.
  Future<bool> _confirmDiscardBulkPackage(VistoriaSession session) async {
    var fotos = 0;
    var audios = 0;
    var outros = 0;
    for (final item in session.envioEmMassaRascunho.values) {
      if (item is! Map || item['status'] == 'enviado') continue;
      switch (item['tipo']?.toString()) {
        case 'foto':
          fotos++;
        case 'audio':
          audios++;
        default:
          outros++;
      }
    }

    final partes = [
      if (fotos > 0) '$fotos foto${fotos > 1 ? 's' : ''}',
      if (audios > 0) '$audios áudio${audios > 1 ? 's' : ''}',
      if (outros > 0) '$outros outro${outros > 1 ? 's' : ''} item${outros > 1 ? 'ns' : ''}',
    ];
    if (partes.isEmpty) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Descartar o pacote?'),
        content: Text(
          'O pacote em montagem tem ${partes.join(', ')}. Ao mudar para o '
          'passo a passo, esse conteúdo não será enviado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Manter o pacote'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.deepOrange),
            child: const Text('Descartar e mudar'),
          ),
        ],
      ),
    );

    return result ?? false;
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
                  subtitle: 'Volta para o ponto exato onde você parou.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () => Navigator.of(context)
                      .pop(ContinueVistoriaAction.continueNow),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.schedule_rounded,
                  title: 'Continuar mais tarde',
                  subtitle: 'Fecha por agora, o progresso fica salvo.',
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

  /// Diálogo de vistoria expirada: só oferece continuar mais tarde ou começar nova.
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
                  title: 'Iniciar nova vistoria',
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
                  subtitle: 'Volta para a tela de vistorias por agora.',
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

  /// Confirma com o mecânico se quer abandonar a vistoria atual e começar outra.
  Future<bool> _confirmStartNewVistoria(VistoriaSession session) async {
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
                      Icons.restart_alt_rounded,
                      color: Color(0xFFB45309),
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Começar uma nova coleta?',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'A vistoria atual será marcada como abandonada. O '
                  'histórico não é apagado. Só o analista pode cancelar o '
                  'sinistro de verdade.',
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
                  icon: Icons.restart_alt_rounded,
                  title: 'Abandonar e iniciar nova',
                  subtitle: 'Começa agora. Não cancela o sinistro.',
                  color: Colors.deepOrange,
                  filled: true,
                  onTap: () => Navigator.of(dialogContext).pop(true),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.close_rounded,
                  title: 'Cancelar',
                  subtitle: 'Continua na vistoria atual.',
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

      if (!ArgosConnectivityService.instance.isOnline.value) {
        await _startVistoriaOffline(sinistroId, openSession);
        return;
      }

      if (openSession != null) {
        setState(() {
          isLoadingSession = false;
        });

        final alreadyExpired = await ArgosAiService.instance
            .checkVistoriaExpiration(idvistoria: openSession.docId);

        if (!mounted) return;

        if (!alreadyExpired && openSession.isEmMassa) {
          // Pacote vazio: não há o que decidir, segue no envio em massa.
          final temPacote = openSession.envioEmMassaRascunho.values
              .any((item) => item is Map && item['status'] != 'enviado');
          var resumeChoice = temPacote
              ? await _askResumeBulkMode(openSession)
              : ColetaModo.emMassa;

          if (!mounted) return;

          if (resumeChoice == ColetaModo.guiado &&
              !await _confirmDiscardBulkPackage(openSession)) {
            if (!mounted) return;
            resumeChoice = ColetaModo.emMassa;
          }

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
            setState(() {
              isLoadingSession = true;
            });
          } else {
            final confirmed = await _confirmStartNewVistoria(openSession);

            if (!mounted) return;

            if (!confirmed) {
              setState(() {
                _loadSessionIntoChat(openSession);
                isLoadingSession = false;
              });
              _scrollToBottom();
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
            const ChatMessage(
              type: ChatMessageType.ai,
              text: 'Não foi possível iniciar a vistoria. Verifique se o '
                  'veículo possui check-in e tente novamente.',
            ),
          );
      });
    }
  }

  /// Ramo offline de `_startVistoriaFromSinistro`: bloqueia histórico guiado em aberto,
  /// permite continuar/criar vistoria em massa.
  Future<void> _startVistoriaOffline(
    String sinistroId,
    VistoriaSession? openSession,
  ) async {
    if (openSession != null && !openSession.isEmMassa) {
      final wantsAbandon =
          await _askAbandonGuidedAndStartOfflineBulk(openSession);

      if (!mounted) return;

      if (wantsAbandon) {
        final switched = await _abandonGuidedAndSwitchToOfflineBulk(
          openSession: openSession,
          sinistroId: sinistroId,
        );

        if (switched) return;
      }

      setState(() {
        currentSession = openSession;
        isLoadingSession = false;
        isBlockedOfflineGuidedHistory = true;
        messages
          ..clear()
          ..add(
            ChatMessage(
              type: ChatMessageType.ai,
              text: 'Esta vistoria foi iniciada no passo a passo, que '
                  'depende de internet para funcionar. Conecte-se para '
                  'continuar de onde parou.',
            ),
          );
      });

      return;
    }

    setState(() => isBlockedOfflineGuidedHistory = false);

    if (openSession != null) {
      setState(() {
        coletaModo = ColetaModo.emMassa;
        _loadSessionIntoChat(openSession);
        isAwaitingBulkSync = openSession.envioEmMassaConfirmadoOffline;
        isLoadingSession = false;
      });

      _scrollToBottom();
      return;
    }

    await _createFreshOfflineVistoria(sinistroId);
  }

  /// Oferece abandonar a vistoria guiada em aberto e começar uma nova em massa offline.
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
                  'Passo a passo — sem rede',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'O passo a passo precisa de internet. Offline, só é possível '
                  'continuar enviando tudo de uma vez.',
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
                  title: 'Abandonar e enviar tudo de uma vez',
                  subtitle: 'Começa agora. Não cancela o sinistro.',
                  color: Colors.deepOrange,
                  filled: true,
                  onTap: () => Navigator.of(dialogContext).pop(true),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.schedule_rounded,
                  title: 'Esperar conexão',
                  subtitle: 'Continua o passo a passo quando a rede voltar.',
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

  /// Abandona a vistoria guiada e cria uma nova em massa offline; retorna se trocou com sucesso.
  Future<bool> _abandonGuidedAndSwitchToOfflineBulk({
    required VistoriaSession openSession,
    required String sinistroId,
  }) async {
    setState(() {
      isLoadingSession = false;
      isConvertingToOfflineBulk = true;
      currentSession = openSession;
    });

    try {
      final session = await Future.wait([
        VistoriaChatSessionService.instance.createVistoriaOffline(
          sinistroId: sinistroId,
        ),
        Future<void>.delayed(const Duration(seconds: 15)),
      ]).then((results) => results.first as VistoriaSession);

      if (!mounted) return true;

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

      return true;
    } catch (e) {
      debugPrint('Abandonar+criar offline falhou: $e');

      if (!mounted) return false;

      setState(() => isConvertingToOfflineBulk = false);

      _showSnack(
        'Isso está demorando mais que o esperado. Tente de novo em '
        'alguns segundos.',
        backgroundColor: Colors.orange,
      );

      return false;
    }
  }

  /// Oferece abandonar o chat guiado ou esperar a conexão, ao tentar enviar algo offline.
  Future<void> _handleOfflineDuringGuidedChat() async {
    final session = currentSession;
    if (session == null || _offlineGuidedPromptShown) return;

    _offlineGuidedPromptShown = true;

    final wantsAbandon = await _askAbandonGuidedAndStartOfflineBulk(session);

    if (!mounted) return;

    if (!wantsAbandon) return;

    await _abandonGuidedAndSwitchToOfflineBulk(
      openSession: session,
      sinistroId: session.sinistroId,
    );
  }

  /// Cria uma vistoria do zero offline, já em modo em massa, e carrega na tela.
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

  /// Sempre cria a vistoria de retificação a partir da rejeitada do sinistro.
  Future<void> _startRetificacaoFromSinistro(String sinistroId) async {
    if (!ArgosConnectivityService.instance.isOnline.value) {
      setState(() {
        currentSession = VistoriaSession(
          docId: '',
          idvistoria: '',
          sinistroId: sinistroId,
          placa: '',
          veiculo: '',
          cliente: '',
          credenciado: '',
          status: '',
          tipoVistoria: '',
          vistoriaOrigemId: '',
          ajustesNecessarios: '',
          contextoVistoriaAnterior: '',
          chatMessages: const [],
        );
        isLoadingSession = false;
        isBlockedOfflineRetificacao = true;
        messages
          ..clear()
          ..add(
            const ChatMessage(
              type: ChatMessageType.ai,
              text: 'A retificação precisa de internet para funcionar. Por '
                  'ser um processo mais delicado, não tem um modo offline '
                  'alternativo. Conecte-se para continuar.',
            ),
          );
      });
      return;
    }

    isBlockedOfflineRetificacao = false;

    setState(() {
      isLoadingSession = true;
    });

    try {
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
              setState(() {
                _loadSessionIntoChat(openSession);
                isLoadingSession = false;
              });
              _scrollToBottom();
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
            const ChatMessage(
              type: ChatMessageType.ai,
              text: 'Não foi possível iniciar a retificação. Verifique a '
                  'conexão e tente novamente.',
            ),
          );
      });
    }
  }

  /// Cria a retificação; se `discardedOrigemId` vier preenchido, busca a vistoria
  /// rejeitada original por id em vez de reler o ponteiro do sinistro.
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
      _openOrcamentoAfterRelease(reply);
      unawaited(_mostrarResumoOrcamento(reply));
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
    completedLaudoPending = false;
    cameraUnlocked = session.isRetificacao;
    cameraPulsing = false;
    autoOrcamentoOpenedForRelease = false;
    _listenToVistoriaCompletion(session);

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
      if (message == null) continue;

      // O resumo é gravado depois da confirmação do Argos, mas aparece
      // acima dela, como na hora em que foi mostrado.
      if (message.orcamentoLinhas != null &&
          loadedMessages.isNotEmpty &&
          loadedMessages.last.type == ChatMessageType.ai) {
        loadedMessages.insert(loadedMessages.length - 1, message);
      } else {
        loadedMessages.add(message);
      }
    }

    messages
      ..clear()
      ..addAll(loadedMessages);

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
              'Vistoria iniciada para ${session.placa.isEmpty ? 'o veículo sem placa' : 'a placa ${session.placa}'}. Vamos começar.',
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

    if (role == 'orcamento_resumo') {
      return _resumoOrcamentoMessage(data, createdAt: createdAt);
    }

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
    if (!ArgosConnectivityService.instance.isOnline.value) {
      final shouldContinueOffline = await _askOfflineEntryChoice();

      if (!mounted) return;

      if (!shouldContinueOffline) {
        widget.onGoToInspections?.call();
        return;
      }
    }

    if (option.isRetificacaoPendente) {
      await _startRetificacaoFromSinistro(option.sinistroId);
      return;
    }
    await _startVistoriaFromSinistro(option.sinistroId);
  }

  /// Pergunta, ao tocar num veículo offline, se o mecânico quer seguir com envio em massa.
  Future<bool> _askOfflineEntryChoice() async {
    final choice = await showDialog<bool>(
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
                  'Você está offline',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'O passo a passo com o agente precisa de internet para '
                  'funcionar. Sem conexão, só é possível trabalhar '
                  'enviando tudo de uma vez.',
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
                  title: 'Continuar offline',
                  subtitle: 'Envia tudo de uma vez enquanto a rede não volta.',
                  color: const Color(0xFF0057C0),
                  filled: true,
                  onTap: () => Navigator.of(dialogContext).pop(true),
                ),
                const SizedBox(height: 10),
                _VistoriaActionTile(
                  icon: Icons.arrow_back_rounded,
                  title: 'Continuar mais tarde',
                  subtitle: 'Volta para a tela principal e espera a internet.',
                  color: const Color(0xFF6B7280),
                  onTap: () => Navigator.of(dialogContext).pop(false),
                ),
              ],
            ),
          ),
        );
      },
    );

    return choice ?? false;
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

    if (!ArgosConnectivityService.instance.isOnline.value) {
      if (_offlineGuidedPromptShown) {
        _showSnack(
          'Isso precisa de internet. Sua mensagem não foi enviada.',
          backgroundColor: Colors.orange,
        );
      } else {
        await _handleOfflineDuringGuidedChat();
      }
      return;
    }

    final userMessage = ChatMessage(
      type: ChatMessageType.user,
      text: text,
      createdAt: DateTime.now(),
    );

    setState(() {
      messages.add(userMessage);

      messageController.clear();
      hasText = false;
      isAiTyping = true;
    });

    _scrollToBottom();

    try {
      if (isInspectionCompleted) return;

      final reply = await ArgosAiService.instance.sendMessage(
        text: text,
        inspectionId: session.idvistoria,
        isRetificacao: session.isRetificacao,
        ajustesNecessarios: session.ajustesNecessarios,
        contextoVistoriaAnterior: session.contextoVistoriaAnterior,
      );

      // Grava a mensagem do mecânico só depois que o Argos respondeu: se o
      // envio falhar, ela volta para o campo de texto em vez de ficar no
      // histórico sem resposta.
      await VistoriaChatSessionService.instance.appendUserMessage(
        vistoriaDocId: session.docId,
        text: text,
      );

      // A tela pode concluir antes da resposta chegar (status mudou pra
      // análise); grava a resposta final no histórico mesmo assim.
      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: reply,
      );

      if (isInspectionCompleted) return;

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(_aiMessageFromText(reply, createdAt: DateTime.now()));
      });

      _openCameraAfterPhotoRelease(reply);
      _openOrcamentoAfterRelease(reply);
      unawaited(_mostrarResumoOrcamento(reply));
      _scrollToBottom();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('ERRO CLOUD FUNCTION');
      debugPrint('code: ${e.code}');
      debugPrint('message: ${e.message}');
      debugPrint('details: ${e.details}');

      if (!mounted) return;
      _devolverMensagemNaoEnviada(userMessage, text);
    } catch (e) {
      debugPrint('ERRO GERAL CHAT IA: $e');

      if (!mounted) return;
      _devolverMensagemNaoEnviada(userMessage, text);
    }
  }

  /// O Argos não respondeu: tira a bolha, devolve o texto para o campo e
  /// avisa. Nada é gravado no histórico da vistoria.
  void _devolverMensagemNaoEnviada(ChatMessage userMessage, String text) {
    setState(() {
      isAiTyping = false;
      messages.remove(userMessage);
      if (messageController.text.trim().isEmpty) {
        messageController.text = text;
        hasText = true;
      }
    });

    _showSnack(
      'O Argos não respondeu agora. Sua mensagem voltou para o campo de '
      'texto; toque em enviar para tentar de novo.',
    );
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

    if (!ArgosConnectivityService.instance.isOnline.value) {
      if (_offlineGuidedPromptShown) {
        _showSnack(
          'Isso precisa de internet para anexar fotos.',
          backgroundColor: Colors.orange,
        );
      } else {
        await _handleOfflineDuringGuidedChat();
      }
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

    await _enviarFotos(session, photos.map((p) => p.path).toList());
  }

  /// Etapas já concluídas de cada foto que ainda não terminou de subir
  /// (chave: caminho local). Num reenvio, só a etapa que falhou é refeita:
  /// a foto não sobe de novo nem entra duas vezes em `images`.
  final Map<String, _EnvioFoto> _enviosFoto = {};

  /// Fotos com reenvio automático em andamento, pra não abrir dois laços.
  final Set<String> _fotosEmReenvio = {};

  /// Texto da bolha de "digitando" enquanto as fotos sobem e são analisadas
  /// (null = só os pontinhos). O aviso do agente só chega com a resposta
  /// inteira, então o app avisa por conta própria.
  String? _statusFotos;

  /// Sobe as fotos, mostra cada uma no chat e avisa o Argos das que subiram.
  /// As que falharem ficam no chat como "Enviando de novo…" e o app tenta
  /// sozinho até conseguir (ver [_reenviarFotosSozinho]).
  Future<void> _enviarFotos(VistoriaSession session, List<String> paths) async {
    setState(() {
      for (final path in paths) {
        messages.add(
          ChatMessage(
            type: ChatMessageType.photo,
            text: 'Foto anexada à vistoria',
            imagePath: path,
            createdAt: DateTime.now(),
          ),
        );
      }
    });

    final plural = paths.length > 1 ? 's' : '';
    setState(() {
      isAiTyping = true;
      _statusFotos = 'Enviando ${paths.length} foto$plural…';
    });
    _scrollToBottom();

    var uploadedCount = 0;
    final failedPaths = <String>[];

    // Sobe a leva em paralelo: em série, cada foto esperava a anterior.
    await Future.wait(paths.map((path) async {
      try {
        await _enviarUmaFoto(session, path);
        uploadedCount++;
      } catch (e) {
        debugPrint('Erro ao salvar foto da vistoria no Storage: $e');
        if (_falhaSemReenvio(e)) {
          _marcarFoto(path, ChatMessage.fotoFalhou);
        } else {
          failedPaths.add(path);
        }
      }
    }));

    if (uploadedCount == 0 && mounted) {
      setState(() {
        isAiTyping = false;
        _statusFotos = null;
      });
    }

    if (failedPaths.isNotEmpty && mounted) {
      for (final path in failedPaths) {
        _marcarFoto(path, ChatMessage.fotoReenviando);
      }
      final failed = failedPaths.length;
      _showSnack(
        failed == 1
            ? 'Uma foto não subiu. O app vai tentar de novo sozinho.'
            : '$failed fotos não subiram. O app vai tentar de novo sozinho.',
        backgroundColor: Colors.orange,
      );
      unawaited(_reenviarFotosSozinho(session, failedPaths));
    }

    if (uploadedCount == 0) return;

    await _analyzePhotosWithAgent(session: session, quantity: uploadedCount);
  }

  /// Sobe uma foto e grava a evidência e a bolha no histórico, pulando as
  /// etapas que já deram certo numa tentativa anterior.
  Future<void> _enviarUmaFoto(VistoriaSession session, String path) async {
    final service = VistoriaChatSessionService.instance;
    final envio = _enviosFoto.putIfAbsent(path, () => _EnvioFoto());

    final uploadedImage = envio.upload ??= await service.uploadImageFile(
      vistoriaDocId: session.docId,
      imagePath: path,
    );

    if (!envio.evidenciaGravada) {
      await service.appendImageEvidence(
        vistoriaDocId: session.docId,
        imageUrl: uploadedImage.downloadUrl,
        imagePath: path,
        imageId: uploadedImage.imageId,
        storagePath: uploadedImage.storagePath,
        fileName: uploadedImage.fileName,
        contentType: uploadedImage.contentType,
        sizeBytes: uploadedImage.sizeBytes,
      );
      envio.evidenciaGravada = true;
    }

    await service.appendChatMessage(
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

    _enviosFoto.remove(path);
  }

  /// Erros que não se resolvem tentando de novo: o arquivo sumiu do
  /// aparelho ou as regras recusaram (ex. vistoria fechada).
  bool _falhaSemReenvio(Object e) {
    if (e is FileSystemException) return true;
    if (e is FirebaseException) {
      return e.code == 'unauthorized' || e.code == 'permission-denied';
    }
    return false;
  }

  /// Tenta de novo as fotos que não subiram enquanto o chat estiver aberto:
  /// espera a internet voltar e aumenta o intervalo a cada rodada (até 30 s).
  /// A cada rodada que sobe alguma foto, avisa o Argos.
  Future<void> _reenviarFotosSozinho(
    VistoriaSession session,
    List<String> paths,
  ) async {
    // Só as que ainda não estão num laço de reenvio.
    final aceitas = paths.where(_fotosEmReenvio.add).toList();
    var pendentes = aceitas;
    var espera = const Duration(seconds: 3);

    try {
      while (pendentes.isNotEmpty && mounted && !isInspectionCompleted) {
        await Future<void>.delayed(espera);
        await _aguardarInternet();
        if (!mounted || isInspectionCompleted) return;

        var enviadas = 0;
        final aindaPendentes = <String>[];

        for (final path in pendentes) {
          try {
            await _enviarUmaFoto(session, path);
            enviadas++;
            _marcarFoto(path, null);
          } catch (e) {
            debugPrint('Reenvio da foto falhou: $e');
            if (_falhaSemReenvio(e)) {
              _marcarFoto(path, ChatMessage.fotoFalhou);
            } else {
              aindaPendentes.add(path);
            }
          }
        }

        pendentes = aindaPendentes;
        espera = Duration(seconds: min(espera.inSeconds * 2, 30));

        if (enviadas > 0 && mounted) {
          await _analyzePhotosWithAgent(session: session, quantity: enviadas);
        }
      }
    } finally {
      _fotosEmReenvio.removeAll(aceitas);
    }
  }

  /// Volta logo se houver internet; senão espera o [ArgosConnectivityService]
  /// avisar que ela voltou.
  Future<void> _aguardarInternet() async {
    final online = ArgosConnectivityService.instance.isOnline;
    if (online.value) return;

    final voltou = Completer<void>();
    void ouvir() {
      if (online.value && !voltou.isCompleted) voltou.complete();
    }

    online.addListener(ouvir);
    try {
      await voltou.future;
    } finally {
      online.removeListener(ouvir);
    }
  }

  /// Atualiza o estado de envio na bolha da foto (null = enviada).
  void _marcarFoto(String path, String? status) {
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (m.type == ChatMessageType.photo && m.imagePath == path) {
          messages[i] = status == null
              ? m.copyWith(limparPhotoStatus: true)
              : m.copyWith(photoStatus: status);
        }
      }
    });
  }

  /// Toque na foto que falhou de vez: tenta mais uma rodada de reenvio.
  void _tentarFotoDeNovo(String path) {
    final session = currentSession;
    if (session == null || isInspectionCompleted) return;
    _marcarFoto(path, ChatMessage.fotoReenviando);
    unawaited(_reenviarFotosSozinho(session, [path]));
  }

  /// Avisa o agente que a leva de fotos subiu e mostra a resposta dele no chat.
  Future<void> _analyzePhotosWithAgent({
    required VistoriaSession session,
    required int quantity,
  }) async {
    if (!mounted) return;

    final plural = quantity > 1 ? 's' : '';
    setState(() {
      isAiTyping = true;
      _statusFotos =
          'Analisando $quantity foto$plural. Isso leva cerca de 1 minuto…';
    });
    _scrollToBottom();

    final fallback =
        '$quantity foto$plural recebida$plural. Essas evidências foram vinculadas à vistoria.';

    // A análise das fotos (visão + consistência) leva perto de 1 minuto.
    // O servidor grava a resposta no histórico com este id; se a conexão do
    // celular cair antes, o app espera a resposta aparecer lá.
    final turnoId = 'fotos_${DateTime.now().millisecondsSinceEpoch}';

    String reply;
    try {
      reply = (await ArgosAiService.instance.sendBackgroundMessage(
        text: 'Fotos enviadas ($quantity).',
        inspectionId: session.idvistoria,
        isRetificacao: session.isRetificacao,
        ajustesNecessarios: session.ajustesNecessarios,
        contextoVistoriaAnterior: session.contextoVistoriaAnterior,
        persistirResposta: true,
        turnoId: turnoId,
      ))
          .trim();
    } catch (e) {
      debugPrint('Erro ao notificar envio de fotos para IA: $e');
      await _aguardarAnaliseDasFotos(session, turnoId);
      return;
    }

    // Resposta vazia: o servidor não gravou nada, então o app registra o
    // texto factual. Com resposta, ela já está no histórico (servidor).
    if (reply.isEmpty) {
      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: fallback,
      );
    }

    _mostrarRespostaDoArgos(reply.isEmpty ? fallback : reply);
  }

  // ── Ouvir mensagens do Argos (Text-to-Speech, ver functions/fala_argos.js)
  final AudioPlayer _falaPlayer = AudioPlayer();
  final Map<String, Uint8List> _falaCache = {};
  String? _falaTexto;
  bool _falaCarregando = false;

  /// Toca a mensagem em voz; se ela já estiver tocando, para.
  Future<void> _alternarFala(String texto) async {
    if (_falaTexto == texto) {
      await _falaPlayer.stop();
      if (mounted) setState(() => _falaTexto = null);
      return;
    }

    await _falaPlayer.stop();
    setState(() {
      _falaTexto = texto;
      _falaCarregando = true;
    });

    try {
      var audio = _falaCache[texto];
      if (audio == null) {
        final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('falarMensagemArgos')
            .call<Map<String, dynamic>>({'texto': texto});
        audio = base64Decode(result.data['audio'].toString());
        _falaCache[texto] = audio;
      }

      if (!mounted || _falaTexto != texto) return;
      await _falaPlayer.play(BytesSource(audio, mimeType: 'audio/mpeg'));
    } catch (e) {
      debugPrint('Erro ao ouvir mensagem: $e');
      if (mounted) {
        setState(() => _falaTexto = null);
        _showSnack('Não foi possível tocar a mensagem agora.');
      }
    } finally {
      if (mounted) setState(() => _falaCarregando = false);
    }
  }

  /// Mostra uma resposta do Argos no chat e aplica os gatilhos de câmera e
  /// orçamento que ela possa trazer.
  void _mostrarRespostaDoArgos(String texto) {
    if (!mounted) return;

    setState(() {
      isAiTyping = false;
      _statusFotos = null;
      messages.add(_aiMessageFromText(texto, createdAt: DateTime.now()));
    });

    _openCameraAfterPhotoRelease(texto);
    _openOrcamentoAfterRelease(texto);
    unawaited(_mostrarResumoOrcamento(texto));
    _scrollToBottom();
  }

  /// A conexão caiu durante a análise das fotos: o agente continua
  /// trabalhando no servidor, que grava a resposta no histórico. Espera ela
  /// aparecer (até 5 min) em vez de mostrar uma confirmação falsa.
  Future<void> _aguardarAnaliseDasFotos(
    VistoriaSession session,
    String turnoId,
  ) async {
    if (!mounted) return;

    setState(() {
      isAiTyping = false;
      _statusFotos = null;
      messages.add(
        _aiMessageFromText(
          'Recebi as fotos. A análise está levando mais tempo; a resposta '
          'aparece aqui em instantes.',
          createdAt: DateTime.now(),
        ),
      );
    });
    _scrollToBottom();

    try {
      final resposta = await FirebaseFirestore.instance
          .collection('vistorias')
          .doc(session.docId)
          .snapshots()
          .map((doc) {
            final lista = doc.data()?['chatmessages'];
            if (lista is! List) return null;
            for (final item in lista.reversed) {
              if (item is Map && item['turnoId'] == turnoId) {
                return item['text']?.toString();
              }
            }
            return null;
          })
          .where((texto) => texto != null && texto.trim().isNotEmpty)
          .first
          .timeout(const Duration(minutes: 5));

      _mostrarRespostaDoArgos(resposta!.trim());
    } catch (e) {
      debugPrint('Análise das fotos não chegou: $e');
      _showSnack(
        'A análise das fotos não chegou. Envie uma mensagem para continuar.',
        backgroundColor: Colors.orange,
      );
    }
  }

  /// Refaz o bootstrap quando a conexão volta, pra sair dos estados bloqueados offline.
  void _handleConnectivityRestored() {
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    _offlineGuidedPromptShown = false;

    if (isBlockedOfflineGuidedHistory || isBlockedOfflineRetificacao) {
      unawaited(_bootstrapChatSession());
    }
  }

  /// Reage ao fim do envio de um pacote em massa, se for o desta tela.
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
      completedLaudoPending = true;
    });
  }

  Future<void> _openBulkUploadSheet() async {
    if (isInspectionCompleted || isBulkProcessing) return;

    final session = currentSession;

    if (session == null) return;

    FocusScope.of(context).unfocus();

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

  /// Envia o pacote em massa via `BulkSyncCoordinator`, que sobrevive à troca de tela.
  Future<void> _submitBulkPackage({
    required VistoriaSession session,
    required BulkUploadResult result,
  }) async {
    if (!ArgosConnectivityService.instance.isOnline.value) {
      setState(() => isAwaitingBulkSync = true);

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

    // A sincronização em segundo plano já está enviando esta vistoria: o
    // submitPackage retornaria sem fazer nada e o overlay ficaria preso se
    // aquela tentativa falhasse. A tela troca sozinha quando ela concluir.
    if (BulkSyncCoordinator.instance.syncingVistoriaIds.value
        .contains(session.docId)) {
      _showSnack(
        'O envio desta vistoria já está em andamento. Aguarde a conclusão.',
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
    } on BulkUploadIncompleteException catch (e) {
      debugPrint('Pacote em massa incompleto: $e');

      if (!mounted) return;

      setState(() => isBulkProcessing = false);

      _showSnack(
        'Não foi possível enviar ${_describeFailedEvidence(e)}. O pacote '
        'continua salvo; tente novamente.',
        backgroundColor: Colors.redAccent,
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

  /// Monta "2 fotos e 1 áudio" a partir das falhas do pacote em massa.
  String _describeFailedEvidence(BulkUploadIncompleteException e) {
    final parts = <String>[
      if (e.failedPhotos > 0)
        '${e.failedPhotos} foto${e.failedPhotos > 1 ? 's' : ''}',
      if (e.failedAudios > 0)
        '${e.failedAudios} áudio${e.failedAudios > 1 ? 's' : ''}',
    ];

    return parts.join(' e ');
  }

  Future<void> _openOrcamentoTable() async {
    final session = currentSession;

    if (isInspectionCompleted || session == null) return;

    FocusScope.of(context).unfocus();

    List<Map<String, dynamic>> rascunho = [];

    try {
      rascunho = await VistoriaChatSessionService.instance
          .loadOrcamentoRascunho(vistoriaDocId: session.docId);
    } catch (e) {
      debugPrint('Erro ao carregar rascunho de orçamento: $e');
    }

    if (!mounted) return;

    final itensIniciais = rascunho.map(OrcamentoItemDraft.fromMap).toList();

    final result = await Navigator.of(context).push<List<Map<String, dynamic>>?>(
      MaterialPageRoute(
        builder: (_) => OrcamentoTablePage(
          itensIniciais: itensIniciais,
          modeloVeiculo: session.veiculo,
          vistoriaDocId: session.docId,
        ),
      ),
    );

    // Fechou sem enviar: libera pra tabela reabrir na próxima vez que o
    // agente pedir.
    if (result == null || result.isEmpty) {
      autoOrcamentoOpenedForRelease = false;
      return;
    }
    if (!mounted) return;

    try {
      await VistoriaChatSessionService.instance.submitOrcamento(
        vistoriaDocId: session.docId,
        itens: result,
      );

      // Se o mecânico pedir correção na confirmação final, o agente libera a
      // tabela de novo — sem isso ela só abriria uma vez por sessão.
      autoOrcamentoOpenedForRelease = false;

      if (!mounted) return;

      setState(() {
        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: 'Orçamento enviado: ${result.length} '
                'ite${result.length > 1 ? 'ns' : 'm'}, total de '
                '${formatCurrencyBRL(somarItensOrcamento(result))}.',
            createdAt: DateTime.now(),
          ),
        );
      });

      _scrollToBottom();

      unawaited(_notifyOrcamentoSentInBackground(session.idvistoria));
    } catch (e) {
      debugPrint('Erro ao enviar orçamento: $e');

      _showSnack(
        'Não foi possível enviar o orçamento. Tente novamente.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  Future<void> _notifyOrcamentoSentInBackground(String inspectionId) async {
    try {
      await ArgosAiService.instance.sendBackgroundMessage(
        text: 'enviei o orçamento',
        inspectionId: inspectionId,
      );
    } catch (e) {
      debugPrint('Erro ao notificar envio de orçamento para IA: $e');
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

    if (!ArgosConnectivityService.instance.isOnline.value) {
      if (_offlineGuidedPromptShown) {
        _showSnack(
          'Isso precisa de internet para gravar áudio.',
          backgroundColor: Colors.orange,
        );
      } else {
        await _handleOfflineDuringGuidedChat();
      }
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isStartingRecording = true;
    });

    try {
      final hasPermission = await audioRecorder.hasPermission();

      if (!hasPermission) {
        if (mounted) await showMicrophonePermissionDialog(context);
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
      _openOrcamentoAfterRelease(audioResult.reply);
      unawaited(_mostrarResumoOrcamento(audioResult.reply));
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
            text: 'Recebi o áudio, mas não consegui transcrever agora. '
                'Tente novamente em instantes.',
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

  /// Monta a área de composição: oculta, botão de envio em massa ou composer de texto/áudio.
  Widget _buildComposerArea(String duration) {
    if (awaitingColetaModoChoice ||
        isBlockedOfflineGuidedHistory ||
        isBlockedOfflineRetificacao) {
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
                          laudoPending: completedLaudoPending,
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
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: _TypingBubble(status: _statusFotos),
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
                                acaoOuvir: message.type == ChatMessageType.ai &&
                                        message.orcamentoLinhas == null
                                    ? _BotaoOuvir(
                                        tocando: _falaTexto == message.text,
                                        carregando: _falaCarregando &&
                                            _falaTexto == message.text,
                                        onTap: () =>
                                            _alternarFala(message.text),
                                      )
                                    : null,
                                onOpenCamera:
                                    isCameraReleaseMessage ? _openCamera : null,
                                onRetryPhoto: message.photoStatus ==
                                            ChatMessage.fotoFalhou &&
                                        message.imagePath != null
                                    ? () =>
                                        _tentarFotoDeNovo(message.imagePath!)
                                    : null,
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

/// Spinner centralizado mostrado enquanto a sessão de chat carrega.
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

/// Tela de conclusão mostrada quando a vistoria já foi finalizada/analisada.
class _InspectionCompletedView extends StatefulWidget {
  final VistoriaSession session;
  final String status;
  final VoidCallback onBackToSelection;

  /// true se o laudo técnico ainda não foi gerado ao concluir.
  final bool laudoPending;

  const _InspectionCompletedView({
    required this.session,
    required this.status,
    required this.onBackToSelection,
    this.laudoPending = false,
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

  /// Traduz o status cru do Firestore para um texto amigável ao mecânico.
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
            'Vistoria concluída',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
              fontSize: 26,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Aguarde a próxima etapa.',
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
                if (widget.laudoPending) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'O laudo técnico está sendo gerado.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
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

/// Lista de veículos com busca, pra escolher qual sinistro iniciar/retomar.
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
                          width: 44,
                          height: 44,
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
                            ? 'Nenhum veículo com check-in. Faça o check-in do sinistro na aba Vistorias para começar.'
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

/// Linha com ícone, rótulo e valor, usada nos cards de resumo da vistoria.
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

/// Tile tocável com ícone, título e subtítulo, usado nos diálogos de ação da vistoria.
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

/// Banner fixo no topo do chat de retificação com o que o analista pediu pra corrigir.
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

/// Cabeçalho do chat com número da vistoria, placa e botão de fechar.
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

    final subtitle = [
      if (placa.isNotEmpty) placa,
      if (idvistoria.isNotEmpty) idvistoria,
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

/// Decide, pelo tipo da mensagem, qual bolha renderizar (IA, usuário, foto ou áudio).
class _ChatBubble extends StatelessWidget {
  final ChatMessage message;

  /// Não-nulo apenas na bolha que liberou a câmera.
  final VoidCallback? onOpenCamera;

  /// Não-nulo apenas na bolha da pergunta bifurcada, pra renderizar os botões inline.
  final void Function(ColetaModo)? onChooseColetaModo;

  /// Botão de ouvir a mensagem (Text-to-Speech, em toda fala do Argos).
  final Widget? acaoOuvir;

  /// Não-nulo apenas na foto que não deu para reenviar sozinho.
  final VoidCallback? onRetryPhoto;

  const _ChatBubble({
    required this.message,
    this.onOpenCamera,
    this.onChooseColetaModo,
    this.acaoOuvir,
    this.onRetryPhoto,
  });

  @override
  Widget build(BuildContext context) {
    switch (message.type) {
      case ChatMessageType.ai:
        final linhas = message.orcamentoLinhas;
        if (linhas != null) {
          return _OrcamentoResumoBubble(
            linhas: linhas,
            total: message.orcamentoTotal ?? 0,
          );
        }
        return _AiBubble(
          text: message.text,
          boldLineIndexes: message.boldLineIndexes,
          createdAt: message.createdAt,
          acaoOuvir: acaoOuvir,
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
          photoStatus: message.photoStatus,
          onRetry: onRetryPhoto,
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

/// Bolha de mensagem da IA, com suporte a negrito em linhas específicas e à pergunta bifurcada de coleta.
class _AiBubble extends StatelessWidget {
  final String text;
  final List<int> boldLineIndexes;
  final DateTime? createdAt;
  final VoidCallback? onOpenCamera;
  final bool isColetaModoPrompt;
  final ColetaModo? selectedColetaModo;
  final void Function(ColetaModo)? onChooseColetaModo;
  final Widget? acaoOuvir;

  const _AiBubble({
    required this.text,
    this.boldLineIndexes = const [],
    this.createdAt,
    this.acaoOuvir,
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
                    subtitle: 'O Argos pergunta e libera a câmera em cada etapa.',
                    selected: selectedColetaModo == ColetaModo.guiado,
                    onTap: selectedColetaModo == null &&
                            onChooseColetaModo != null
                        ? () => onChooseColetaModo!(ColetaModo.guiado)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  _ColetaModoChoiceButton(
                    icon: Icons.upload_file_rounded,
                    label: 'Enviar tudo de uma vez',
                    subtitle:
                        'Você junta fotos, áudios e orçamento e envia no fim. Funciona sem internet.',
                    selected: selectedColetaModo == ColetaModo.emMassa,
                    onTap: selectedColetaModo == null &&
                            onChooseColetaModo != null
                        ? () => onChooseColetaModo!(ColetaModo.emMassa)
                        : null,
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (acaoOuvir != null) acaoOuvir!,
                    const Spacer(),
                    Text(
                      _formatMessageTime(createdAt),
                      style: TextStyle(
                        color: const Color(0xFF414755).withOpacity(.60),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
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

/// Botão de opção (guiado/em massa) usado na bolha da pergunta bifurcada.
class _ColetaModoChoiceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;

  /// Null quando a pergunta já foi respondida; o botão vira só-leitura.
  final VoidCallback? onTap;

  const _ColetaModoChoiceButton({
    required this.icon,
    required this.label,
    this.subtitle,
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
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    if (subtitle != null && !answered)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: foreground.withOpacity(.85),
                          fontWeight: FontWeight.w500,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
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

/// Bolha de texto enviada pelo mecânico, alinhada à direita.
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

/// Bolha com a foto enviada pelo mecânico, alinhada à direita.
class _PhotoBubble extends StatelessWidget {
  final String text;
  final String? imagePath;
  final DateTime? createdAt;
  final String? photoStatus;
  final VoidCallback? onRetry;

  const _PhotoBubble({
    required this.text,
    required this.imagePath,
    this.createdAt,
    this.photoStatus,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    final reenviando = photoStatus == ChatMessage.fotoReenviando;
    final falhou = photoStatus == ChatMessage.fotoFalhou;

    final Widget icone;
    final String legenda;
    if (reenviando) {
      icone = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
      legenda = 'Enviando de novo…';
    } else if (falhou) {
      icone = const Icon(Icons.refresh, color: Colors.white, size: 18);
      legenda = 'Não enviada. Toque para tentar de novo';
    } else {
      icone = const Icon(Icons.image, color: Colors.white, size: 18);
      legenda = text;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: GestureDetector(
            onTap: onRetry,
            child: Opacity(
              opacity: reenviando || falhou ? .75 : 1,
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
                          icone,
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              legenda,
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
          ),
        ),
      ],
    );
  }
}

/// Cartão com os itens e o total do orçamento, mostrado na confirmação final
/// (mesmo visual do resumo do "Enviar tudo de uma vez").
class _OrcamentoResumoBubble extends StatelessWidget {
  final List<MapEntry<String, double>> linhas;
  final double total;

  const _OrcamentoResumoBubble({required this.linhas, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 46),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF0057C0).withOpacity(.14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.request_quote_outlined,
                  size: 18,
                  color: Color(0xFF0057C0),
                ),
                SizedBox(width: 6),
                Text(
                  'Resumo do orçamento',
                  style: TextStyle(
                    color: Color(0xFF0057C0),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final linha in linhas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        linha.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF1F2937),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatCurrencyBRL(linha.value),
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 18, color: Color(0xFF1F2937)),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Total',
                    style: TextStyle(
                      color: Color(0xFF1F2937),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  formatCurrencyBRL(total),
                  style: const TextStyle(
                    color: Color(0xFF0057C0),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Etapas já concluídas de uma foto que ainda não terminou de subir.
class _EnvioFoto {
  UploadedImageEvidence? upload;
  bool evidenciaGravada = false;
}

/// Bolha de áudio com player, forma de onda e transcrição revelável.
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

/// Avatar com selo de microfone, usado na bolha de áudio.
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

/// Botão circular de play/pause/retry da bolha de áudio, conforme o estado.
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

/// Ícone pequeno de status (enviando/enviado/erro) no rodapé da bolha de áudio.
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

/// Forma de onda animada estilo WhatsApp, refletindo o progresso de reprodução.
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

/// Botão fixo no rodapé que abre o modal de montar o pacote em massa.
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
            'Enviar tudo de uma vez',
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

/// Tela cheia mostrada enquanto abandona a vistoria guiada e cria a nova em massa offline.
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
                ? 'Abandonando o passo a passo e preparando para enviar '
                    'tudo de uma vez. Isso pode levar alguns instantes.'
                : 'Abandonando o passo a passo de ${widget.placa} e '
                    'preparando para enviar tudo de uma vez. Isso pode '
                    'levar alguns instantes.',
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

/// Tela cheia mostrada quando o pacote em massa já foi confirmado offline e aguarda conexão para enviar.
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

/// Barra de composição do chat guiado: campo de texto, câmera e microfone.
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
                    tooltip: 'Enviar mensagem',
                    onTap: onSendTap,
                  )
                : _RoundActionButton(
                    key: const ValueKey('mic'),
                    icon: Icons.mic,
                    tooltip: 'Gravar áudio',
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
        onPressed: widget.unlocked
            ? widget.onTap
            : () {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text(
                        'A câmera libera quando o Argos pedir as fotos.',
                      ),
                    ),
                  );
              },
        icon: Icon(
          widget.unlocked ? Icons.camera_alt : Icons.camera_alt_outlined,
        ),
        color: widget.unlocked
            ? const Color(0xFF0057C0)
            : const Color(0xFFB5C3D6),
        tooltip: widget.unlocked
            ? 'Anexar fotos'
            : 'Câmera travada: libera quando o Argos pedir as fotos',
      ),
    );
  }
}

/// Barra de composição durante a gravação de áudio: duração, ondas e ações de cancelar/enviar.
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
          _RoundActionButton(
            icon: Icons.send,
            tooltip: 'Enviar áudio',
            onTap: onSend,
          ),
        ],
      ),
    );
  }
}

/// Botão circular de ação (enviar, cancelar, etc.) usado nas barras de composição.
class _RoundActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isLoading;

  const _RoundActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: _buildButton(),
    );
  }

  Widget _buildButton() {
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

/// Barras animadas simulando ondas de áudio durante a gravação.
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

/// Bolha com três pontinhos pulsantes indicando que a IA está digitando.
class _TypingBubble extends StatefulWidget {
  /// Texto ao lado dos pontinhos (ex. "Analisando 3 fotos…"), se houver.
  final String? status;

  const _TypingBubble({this.status});

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
              final pontos = Row(
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

              final status = widget.status;
              if (status == null) return pontos;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      status,
                      style: const TextStyle(
                        color: Color(0xFF1F2937),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  pontos,
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Botão pequeno de ouvir/parar a mensagem do Argos.
class _BotaoOuvir extends StatelessWidget {
  final bool tocando;
  final bool carregando;
  final VoidCallback onTap;

  const _BotaoOuvir({
    required this.tocando,
    required this.carregando,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tocando ? 'Parar' : 'Ouvir mensagem',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (carregando)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  tocando ? Icons.stop_circle_rounded : Icons.volume_up_rounded,
                  size: 18,
                  color: const Color(0xFF0057C0),
                ),
              const SizedBox(width: 4),
              Text(
                tocando ? 'Parar' : 'Ouvir',
                style: const TextStyle(
                  color: Color(0xFF0057C0),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

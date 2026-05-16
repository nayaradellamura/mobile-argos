import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../services/argos_ai_service.dart';
import '../../services/user_audio_storage_service.dart';
import '../../services/vistoria_chat_session_service.dart';
import '../camera/camera_page.dart';

enum ChatMessageType { ai, user, photo, audio }

enum ContinueVistoriaAction { continueNow, continueLater, startNew }

class ChatMessage {
  final ChatMessageType type;
  final String text;
  final String? imagePath;
  final String? audioPath;
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

  const ChatMessage({
    required this.type,
    required this.text,
    this.imagePath,
    this.audioPath,
    this.durationSeconds,
    this.audioId,
    this.originalStoragePath,
    this.mp3StoragePath,
    this.mp3DownloadUrl,
    this.audioStatus,
    this.createdAt,
  });
}

class AiChatPage extends StatefulWidget {
  /// ID do sinistro atual.
  ///
  /// Quando o chat for aberto a partir da tela de vistorias, passe este valor
  /// para vincular mensagens, fotos e áudios ao sinistro correto.
  final String? sinistroId;

  const AiChatPage({super.key, this.sinistroId});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final AudioRecorder audioRecorder = AudioRecorder();

  final List<ChatMessage> messages = [];

  VistoriaSession? currentSession;
  List<SinistroVistoriaOption> availableSinistros = [];
  bool isLoadingSession = true;

  bool hasText = false;
  bool isRecording = false;
  bool isStartingRecording = false;
  bool isAiTyping = false;

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

    _bootstrapChatSession();
  }

  @override
  void dispose() {
    recordingTimer?.cancel();

    if (isRecording) {
      audioRecorder.stop();
    }

    audioRecorder.dispose();
    messageController.dispose();
    scrollController.dispose();

    super.dispose();
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

  Future<void> _bootstrapChatSession() async {
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
            ChatMessage(
              type: ChatMessageType.ai,
              text:
                  'Não consegui preparar a sessão da vistoria. Detalhe: $e',
            ),
          );
      });
    }
  }

  Future<void> _loadAvailableSinistros({String? message}) async {
    final options = await VistoriaChatSessionService.instance
        .listCheckedInSinistrosForCurrentUser();

    if (!mounted) return;

    setState(() {
      currentSession = null;
      availableSinistros = options;
      isLoadingSession = false;
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

  Future<ContinueVistoriaAction?> _askVistoriaAction(
    VistoriaSession session,
  ) {
    return showDialog<ContinueVistoriaAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('Vistoria em andamento'),
          content: Text(
            'Encontramos uma vistoria aberta para este veículo.\n\n'
            'Nº: ${session.idvistoria}\n'
            'Placa: ${session.placa.isEmpty ? 'Sem placa' : session.placa}\n'
            'Veículo: ${session.veiculo.isEmpty ? 'Não informado' : session.veiculo}\n\n'
            'O que deseja fazer?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(
                  ContinueVistoriaAction.continueLater,
                );
              },
              child: const Text('Continuar mais tarde'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(
                  ContinueVistoriaAction.startNew,
                );
              },
              child: const Text('Começar nova'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(
                  ContinueVistoriaAction.continueNow,
                );
              },
              child: const Text('Continuar agora'),
            ),
          ],
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
          title: const Text('Descartar vistoria atual?'),
          content: Text(
            'A vistoria ${session.idvistoria} será marcada como abandonada.\n\n'
            'O histórico não será apagado do banco, mas uma nova vistoria será iniciada para este veículo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Descartar e iniciar nova'),
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

        final action = await _askVistoriaAction(openSession);

        if (!mounted) return;

        if (action == ContinueVistoriaAction.continueNow) {
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
          final confirmed = await _confirmStartNewVistoria(openSession);

          if (!mounted) return;

          if (!confirmed) {
            await _handleContinueLater(fromDirectSinistro: fromDirectSinistro);
            return;
          }

          setState(() {
            isLoadingSession = true;
          });

          await VistoriaChatSessionService.instance.discardVistoria(
            vistoriaDocId: openSession.docId,
            hardDelete: false,
          );
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
        await _sendInitialOiToAgent();
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

    if (session == null) return;

    setState(() {
      isAiTyping = true;
    });

    try {
      final reply = await ArgosAiService.instance.sendMessage(
        text: 'oi',
        inspectionId: session.idvistoria,
      );

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: reply,
      );

      if (!mounted) return;

      setState(() {
        isAiTyping = false;
        messages.add(ChatMessage(type: ChatMessageType.ai, text: reply, createdAt: DateTime.now()));
      });

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

    final loadedMessages = session.chatMessages
        .where((item) => item['backgroundStart'] != true)
        .map(_chatMessageFromFirestore)
        .whereType<ChatMessage>()
        .toList();

    messages
      ..clear()
      ..addAll(loadedMessages);

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

    return ChatMessage(
      type: ChatMessageType.ai,
      text: text,
      createdAt: createdAt,
    );
  }

  Future<void> _handleSinistroSelected(SinistroVistoriaOption option) async {
    await _startVistoriaFromSinistro(option.sinistroId);
  }

  Future<void> _sendTextMessage() async {
    final session = currentSession;
    final text = messageController.text.trim();

    if (text.isEmpty) return;

    if (session == null) {
      _showSnack(
        'Selecione uma vistoria antes de enviar mensagens.',
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
      final reply = await ArgosAiService.instance.sendMessage(
        text: text,
        inspectionId: session.idvistoria,
      );

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: reply,
      );

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(ChatMessage(type: ChatMessageType.ai, text: reply, createdAt: DateTime.now()));
      });

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

    if (session == null) {
      _showSnack(
        'Selecione uma vistoria antes de anexar fotos.',
        backgroundColor: Colors.orange,
      );
      return;
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

    for (final photo in photos) {
      try {
        await VistoriaChatSessionService.instance.appendImageBase64FromFile(
          vistoriaDocId: session.docId,
          imagePath: photo.path,
        );
      } catch (e) {
        debugPrint('Erro ao salvar foto em base64 na vistoria: $e');
      }
    }

    await VistoriaChatSessionService.instance.appendChatMessage(
      vistoriaDocId: session.docId,
      role: 'photo',
      text:
          '${photos.length} foto${photos.length > 1 ? 's' : ''} anexada${photos.length > 1 ? 's' : ''} à vistoria.',
    );

    Future.delayed(const Duration(milliseconds: 650), () async {
      if (!mounted) return;

      final quantity = photos.length;
      final aiText =
          '$quantity foto${quantity > 1 ? 's' : ''} recebida${quantity > 1 ? 's' : ''}. Essas evidências foram vinculadas à vistoria.';

      await VistoriaChatSessionService.instance.appendAiMessage(
        vistoriaDocId: session.docId,
        text: aiText,
      );

      if (!mounted) return;

      setState(() {
        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: aiText,
            createdAt: DateTime.now(),
          ),
        );
      });

      _scrollToBottom();
    });
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
            sinistroId: session.sinistroId,
            duration: Duration(seconds: duration),
          );

      try {
        await VistoriaChatSessionService.instance.appendAudioBase64FromFile(
          vistoriaDocId: session.docId,
          audioPath: path,
          contentType: 'audio/mp4',
        );
      } catch (e) {
        debugPrint('Erro ao salvar áudio em base64 na vistoria: $e');
      }

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

      final audioResult = await ArgosAiService.instance.sendAudioMessage(
        idvistoria: session.idvistoria,
        sinistroId: session.sinistroId,
        audioId: uploadedAudio.audioId,
        storagePath: uploadedAudio.mp3StoragePath,
        durationSeconds: duration,
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
            audioStatus: 'done',
            createdAt: messages[index].createdAt,
          );
        }

        if (audioResult.revisedTranscript.trim().isNotEmpty) {
          messages.add(
            ChatMessage(
              type: ChatMessageType.user,
              text: audioResult.revisedTranscript,
              createdAt: DateTime.now(),
            ),
          );
        }

        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: audioResult.reply,
            createdAt: DateTime.now(),
          ),
        );

        isAiTyping = false;
      });

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

  @override
  Widget build(BuildContext context) {
    final duration = _formatDuration(recordingSeconds);

    if (isLoadingSession) {
      return const SafeArea(child: _ChatSessionLoading());
    }

    if (currentSession == null) {
      return SafeArea(
        child: _SinistroSelectionView(
          options: availableSinistros,
          onSelect: _handleSinistroSelected,
        ),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          const _ChatHeader(),

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

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _ChatBubble(message: message),
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
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: isRecording
                ? _RecordingComposer(
                    key: const ValueKey('recording'),
                    duration: duration,
                    onCancel: _cancelRecording,
                    onSend: _finishRecording,
                  )
                : _TextComposer(
                    key: const ValueKey('composer'),
                    controller: messageController,
                    hasText: hasText,
                    isStartingRecording: isStartingRecording,
                    onCameraTap: _openCamera,
                    onSendTap: _sendTextMessage,
                    onMicTap: _startRecording,
                  ),
          ),
        ],
      ),
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

class _SinistroSelectionView extends StatelessWidget {
  final List<SinistroVistoriaOption> options;
  final ValueChanged<SinistroVistoriaOption> onSelect;

  const _SinistroSelectionView({
    required this.options,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _ChatHeader(),
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
                      child: const Text(
                        'Nenhum veículo com check-in disponível para iniciar vistoria.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
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

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => onSelect(option),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE5F6FF),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Icon(
                                    Icons.directions_car,
                                    color: Color(0xFF0057C0),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        option.placa.isEmpty
                                            ? 'Sem placa'
                                            : option.placa,
                                        style: const TextStyle(
                                          color: Color(0xFF1F2937),
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
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
                                const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFF0057C0),
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

class _ChatHeader extends StatelessWidget {
  const _ChatHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.80),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF0057C0),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.smart_toy, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chat IA',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0057C0),
                  ),
                ),
                const Text(
                  'Assistente de vistoria ativa',
                  style: TextStyle(
                    color: Color(0xFF414755),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFE5F6FF),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'ONLINE',
              style: TextStyle(
                color: Color(0xFF0057C0),
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    switch (message.type) {
      case ChatMessageType.ai:
        return _AiBubble(text: message.text, createdAt: message.createdAt);

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
  final DateTime? createdAt;

  const _AiBubble({required this.text, this.createdAt});

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
                Text(
                  text,
                  style: const TextStyle(
                    color: Color(0xFF1F2937),
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
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
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            decoration: const BoxDecoration(
              color: Color(0xFF0057C0),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(22),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(22),
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
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
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

  bool isPlaying = false;
  Duration currentPosition = Duration.zero;
  Duration totalDuration = Duration.zero;

  @override
  void initState() {
    super.initState();

    totalDuration = Duration(seconds: widget.durationSeconds ?? 0);

    player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => totalDuration = duration);
    });

    player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => currentPosition = position);
    });

    player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        isPlaying = false;
        currentPosition = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
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
              child: Row(
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

class _TextComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool hasText;
  final bool isStartingRecording;
  final VoidCallback onCameraTap;
  final VoidCallback onSendTap;
  final VoidCallback onMicTap;

  const _TextComposer({
    super.key,
    required this.controller,
    required this.hasText,
    required this.isStartingRecording,
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
          IconButton(
            onPressed: onCameraTap,
            icon: const Icon(Icons.camera_alt),
            color: const Color(0xFF0057C0),
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

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../services/argos_ai_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../camera/camera_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

class ArgosAiService {
  ArgosAiService._();

  static final ArgosAiService instance = ArgosAiService._();

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  Future<String> sendMessage({
    required String text,
    required String inspectionId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    debugPrint('Usuário Firebase atual: ${user?.uid}');
    debugPrint('Email Firebase atual: ${user?.email}');

    if (user == null) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Usuário não está logado no Firebase Auth.',
      );
    }

    await user.getIdToken(true);

    final callable = _functions.httpsCallable('sendArgosMessage');

    final result = await callable.call<Map<String, dynamic>>({
      'text': text.trim(),
      'inspectionId': inspectionId,
    });

    final data = result.data;

    return data['reply']?.toString() ??
        'Entendi. Pode continuar descrevendo a vistoria.';
  }
}

enum ChatMessageType { ai, user, photo, audio }

class ChatMessage {
  final ChatMessageType type;
  final String text;
  final String? imagePath;
  final String? audioPath;
  final int? durationSeconds;

  const ChatMessage({
    required this.type,
    required this.text,
    this.imagePath,
    this.audioPath,
    this.durationSeconds,
  });
}

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final AudioRecorder audioRecorder = AudioRecorder();

  final List<ChatMessage> messages = [
    const ChatMessage(
      type: ChatMessageType.ai,
      text:
          'Olá! Sou o assistente Argos. Vamos iniciar o registro de sinistro para o Toyota Corolla ABC-1234.',
    ),
    const ChatMessage(
      type: ChatMessageType.ai,
      text:
          'Descreva os principais pontos de impacto ou envie fotos e áudio da avaria.',
    ),
  ];

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

  Future<void> _sendTextMessage() async {
    final text = messageController.text.trim();

    if (text.isEmpty) return;

    setState(() {
      messages.add(ChatMessage(type: ChatMessageType.user, text: text));

      messageController.clear();
      hasText = false;
      isAiTyping = true;
    });

    _scrollToBottom();

    try {
      final reply = await ArgosAiService.instance.sendMessage(
        text: text,
        inspectionId: 'INS-001',
      );

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(ChatMessage(type: ChatMessageType.ai, text: reply));
      });

      _scrollToBottom();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('ERRO CLOUD FUNCTION');
      debugPrint('code: ${e.code}');
      debugPrint('message: ${e.message}');
      debugPrint('details: ${e.details}');

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text:
                'O assistente Argos está temporariamente indisponível.\nCódigo: ${e.code}',
          ),
        );
      });

      _scrollToBottom();
    } catch (e) {
      debugPrint('ERRO GERAL CHAT IA: $e');

      if (!mounted) return;

      setState(() {
        isAiTyping = false;

        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text: 'Erro inesperado ao chamar o assistente.',
          ),
        );
      });

      _scrollToBottom();
    }
  }

  Future<void> _openCamera() async {
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
          ),
        );
      }
    });

    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;

      final quantity = photos.length;

      setState(() {
        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text:
                '$quantity foto${quantity > 1 ? 's' : ''} recebida${quantity > 1 ? 's' : ''}. Essas evidências serão vinculadas à vistoria.',
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
          text: '• ${_formatDuration(duration)}',
          audioPath: path,
          durationSeconds: duration,
        ),
      );
    });

    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;

      setState(() {
        messages.add(
          const ChatMessage(type: ChatMessageType.ai, text: 'Áudio recebido.'),
        );
      });

      _scrollToBottom();
    });
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final duration = _formatDuration(recordingSeconds);

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
        return _AiBubble(text: message.text);

      case ChatMessageType.user:
        return _UserBubble(text: message.text);

      case ChatMessageType.photo:
        return _PhotoBubble(text: message.text, imagePath: message.imagePath);

      case ChatMessageType.audio:
        return _AudioBubble(text: message.text, audioPath: message.audioPath);
    }
  }
}

class _AiBubble extends StatelessWidget {
  final String text;

  const _AiBubble({required this.text});

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
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFFE5F6FF),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(22),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF1F2937),
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  final String text;

  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF0057C0),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(22),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                height: 1.35,
                fontWeight: FontWeight.w600,
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

  const _PhotoBubble({required this.text, required this.imagePath});

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
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioBubble extends StatelessWidget {
  final String text;
  final String? audioPath;

  const _AudioBubble({required this.text, required this.audioPath});

  @override
  Widget build(BuildContext context) {
    final fileName = audioPath == null
        ? 'audio.m4a'
        : audioPath!.split(Platform.pathSeparator).last;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0057C0),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.graphic_eq,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      const _StaticAudioBars(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Arquivo salvo: $fileName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(.72),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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

class _StaticAudioBars extends StatelessWidget {
  const _StaticAudioBars();

  @override
  Widget build(BuildContext context) {
    final heights = [8.0, 16.0, 11.0, 22.0, 14.0, 19.0, 10.0];

    return Row(
      children: heights.map((height) {
        return Container(
          width: 3,
          height: height,
          margin: const EdgeInsets.only(right: 3),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.75),
            borderRadius: BorderRadius.circular(99),
          ),
        );
      }).toList(),
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

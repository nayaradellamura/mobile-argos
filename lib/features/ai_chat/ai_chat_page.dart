import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../camera/camera_page.dart';

enum ChatMessageType { ai, user, photo, audio }

class ChatMessage {
  final ChatMessageType type;
  final String text;
  final String? imagePath;

  const ChatMessage({required this.type, required this.text, this.imagePath});
}

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();

  final List<ChatMessage> messages = [
    const ChatMessage(
      type: ChatMessageType.ai,
      text:
          'Olá! Sou o assistente Argos. Vamos iniciar o registro de sinistro para o Toyota Corolla ABC-1234.',
    ),
    const ChatMessage(
      type: ChatMessageType.ai,
      text:
          'Descreva os principais pontos de impacto ou envie uma foto da avaria.',
    ),
  ];

  bool hasText = false;
  bool isRecording = false;

  Timer? recordingTimer;
  int recordingSeconds = 0;

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
    messageController.dispose();
    scrollController.dispose();
    recordingTimer?.cancel();
    super.dispose();
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

  void _sendTextMessage() {
    final text = messageController.text.trim();

    if (text.isEmpty) return;

    setState(() {
      messages.add(ChatMessage(type: ChatMessageType.user, text: text));

      messageController.clear();
      hasText = false;
    });

    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;

      setState(() {
        messages.add(
          const ChatMessage(
            type: ChatMessageType.ai,
            text:
                'Entendido. Vou considerar essa descrição no laudo técnico da vistoria. Você pode complementar com fotos ou áudio, se necessário.',
          ),
        );
      });

      _scrollToBottom();
    });
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

      setState(() {
        messages.add(
          ChatMessage(
            type: ChatMessageType.ai,
            text:
                '${photos.length} foto${photos.length > 1 ? 's' : ''} recebida${photos.length > 1 ? 's' : ''}. Essas evidências serão vinculadas à vistoria.',
          ),
        );
      });

      _scrollToBottom();
    });
  }

  void _startRecording() {
    FocusScope.of(context).unfocus();

    setState(() {
      isRecording = true;
      recordingSeconds = 0;
    });

    recordingTimer?.cancel();
    recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      setState(() {
        recordingSeconds++;
      });
    });
  }

  void _cancelRecording() {
    recordingTimer?.cancel();

    setState(() {
      isRecording = false;
      recordingSeconds = 0;
    });
  }

  void _finishRecording() {
    final duration = _formatDuration(recordingSeconds);

    recordingTimer?.cancel();

    setState(() {
      isRecording = false;
      recordingSeconds = 0;

      messages.add(
        ChatMessage(
          type: ChatMessageType.audio,
          text: 'Áudio técnico enviado • $duration',
        ),
      );
    });

    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;

      setState(() {
        messages.add(
          const ChatMessage(
            type: ChatMessageType.ai,
            text:
                'Áudio recebido. Na versão final, esse relato poderá ser transcrito e usado junto às imagens para gerar o laudo estruturado.',
          ),
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
          _ChatHeader(),

          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
              itemCount: messages.length,
              itemBuilder: (context, index) {
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
        return _AudioBubble(text: message.text);
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

  const _AudioBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF0057C0),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow, color: Colors.white),
                const SizedBox(width: 8),
                const _StaticAudioBars(),
                const SizedBox(width: 10),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
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

class _TextComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool hasText;
  final VoidCallback onCameraTap;
  final VoidCallback onSendTap;
  final VoidCallback onMicTap;

  const _TextComposer({
    super.key,
    required this.controller,
    required this.hasText,
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

  const _RoundActionButton({
    super.key,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0057C0),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white, size: 21),
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

  final random = Random();

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

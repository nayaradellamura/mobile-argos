import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

/// Animação exibida enquanto o pacote do modo "enviar tudo de uma vez" está
/// sendo processado (upload de fotos/áudio + orçamento + transição de
/// status) -- glow pulsante reaproveita o mesmo padrão de
/// `_CameraReleaseButtonState` em `ai_chat_page.dart`, só centralizado e
/// maior, com um anel giratório (efeito "scanner") em volta do olho.
///
/// `statusText` é dirigido por quem chama (o orquestrador do envio em
/// massa), refletindo a etapa real (fotos/áudio/orçamento/finalizando) em
/// vez de um texto cíclico desconectado do progresso de verdade.
class EyeProcessingAnimation extends StatefulWidget {
  final ValueListenable<String> statusText;

  const EyeProcessingAnimation({super.key, required this.statusText});

  @override
  State<EyeProcessingAnimation> createState() =>
      _EyeProcessingAnimationState();
}

class _EyeProcessingAnimationState extends State<EyeProcessingAnimation>
    with TickerProviderStateMixin {
  late final AnimationController _glowController;
  late final Animation<double> _glow;
  late final AnimationController _ringController;

  @override
  void initState() {
    super.initState();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _glow = Tween<double>(begin: .18, end: .55).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 150,
          height: 150,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _glowController,
                builder: (context, child) {
                  return Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0057C0).withOpacity(_glow.value),
                          blurRadius: 42,
                          spreadRadius: 14,
                        ),
                      ],
                    ),
                  );
                },
              ),
              RotationTransition(
                turns: _ringController,
                child: CustomPaint(
                  size: const Size(150, 150),
                  painter: _ScanRingPainter(),
                ),
              ),
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(.18),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Center(
                  child: SvgPicture.asset(
                    'assets/images/eye_argos.svg',
                    width: 46,
                    height: 46,
                    colorFilter: const ColorFilter.mode(
                      Color(0xFF0057C0),
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        ValueListenableBuilder<String>(
          valueListenable: widget.statusText,
          builder: (context, text, _) {
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                text,
                key: ValueKey(text),
                textAlign: TextAlign.center,
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2937),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ScanRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final paint = Paint()
      ..shader = SweepGradient(
        colors: const [Colors.transparent, Color(0xFF0057C0)],
        startAngle: 0,
        endAngle: math.pi * 1.3,
        transform: GradientRotation(-math.pi / 2),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.3, false, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

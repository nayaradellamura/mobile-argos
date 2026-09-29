import 'dart:async';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class SplashPage extends StatefulWidget {
  final VoidCallback onComplete;

  const SplashPage({super.key, required this.onComplete});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  double progress = 0;
  Timer? timer;
  bool completed = false;

  // 1. Usando a classe nova do Shorebird: ShorebirdUpdater
  final shorebirdUpdater = ShorebirdUpdater();
  int? _patchNumber;
  String? _updateStatusText;

  @override
  void initState() {
    super.initState();

    // 2. Busca o número do patch ao abrir a tela
    _fetchPatchNumber();

    // Dispara a checagem de update do Shorebird sem esperar (a doc do pacote
    // avisa explicitamente pra não dar await nisso no startup — a chamada de
    // rede pode demorar e travaria a splash indefinidamente). O progresso
    // visual da tela continua no timer normal, independente do resultado.
    _checkForShorebirdUpdate();

    timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted) return;

      if (progress >= 100) {
        timer.cancel();

        if (!completed) {
          completed = true;

          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              widget.onComplete();
            }
          });
        }

        return;
      }

      setState(() {
        progress += 2;
      });
    });
  }

  // 3. Método atualizado para ler o patch
  Future<void> _fetchPatchNumber() async {
    try {
      final currentPatch = await shorebirdUpdater.readCurrentPatch();
      if (mounted) {
        setState(() {
          _patchNumber = currentPatch?.number;
        });
      }
    } catch (e) {
      // Se der erro (ex: rodando no modo debug), ignora em silêncio
      debugPrint('Erro ao buscar patch do Shorebird: $e');
    }
  }

  void _checkForShorebirdUpdate() {
    // Fora de um build gerado via `shorebird release`/`shorebird preview`
    // (ex: debug local, flutter run) o updater não existe — não tem update
    // pra checar.
    if (!shorebirdUpdater.isAvailable) return;

    if (mounted) {
      setState(() => _updateStatusText = 'Verificando atualização...');
    }

    shorebirdUpdater
        .checkForUpdate()
        .then((status) async {
          if (!mounted) return;

          switch (status) {
            case UpdateStatus.outdated:
              setState(() => _updateStatusText = 'Baixando atualização...');
              try {
                await shorebirdUpdater.update();
                if (!mounted) return;
                setState(
                  () => _updateStatusText =
                      'Atualização baixada — abra o app de novo pra aplicar',
                );
              } catch (e) {
                debugPrint('Erro ao baixar patch do Shorebird: $e');
                if (!mounted) return;
                setState(() => _updateStatusText = null);
              }
            case UpdateStatus.restartRequired:
              setState(
                () => _updateStatusText =
                    'Atualização pronta — abra o app de novo pra aplicar',
              );
            case UpdateStatus.upToDate:
              setState(() => _updateStatusText = 'App atualizado');
            case UpdateStatus.unavailable:
              setState(() => _updateStatusText = null);
          }
        })
        .catchError((e) {
          debugPrint('Erro ao checar atualização do Shorebird: $e');
          if (!mounted) return;
          setState(() => _updateStatusText = null);
        });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const brandColor = Color(0xFF0474FB);

    return Scaffold(
      backgroundColor: brandColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0474FB), Color(0xFF0057C0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),

          Positioned(
            top: -90,
            right: -80,
            child: _BlurCircle(size: 280, color: Colors.white.withOpacity(.08)),
          ),

          Positioned(
            bottom: -120,
            left: -110,
            child: _BlurCircle(size: 340, color: Colors.black.withOpacity(.12)),
          ),

          Positioned.fill(child: CustomPaint(painter: _GrainPainter())),

          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: .8, end: 1),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutBack,
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value.clamp(0, 1),
                      child: Transform.scale(scale: value, child: child),
                    );
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withOpacity(.22),
                              blurRadius: 70,
                              spreadRadius: 18,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 128,
                        height: 128,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(.20),
                              blurRadius: 35,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: Center(
                          child: SvgPicture.asset(
                            'assets/images/eye_argos.svg',
                            width: 64,
                            height: 64,
                            colorFilter: const ColorFilter.mode(
                              brandColor,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 34),

                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 20, end: 0),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOut,
                  builder: (context, value, child) {
                    return Transform.translate(
                      offset: Offset(0, value),
                      child: Opacity(opacity: 1 - (value / 20), child: child),
                    );
                  },
                  child: SvgPicture.asset(
                    'assets/images/display_argos.svg',
                    width: 220,
                    colorFilter: const ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                  ),
                ),

                const SizedBox(height: 6),

                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: .72),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOut,
                  builder: (context, value, child) {
                    return Opacity(opacity: value, child: child);
                  },
                  child: Text(
                    'VISTORIAS INTELIGENTES',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      letterSpacing: 3.6,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),

                const SizedBox(height: 52),

                Container(
                  width: 190,
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      curve: Curves.linear,
                      width: 190 * (progress / 100),
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.65),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 12,
                ),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _updateStatusText != null ? .85 : .40,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 4. Lógica de exibição da versão
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _patchNumber != null
                                ? 'v1.0 • Patch $_patchNumber'
                                : 'v1.0',
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_updateStatusText != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              _updateStatusText!,
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Row(
                        children: [
                          Container(
                            width: 14,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.55),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.55),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlurCircle extends StatelessWidget {
  final double size;
  final Color color;

  const _BlurCircle({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 120, spreadRadius: 45)],
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(.025)
      ..strokeWidth = 1;

    for (double x = 0; x < size.width; x += 18) {
      for (double y = 0; y < size.height; y += 18) {
        canvas.drawCircle(Offset(x, y), .8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
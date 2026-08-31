import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

enum _NetworkState { online, offline }

class ArgosNetworkGate extends StatefulWidget {
  final Widget child;

  const ArgosNetworkGate({super.key, required this.child});

  @override
  State<ArgosNetworkGate> createState() => _ArgosNetworkGateState();
}

class _ArgosNetworkGateState extends State<ArgosNetworkGate> {
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounce;

  _NetworkState _state = _NetworkState.online;

  bool _manualChecking = false;
  bool _hasCheckedOnce = false;

  @override
  void initState() {
    super.initState();

    _checkInternet(silent: true);

    _subscription = _connectivity.onConnectivityChanged.listen((_) {
      _debounce?.cancel();

      _debounce = Timer(const Duration(milliseconds: 450), () {
        _checkInternet();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _checkInternet({bool silent = false}) async {
    if (!mounted) return;

    if (!silent && _hasCheckedOnce) {
      setState(() {
        _manualChecking = true;
      });
    }

    final hasInternet = await _hasRealInternet();

    if (!mounted) return;

    setState(() {
      _state = hasInternet ? _NetworkState.online : _NetworkState.offline;
      _manualChecking = false;
      _hasCheckedOnce = true;
    });
  }

  Future<void> _retry() async {
    if (_manualChecking) return;

    setState(() {
      _manualChecking = true;
    });

    await _checkInternet();
  }

  Future<bool> _hasRealInternet() async {
    try {
      final connectivityResult = await _connectivity.checkConnectivity();

      if (connectivityResult.contains(ConnectivityResult.none)) {
        return false;
      }

      final lookup = await InternetAddress.lookup(
        'example.com',
      ).timeout(const Duration(seconds: 3));

      return lookup.isNotEmpty && lookup.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _NetworkState.offline) {
      return _ArgosOfflineScreen(isChecking: _manualChecking, onRetry: _retry);
    }

    return widget.child;
  }
}

class _ArgosOfflineScreen extends StatelessWidget {
  final bool isChecking;
  final VoidCallback onRetry;

  const _ArgosOfflineScreen({required this.isChecking, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return MediaQuery(
      data: media.copyWith(textScaler: const TextScaler.linear(1.0)),
      child: Material(
        color: const Color(0xFFF3FBFF),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.96),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: Colors.black.withOpacity(.05)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.06),
                        blurRadius: 32,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _OfflineEye(),
                      const SizedBox(height: 24),
                      Text(
                        'O Argos piscou...',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF0057C0),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'A internet saiu para fazer uma vistoria e ainda não voltou.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2937),
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7FAFC),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.black.withOpacity(.04),
                          ),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.cloud_off_rounded,
                                  color: Color(0xFF0057C0),
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Sem conexão',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color: Color(0xFF1F2937),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Sem internet o app não consegue carregar sinistros, salvar check-in, enviar fotos, áudios ou conversar com a IA.',
                              textAlign: TextAlign.left,
                              softWrap: true,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              textScaler: const TextScaler.linear(1.0),
                              style: const TextStyle(
                                color: Color(0xFF414755),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.28,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5F6FF),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.tips_and_updates_outlined,
                              color: Color(0xFF0057C0),
                              size: 20,
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Dica do fiscal: confira o Wi-Fi, os dados móveis ou se o modo avião está ativado.',
                                textAlign: TextAlign.left,
                                softWrap: true,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                textScaler: const TextScaler.linear(1.0),
                                style: const TextStyle(
                                  color: Color(0xFF414755),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  height: 1.28,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton.icon(
                          onPressed: isChecking ? null : onRetry,
                          icon: isChecking
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: Text(
                            isChecking
                                ? 'Procurando sinal...'
                                : 'Tentar reconectar',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0057C0),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(
                              0xFF0057C0,
                            ).withOpacity(.65),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Código Argos: SEM-SINAL-404',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black.withOpacity(.42),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineEye extends StatefulWidget {
  const _OfflineEye();

  @override
  State<_OfflineEye> createState() => _OfflineEyeState();
}

class _OfflineEyeState extends State<_OfflineEye>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
      lowerBound: 0,
      upperBound: 1,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final scale = .94 + (controller.value * .06);

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              color: const Color(0xFF006FF1),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0057C0).withOpacity(.22),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 82,
                    height: 82,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SvgPicture.asset(
                        'assets/images/eye_argos.svg',
                        width: 220,
                        colorFilter: const ColorFilter.mode(
                          Colors.white,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 22,
                  bottom: 22,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: const Icon(
                      Icons.wifi_off,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

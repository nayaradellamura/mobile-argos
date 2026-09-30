import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/argos_connectivity_service.dart';

/// Antes disto, offline trocava a árvore inteira pela tela cheia de "sem
/// conexão", travando o app até a rede voltar. O app agora funciona híbrido
/// (a Fase 2/3 de offline já cobrem coleta em massa e a listagem de
/// vistorias com o que está em cache) -- então o gate nunca mais bloqueia,
/// só sinaliza com uma faixa fina não-bloqueante no topo. Cada tela decide
/// sozinha o que fazer quando `ArgosConnectivityService.instance.isOnline`
/// está falso (ex: `InspectionsPage` escondendo o ranking, `_registerCheckIn`
/// recusando o check-in com uma mensagem clara).
class ArgosNetworkGate extends StatefulWidget {
  final Widget child;

  const ArgosNetworkGate({super.key, required this.child});

  @override
  State<ArgosNetworkGate> createState() => _ArgosNetworkGateState();
}

class _ArgosNetworkGateState extends State<ArgosNetworkGate> {
  bool _manualChecking = false;

  Future<void> _retry() async {
    if (_manualChecking) return;

    setState(() => _manualChecking = true);

    await ArgosConnectivityService.instance.recheckNow();

    if (!mounted) return;

    setState(() => _manualChecking = false);
  }

  @override
  Widget build(BuildContext context) {
    // Column, não Stack/Positioned: a faixa precisa OCUPAR espaço de
    // verdade e empurrar o conteúdo pra baixo -- um overlay flutuando por
    // cima cobria o cabeçalho/busca da própria tela por baixo. Fica sempre
    // montada (mesmo online, com altura 0) pra poder animar sozinha a
    // confirmação breve de "conectado novamente" quando a rede volta.
    return Column(
      children: [
        _ConnectivityStatusBar(isChecking: _manualChecking, onRetry: _retry),
        Expanded(child: widget.child),
      ],
    );
  }
}

enum _StatusBarState { hidden, offline, backOnline }

/// Faixa de conectividade no estilo dos apps mais comuns do mercado (o
/// "No Internet Connection" que desliza do topo no iOS, o "Conectando..."
/// do WhatsApp): tom neutro (não é um erro da marca, é só um estado
/// informativo), ícone + texto direto, e uma confirmação verde breve ao
/// reconectar -- some sozinha depois de alguns segundos.
class _ConnectivityStatusBar extends StatefulWidget {
  final bool isChecking;
  final VoidCallback onRetry;

  const _ConnectivityStatusBar({
    required this.isChecking,
    required this.onRetry,
  });

  @override
  State<_ConnectivityStatusBar> createState() => _ConnectivityStatusBarState();
}

class _ConnectivityStatusBarState extends State<_ConnectivityStatusBar> {
  late _StatusBarState _barState = ArgosConnectivityService.instance.isOnline.value
      ? _StatusBarState.hidden
      : _StatusBarState.offline;
  bool _wasOffline = !ArgosConnectivityService.instance.isOnline.value;
  Timer? _backOnlineTimer;

  @override
  void initState() {
    super.initState();
    ArgosConnectivityService.instance.isOnline.addListener(_handleChange);
  }

  void _handleChange() {
    final online = ArgosConnectivityService.instance.isOnline.value;

    if (!online) {
      _backOnlineTimer?.cancel();
      _wasOffline = true;
      setState(() => _barState = _StatusBarState.offline);
      return;
    }

    if (_wasOffline) {
      _wasOffline = false;
      setState(() => _barState = _StatusBarState.backOnline);

      _backOnlineTimer?.cancel();
      _backOnlineTimer = Timer(const Duration(seconds: 2, milliseconds: 500), () {
        if (!mounted) return;
        setState(() => _barState = _StatusBarState.hidden);
      });
    } else {
      setState(() => _barState = _StatusBarState.hidden);
    }
  }

  @override
  void dispose() {
    _backOnlineTimer?.cancel();
    ArgosConnectivityService.instance.isOnline.removeListener(_handleChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: switch (_barState) {
        _StatusBarState.hidden => const SizedBox(width: double.infinity, height: 0),
        _StatusBarState.offline => _StatusBarContent(
            key: const ValueKey('offline'),
            color: const Color(0xFF1F2937),
            icon: Icons.wifi_off_rounded,
            text: 'Sem conexão — mostrando dados salvos',
            isChecking: widget.isChecking,
            onRetry: widget.onRetry,
          ),
        _StatusBarState.backOnline => const _StatusBarContent(
            key: ValueKey('back_online'),
            color: Color(0xFF16A34A),
            icon: Icons.wifi_rounded,
            text: 'Conectado novamente',
          ),
      },
    );
  }
}

class _StatusBarContent extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  final bool isChecking;
  final VoidCallback? onRetry;

  const _StatusBarContent({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
    this.isChecking = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onRetry == null || isChecking ? null : onRetry,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.of(context).padding.top + 9,
            16,
            9,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 15),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(width: 10),
                if (isChecking)
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  const Icon(Icons.refresh_rounded, color: Colors.white, size: 15),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/argos_connectivity_service.dart';

/// Envolve o app inteiro: nunca bloqueia a tela, só exibe uma faixa fina de
/// status de conexão no topo, acima do conteúdo normal.
class ArgosNetworkGate extends StatefulWidget {
  final Widget child;

  const ArgosNetworkGate({super.key, required this.child});

  @override
  State<ArgosNetworkGate> createState() => _ArgosNetworkGateState();
}

class _ArgosNetworkGateState extends State<ArgosNetworkGate> {
  bool _bannerReservesTopInset =
      !ArgosConnectivityService.instance.isOnline.value;

  void _handleBannerVisibilityChanged(bool visible) {
    if (_bannerReservesTopInset == visible) return;
    setState(() => _bannerReservesTopInset = visible);
  }

  @override
  Widget build(BuildContext context) {
    final child = _bannerReservesTopInset
        ? MediaQuery(
            data: MediaQuery.of(context).removePadding(removeTop: true),
            child: widget.child,
          )
        : widget.child;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConnectivityStatusBar(
          onVisibilityChanged: _handleBannerVisibilityChanged,
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Estados possíveis da faixa de conexão.
enum _StatusBarState { hidden, offline, backOnline }

/// Faixa de status de conexão: mostra "offline" enquanto sem rede e uma
/// confirmação breve de "conectado novamente" ao reconectar.
class _ConnectivityStatusBar extends StatefulWidget {
  final ValueChanged<bool> onVisibilityChanged;

  const _ConnectivityStatusBar({required this.onVisibilityChanged});

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

  void _setBarState(_StatusBarState state) {
    setState(() => _barState = state);
    widget.onVisibilityChanged(state != _StatusBarState.hidden);
  }

  void _handleChange() {
    final online = ArgosConnectivityService.instance.isOnline.value;

    if (!online) {
      _backOnlineTimer?.cancel();
      _wasOffline = true;
      _setBarState(_StatusBarState.offline);
      return;
    }

    if (_wasOffline) {
      _wasOffline = false;
      _setBarState(_StatusBarState.backOnline);

      _backOnlineTimer?.cancel();
      _backOnlineTimer = Timer(const Duration(seconds: 2, milliseconds: 500), () {
        if (!mounted) return;
        _setBarState(_StatusBarState.hidden);
      });
    } else {
      _setBarState(_StatusBarState.hidden);
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
        _StatusBarState.offline => const _StatusBarContent(
            key: ValueKey('offline'),
            color: Color(0xFF1F2937),
            icon: Icons.wifi_off_rounded,
            text: 'VOCÊ ESTÁ OFFLINE',
          ),
        _StatusBarState.backOnline => const _StatusBarContent(
            key: ValueKey('back_online'),
            color: Color(0xFF16A34A),
            icon: Icons.wifi_rounded,
            text: 'CONECTADO NOVAMENTE',
          ),
      },
    );
  }
}

/// Conteúdo visual da faixa: ícone + texto centralizados sobre fundo colorido.
class _StatusBarContent extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const _StatusBarContent({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 14),
              const SizedBox(width: 8),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
  // Enquanto o banner está visível (offline ou o "conectado novamente"
  // passageiro), ele mesmo já reserva o espaço da status bar pra si
  // (via SafeArea). Se o conteúdo abaixo também reservar -- e reserva,
  // quase toda tela do app tem seu próprio SafeArea/Scaffold pensando que
  // está encostada no topo físico -- o inset conta em dobro e sobra uma
  // faixa vazia entre o banner e o conteúdo. `MediaQuery.removePadding`
  // avisa o conteúdo que o topo já foi consumido, só enquanto o banner
  // estiver de fato ocupando aquele espaço.
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

    // Column, não Stack/Positioned: a faixa precisa OCUPAR espaço de
    // verdade e empurrar o conteúdo pra baixo -- um overlay flutuando por
    // cima cobria o cabeçalho/busca da própria tela por baixo. Fica sempre
    // montada (mesmo online, com altura 0) pra poder animar sozinha a
    // confirmação breve de "conectado novamente" quando a rede volta.
    // `stretch` é o que garante que a faixa ocupe a largura inteira da
    // tela -- sem isso ela encolhe pro tamanho do conteúdo (ícone + texto)
    // e fica um "pill" centralizado em vez de uma barra de ponta a ponta.
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

enum _StatusBarState { hidden, offline, backOnline }

/// Faixa de conectividade no estilo dos apps mais comuns do mercado (o
/// "No Internet Connection" que desliza do topo no iOS, o "Conectando..."
/// do WhatsApp): tom neutro (não é um erro da marca, é só um estado
/// informativo), ícone + texto direto, e uma confirmação verde breve ao
/// reconectar -- some sozinha depois de alguns segundos.
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

/// Faixa minimalista, estilo Duolingo: só ícone + texto centralizados, sem
/// nenhuma ação (nada de botão de retry) -- a reconexão já é detectada
/// sozinha pelo `ArgosConnectivityService`, não depende do usuário tocar em
/// nada. `SafeArea` (não um cálculo manual de `MediaQuery.padding.top`)
/// garante que a faixa nunca fica por baixo da status bar, em qualquer
/// aparelho (notch, ilha dinâmica, etc.).
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

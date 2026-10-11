import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Detecção de conectividade compartilhada: expõe [isOnline] e checa a
/// internet de verdade (não só o rádio) ao detectar qualquer mudança de rede.
class ArgosConnectivityService {
  ArgosConnectivityService._() {
    _init();
  }

  static final ArgosConnectivityService instance = ArgosConnectivityService._();

  final Connectivity _connectivity = Connectivity();

  /// true assumido no boot pra não piscar a faixa de offline antes da
  /// primeira checagem real terminar.
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounce;

  /// Faz a checagem inicial e passa a escutar mudanças de conectividade
  /// (com debounce) pra reavaliar.
  void _init() {
    _checkInternet();

    _subscription = _connectivity.onConnectivityChanged.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 450), _checkInternet);
    });
  }

  /// Atualiza [isOnline] com o resultado de [hasRealInternet].
  Future<void> _checkInternet() async {
    isOnline.value = await hasRealInternet();
  }

  /// Refaz a checagem agora (usado pelo botão "Tentar reconectar").
  Future<void> recheckNow() => _checkInternet();

  /// Checa se há internet de fato: rádio conectado + lookup DNS bem-sucedido.
  Future<bool> hasRealInternet() async {
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
}

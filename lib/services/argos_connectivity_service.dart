import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Detecção de conectividade compartilhada -- antes vivia só dentro de
/// `_ArgosNetworkGateState`; o app hoje funciona híbrido (offline não
/// bloqueia mais nada, só avisa via faixa fina), e outras telas
/// (`InspectionsPage`) também precisam saber se estão online -- pra
/// esconder ações que exigem dado fresco (ranking) ou recusar uma
/// transação (check-in) com uma mensagem clara em vez de travar tentando.
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

  void _init() {
    _checkInternet();

    _subscription = _connectivity.onConnectivityChanged.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 450), _checkInternet);
    });
  }

  Future<void> _checkInternet() async {
    isOnline.value = await hasRealInternet();
  }

  /// Refaz a checagem agora (usado pelo botão "Tentar reconectar").
  Future<void> recheckNow() => _checkInternet();

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

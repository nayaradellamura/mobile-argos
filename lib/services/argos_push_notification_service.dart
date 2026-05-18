import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

@pragma('vm:entry-point')
Future<void> argosFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp();

  debugPrint('FCM background message: ${message.messageId}');
}

/// Serviço de notificações push do Argos.
///
/// Esta versão usa somente firebase_messaging para evitar conflitos de API
/// com flutter_local_notifications.
///
/// O que ela faz:
/// - pede permissão de notificação;
/// - salva o token FCM em userDevices/{uid}/tokens/{tokenId};
/// - atualiza o token quando ele muda;
/// - escuta mensagens em foreground/background;
/// - prepara o sinistroId recebido na notificação para navegação futura.
class ArgosPushNotificationService {
  ArgosPushNotificationService._();

  static final ArgosPushNotificationService instance =
      ArgosPushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _initialized = false;
  bool _listeningTokenRefresh = false;

  Future<void> initialize() async {
    if (_initialized) return;

    FirebaseMessaging.onBackgroundMessage(
      argosFirebaseMessagingBackgroundHandler,
    );

    await _requestPermission();
    await _configureForegroundPresentation();
    _listenForegroundMessages();
    _listenNotificationOpenedApp();
    await _handleInitialMessage();

    _initialized = true;
  }

  Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    debugPrint('Permissão FCM: ${settings.authorizationStatus}');
  }

  Future<void> _configureForegroundPresentation() async {
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  void _listenForegroundMessages() {
    FirebaseMessaging.onMessage.listen((message) {
      debugPrint('FCM foreground message: ${message.messageId}');
      debugPrint('Título: ${message.notification?.title}');
      debugPrint('Corpo: ${message.notification?.body}');
      debugPrint('Dados: ${message.data}');

      // Sem flutter_local_notifications, no Android a notificação recebida
      // com o app aberto pode não aparecer como popup do sistema.
      // Ela ainda chega aqui e pode ser usada futuramente para mostrar
      // um banner próprio dentro do app.
    });
  }

  void _listenNotificationOpenedApp() {
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final sinistroId = message.data['sinistroId']?.toString();

      debugPrint('App aberto pela notificação. sinistroId: $sinistroId');

      // Futuro:
      // navegar para a tela de resumo do sinistro.
    });
  }

  Future<void> _handleInitialMessage() async {
    final initialMessage = await _messaging.getInitialMessage();

    if (initialMessage == null) return;

    final sinistroId = initialMessage.data['sinistroId']?.toString();

    debugPrint('App iniciado pela notificação. sinistroId: $sinistroId');
  }

  Future<void> registerDeviceTokenForCurrentUser() async {
    final user = _auth.currentUser;

    if (user == null) {
      debugPrint('FCM: usuário não logado.');
      return;
    }

    final uid = user.uid;
    final email = user.email?.trim().toLowerCase() ?? '';

    final token = await _messaging.getToken();

    if (token == null || token.trim().isEmpty) {
      debugPrint('FCM: token não gerado.');
      return;
    }

    await _saveToken(uid: uid, email: email, token: token);

    if (!_listeningTokenRefresh) {
      _listeningTokenRefresh = true;

      _messaging.onTokenRefresh.listen((newToken) async {
        final refreshedUser = _auth.currentUser;

        if (refreshedUser == null) return;

        await _saveToken(
          uid: refreshedUser.uid,
          email: refreshedUser.email?.trim().toLowerCase() ?? '',
          token: newToken,
        );
      });
    }
  }

  Future<void> unregisterCurrentDeviceToken() async {
    final user = _auth.currentUser;

    if (user == null) return;

    final token = await _messaging.getToken();

    if (token == null || token.trim().isEmpty) return;

    final tokenId = Uri.encodeComponent(token);

    await _firestore
        .collection('userDevices')
        .doc(user.uid)
        .collection('tokens')
        .doc(tokenId)
        .delete()
        .catchError((_) {});
  }

  Future<void> _saveToken({
    required String uid,
    required String email,
    required String token,
  }) async {
    final tokenId = Uri.encodeComponent(token);

    await _firestore
        .collection('userDevices')
        .doc(uid)
        .collection('tokens')
        .doc(tokenId)
        .set({
          'token': token,
          'tokenId': tokenId,
          'uid': uid,
          'email': email,
          'platform': Platform.operatingSystem,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    debugPrint('FCM token salvo para UID $uid');
  }
}

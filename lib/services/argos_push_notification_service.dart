import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../firebase_options.dart';

@pragma('vm:entry-point')
Future<void> argosFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

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
  final ValueNotifier<ArgosAppNotification?> foregroundNotification =
      ValueNotifier<ArgosAppNotification?>(null);
  final ValueNotifier<String?> openedSinistroId = ValueNotifier<String?>(null);

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
      final notification = ArgosAppNotification.fromRemoteMessage(message);

      debugPrint('FCM foreground message: ${message.messageId}');
      debugPrint('Título: ${message.notification?.title}');
      debugPrint('Corpo: ${message.notification?.body}');
      debugPrint('Dados: ${message.data}');

      foregroundNotification.value = notification;

      Future.delayed(const Duration(seconds: 7), () {
        if (foregroundNotification.value == notification) {
          foregroundNotification.value = null;
        }
      });
    });
  }

  void _listenNotificationOpenedApp() {
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final sinistroId = _sinistroIdFromMessage(message);

      debugPrint('App aberto pela notificação. sinistroId: $sinistroId');

      if (sinistroId != null && sinistroId.isNotEmpty) {
        openedSinistroId.value = sinistroId;
      }
    });
  }

  Future<void> _handleInitialMessage() async {
    final initialMessage = await _messaging.getInitialMessage();

    if (initialMessage == null) return;

    final sinistroId = _sinistroIdFromMessage(initialMessage);

    debugPrint('App iniciado pela notificação. sinistroId: $sinistroId');

    if (sinistroId != null && sinistroId.isNotEmpty) {
      openedSinistroId.value = sinistroId;
    }
  }

  void clearForegroundNotification() {
    foregroundNotification.value = null;
  }

  void clearOpenedSinistroId() {
    openedSinistroId.value = null;
  }

  String? _sinistroIdFromMessage(RemoteMessage message) {
    return message.data['sinistroId']?.toString().trim();
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
          'permissionStatus':
              (await _messaging.getNotificationSettings())
                  .authorizationStatus
                  .name,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    debugPrint('FCM token salvo para UID $uid');
  }
}

class ArgosAppNotification {
  final String title;
  final String body;
  final String? sinistroId;
  final String type;

  const ArgosAppNotification({
    required this.title,
    required this.body,
    required this.type,
    this.sinistroId,
  });

  factory ArgosAppNotification.fromRemoteMessage(RemoteMessage message) {
    final data = message.data;

    return ArgosAppNotification(
      title: message.notification?.title?.trim().isNotEmpty == true
          ? message.notification!.title!.trim()
          : data['title']?.toString().trim().isNotEmpty == true
              ? data['title'].toString().trim()
              : 'Atualização no Argos',
      body: message.notification?.body?.trim().isNotEmpty == true
          ? message.notification!.body!.trim()
          : data['body']?.toString().trim().isNotEmpty == true
              ? data['body'].toString().trim()
              : 'Uma vistoria recebeu uma nova atualização.',
      type: data['notificationType']?.toString().trim().isNotEmpty == true
          ? data['notificationType'].toString().trim()
          : data['type']?.toString().trim() ?? 'argos_update',
      sinistroId: data['sinistroId']?.toString().trim(),
    );
  }
}

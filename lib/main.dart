import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/argos_push_notification_service.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'features/splash/splash_page.dart';
import 'firebase_options.dart';

import 'features/auth/login_page.dart';
import 'app/main_shell.dart';
import 'package:argos_app/features/network/argos_network_gate.dart';
import 'features/inspections/data/inspections_prefetch_service.dart';
import 'services/bulk_sync_coordinator.dart';
import 'services/session_context_service.dart';

// Ponto de entrada: inicializa Firebase, notificações push e sync em background.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseMessaging.onBackgroundMessage(
    argosFirebaseMessagingBackgroundHandler,
  );

  await ArgosPushNotificationService.instance.initialize();

  // Instancia cedo pra escutar conectividade e sincronizar vistorias
  // pendentes desde o boot, em qualquer tela.
  BulkSyncCoordinator.instance;

  runApp(const ArgosApp());
}

// Widget raiz do app: tema, overlay de notificações e gate de conectividade.
class ArgosApp extends StatelessWidget {
  const ArgosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Argos',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF3FBFF),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0057C0),
          secondary: Color(0xFF005EB2),
          surface: Color(0xFFF3FBFF),
        ),
        textTheme: GoogleFonts.interTextTheme(),
        useMaterial3: true,
      ),
      builder: (context, child) {
        return ArgosNotificationOverlay(
          child: ArgosNetworkGate(child: child ?? const SizedBox.shrink()),
        );
      },
      home: const StartupGate(),
    );
  }
}

// Sobrepõe o banner de notificação em primeiro plano por cima do app inteiro.
class ArgosNotificationOverlay extends StatelessWidget {
  final Widget child;

  const ArgosNotificationOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ArgosAppNotification?>(
      valueListenable:
          ArgosPushNotificationService.instance.foregroundNotification,
      builder: (context, notification, _) {
        return Stack(
          children: [
            child,
            if (notification != null)
              Positioned(
                left: 14,
                right: 14,
                top: MediaQuery.of(context).padding.top + 10,
                child: _ArgosForegroundNotificationBanner(
                  notification: notification,
                  onDismiss: ArgosPushNotificationService
                      .instance.clearForegroundNotification,
                  onTap: () {
                    final sinistroId = notification.sinistroId?.trim() ?? '';

                    ArgosPushNotificationService.instance
                        .clearForegroundNotification();

                    if (sinistroId.isNotEmpty) {
                      ArgosPushNotificationService
                          .instance.openedSinistroId.value = sinistroId;
                    }
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

// Banner visual de uma notificação recebida com o app em primeiro plano.
class _ArgosForegroundNotificationBanner extends StatelessWidget {
  final ArgosAppNotification notification;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  const _ArgosForegroundNotificationBanner({
    required this.notification,
    required this.onDismiss,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Dismissible(
        key: ValueKey('${notification.type}_${notification.sinistroId}_${notification.title}'),
        direction: DismissDirection.up,
        onDismissed: (_) => onDismiss(),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF0057C0).withOpacity(.10)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.14),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5F6FF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.notifications_active_outlined,
                    color: Color(0xFF0057C0),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        notification.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF1F2937),
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        notification.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF414755),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18),
                  color: const Color(0xFF6B7280),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Gate de inicialização: mostra a SplashPage uma vez e depois alterna entre
// LoginPage e MainShell conforme o estado de autenticação.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  StreamSubscription<User?>? _authSubscription;

  User? _user;

  bool _splashCompleted = false;
  bool _authResolved = false;
  bool _startupGateReleased = false;

  bool _isResolvingProfile = false;
  bool _profileCompletionRequired = false;

  bool _warmUpCompleted = false;
  Timer? _warmUpTimeoutTimer;

  int _authChangeToken = 0;

  @override
  void initState() {
    super.initState();

    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
      _handleAuthChanged,
      onError: (error) {
        debugPrint('Auth state error: $error');

        if (!mounted) return;

        setState(() {
          _user = null;
          _authResolved = true;
          _isResolvingProfile = false;
          _profileCompletionRequired = false;
        });

        _tryReleaseStartupGate();
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _warmUpTimeoutTimer?.cancel();
    super.dispose();
  }

  // Reage a mudanças de autenticação, disparando o pré-carregamento de
  // vistorias e a checagem de perfil completo.
  Future<void> _handleAuthChanged(User? authUser) async {
    final token = ++_authChangeToken;

    if (!mounted) return;

    if (authUser == null) {
      setState(() {
        _user = null;
        _authResolved = true;
        _isResolvingProfile = false;
        _profileCompletionRequired = false;
      });

      _tryReleaseStartupGate();
      return;
    }

    setState(() {
      _user = authUser;
      _authResolved = true;
      _isResolvingProfile = true;
    });

    _tryReleaseStartupGate();

    unawaited(_warmUpInspections());
    _warmUpTimeoutTimer =
        Timer(const Duration(seconds: 3), _markWarmUpCompleted);

    final profileRequired = await _loadProfileCompletionRequired(authUser);

    if (!mounted || token != _authChangeToken) return;

    setState(() {
      _user = authUser;
      _profileCompletionRequired = profileRequired;
      _isResolvingProfile = false;
    });

    _tryReleaseStartupGate();
  }

  // Pré-carrega vistorias e fotos de perfil durante a splash, com teto de
  // segurança em _warmUpTimeoutTimer pra não travar o login numa rede ruim.
  Future<void> _warmUpInspections() async {
    try {
      final session = await SessionContextService.instance.resolve();
      await InspectionsPrefetchService.instance.warmUp(session.credenciadoId);
    } catch (_) {
    } finally {
      _markWarmUpCompleted();
    }
  }

  // Marca o pré-carregamento como concluído (por sucesso, falha ou timeout).
  void _markWarmUpCompleted() {
    _warmUpTimeoutTimer?.cancel();

    if (!mounted || _warmUpCompleted) return;

    setState(() {
      _warmUpCompleted = true;
    });

    _tryReleaseStartupGate();
  }

  // Checa se o usuário precisa completar o cadastro, tentando users/{email},
  // depois users/{uid}, depois uma query por uid.
  Future<bool> _loadProfileCompletionRequired(User user) async {
    final email = (user.email ?? '').trim().toLowerCase();

    if (email.isEmpty) {
      return true;
    }

    try {
      final db = FirebaseFirestore.instance;

      final byEmail = await _getUserDocCacheFirst(
        db.collection('users').doc(email),
      );

      if (byEmail.exists) {
        final data = byEmail.data() ?? {};
        return data['cadastroCompleto'] != true;
      }

      final byUid = await _getUserDocCacheFirst(
        db.collection('users').doc(user.uid),
      );

      if (byUid.exists) {
        final data = byUid.data() ?? {};
        return data['cadastroCompleto'] != true;
      }

      final query = await db
          .collection('users')
          .where('uid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        final data = query.docs.first.data();
        return data['cadastroCompleto'] != true;
      }

      return true;
    } catch (error) {
      debugPrint('Startup profile completion check error: $error');
      return true;
    }
  }

  // Lê um documento tentando primeiro o cache local do Firestore, caindo
  // para o servidor se não houver nada em cache ainda.
  Future<DocumentSnapshot<Map<String, dynamic>>> _getUserDocCacheFirst(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    try {
      final cached = await ref.get(const GetOptions(source: Source.cache));

      if (cached.exists) return cached;
    } catch (_) {}

    return ref.get();
  }

  // Marca a splash como concluída (callback do SplashPage).
  void _finishSplash() {
    if (!mounted || _splashCompleted) return;

    setState(() {
      _splashCompleted = true;
    });

    _tryReleaseStartupGate();
  }

  // Libera a splash só depois que ela terminou de tocar, o auth resolveu, o
  // perfil carregou (se logado) e o pré-carregamento terminou (ou expirou).
  void _tryReleaseStartupGate() {
    if (!mounted || _startupGateReleased) return;

    if (!_splashCompleted) return;
    if (!_authResolved) return;

    if (_user != null && _isResolvingProfile) return;

    if (_user != null && !_warmUpCompleted) return;

    setState(() {
      _startupGateReleased = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_startupGateReleased) {
      return SplashPage(
        key: const ValueKey('startup-splash'),
        onComplete: _finishSplash,
      );
    }

    final shouldShowMainShell = _user != null && !_isResolvingProfile;

    return Scaffold(
      body: Stack(
        children: [
          const _ArgosBackground(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: shouldShowMainShell
                ? MainShell(
                    key: const ValueKey('main-shell'),
                    user: _user!,
                    initialProfileCompletionRequired:
                        _profileCompletionRequired,
                  )
                : const LoginPage(key: ValueKey('login-page')),
          ),
        ],
      ),
    );
  }
}

// Gradiente de fundo usado atrás da splash/login/main shell.
class _ArgosBackground extends StatelessWidget {
  const _ArgosBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFDEF1FA), Color(0xFFF3FBFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }
}

// lib/main.dart

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseMessaging.onBackgroundMessage(
    argosFirebaseMessagingBackgroundHandler,
  );

  await ArgosPushNotificationService.instance.initialize();

  runApp(const ArgosApp());
}

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
        return ArgosNetworkGate(child: child ?? const SizedBox.shrink());
      },
      home: const StartupGate(),
    );
  }
}

/// Gate único de inicialização.
///
/// Mostra a SplashPage uma única vez na abertura do app.
/// Depois que a splash inicial saiu, o app continua ouvindo mudanças de login.
/// Assim, quando o usuário faz login pelo Google/e-mail, a tela troca para o
/// MainShell sem precisar reiniciar a SplashPage e sem mostrar roda intermediária.
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
    super.dispose();
  }

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

    final profileRequired = await _loadProfileCompletionRequired(authUser);

    if (!mounted || token != _authChangeToken) return;

    setState(() {
      _user = authUser;
      _profileCompletionRequired = profileRequired;
      _isResolvingProfile = false;
    });

    _tryReleaseStartupGate();
  }

  Future<bool> _loadProfileCompletionRequired(User user) async {
    final email = (user.email ?? '').trim().toLowerCase();

    if (email.isEmpty) {
      return true;
    }

    try {
      final db = FirebaseFirestore.instance;

      final byEmail = await db.collection('users').doc(email).get();

      if (byEmail.exists) {
        final data = byEmail.data() ?? {};
        return data['cadastroCompleto'] != true;
      }

      final byUid = await db.collection('users').doc(user.uid).get();

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

  void _finishSplash() {
    if (!mounted || _splashCompleted) return;

    setState(() {
      _splashCompleted = true;
    });

    _tryReleaseStartupGate();
  }

  void _tryReleaseStartupGate() {
    if (!mounted || _startupGateReleased) return;

    if (!_splashCompleted) return;
    if (!_authResolved) return;

    // Na abertura com usuário já logado, segura a splash até o perfil carregar.
    // Depois que o gate já saiu da splash, novos logins não voltam para splash.
    if (_user != null && _isResolvingProfile) return;

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

// lib/main.dart

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
/// Ele mantém a SplashPage visível enquanto:
/// - a animação da splash termina;
/// - o Firebase Auth resolve o usuário;
/// - se estiver logado, o status de cadastro do perfil é carregado.
///
/// Assim não existe segunda SplashPage nem tela intermediária com roda girando.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  User? _user;
  bool _splashCompleted = false;
  bool _bootstrapCompleted = false;
  bool _profileCompletionRequired = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final authUser = FirebaseAuth.instance.currentUser ??
        await FirebaseAuth.instance.authStateChanges().first;

    bool profileRequired = false;

    if (authUser != null) {
      profileRequired = await _loadProfileCompletionRequired(authUser);
    }

    if (!mounted) return;

    setState(() {
      _user = authUser;
      _profileCompletionRequired = profileRequired;
      _bootstrapCompleted = true;
    });
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
  }

  @override
  Widget build(BuildContext context) {
    final canLeaveSplash = _splashCompleted && _bootstrapCompleted;

    if (!canLeaveSplash) {
      return SplashPage(
        key: const ValueKey('startup-splash'),
        onComplete: _finishSplash,
      );
    }

    final user = _user;

    return Scaffold(
      body: Stack(
        children: [
          const _ArgosBackground(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: user == null
                ? const LoginPage(key: ValueKey('login-page'))
                : MainShell(
                    key: const ValueKey('main-shell'),
                    user: user,
                    initialProfileCompletionRequired:
                        _profileCompletionRequired,
                  ),
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

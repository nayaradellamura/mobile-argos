// lib/main.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'features/splash/splash_page.dart';
import 'firebase_options.dart';

import 'features/auth/login_page.dart';
import 'app/main_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

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
      home: const StartupGate(),
    );
  }
}

class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool showSplash = true;

  void finishSplash() {
    setState(() {
      showSplash = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      child: showSplash
          ? SplashPage(key: const ValueKey('splash'), onComplete: finishSplash)
          : const AuthGate(key: ValueKey('auth-gate')),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _ArgosLoadingScreen();
        }

        final user = snapshot.data;

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
                    : MainShell(key: const ValueKey('main-shell'), user: user),
              ),
            ],
          ),
        );
      },
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

class _ArgosLoadingScreen extends StatelessWidget {
  const _ArgosLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Stack(
        children: [
          _ArgosBackground(),
          Center(child: CircularProgressIndicator(color: Color(0xFF0057C0))),
        ],
      ),
    );
  }
}

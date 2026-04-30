import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final formKey = GlobalKey<FormState>();

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final accessEmailController = TextEditingController();

  bool isLoading = false;
  bool obscurePassword = true;

  static const String webClientId = '';

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    accessEmailController.dispose();
    super.dispose();
  }

  void _showSnack(
    String message, {
    Color backgroundColor = const Color(0xFF0057C0),
  }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  String _authErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-disabled':
        return 'Usuário bloqueado pelo administrador. Contate o suporte.';
      case 'user-not-found':
        return 'E-mail não cadastrado. Solicite o primeiro acesso ao administrador.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'E-mail ou senha inválidos.';
      case 'invalid-email':
        return 'E-mail inválido.';
      case 'too-many-requests':
        return 'Muitas tentativas. Aguarde alguns minutos e tente novamente.';
      case 'network-request-failed':
        return 'Falha de conexão. Verifique sua internet.';
      default:
        return e.message ?? 'Erro ao autenticar.';
    }
  }

  Future<void> signInWithEmailAndPassword() async {
    if (isLoading) return;

    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isLoading = true;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('Email login error: ${e.code} - ${e.message}');

      if (e.code == 'user-disabled') {
        await FirebaseAuth.instance.signOut();
      }

      _showSnack(_authErrorMessage(e), backgroundColor: Colors.redAccent);
    } catch (e) {
      debugPrint('Email login unexpected error: $e');

      _showSnack(
        'Erro inesperado ao fazer login.',
        backgroundColor: Colors.redAccent,
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> signInWithGoogle() async {
    if (isLoading) return;

    FocusScope.of(context).unfocus();

    setState(() {
      isLoading = true;
    });

    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );

      await googleSignIn.signOut();

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

      if (googleUser == null) {
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      if (googleAuth.idToken == null) {
        throw FirebaseAuthException(
          code: 'missing-id-token',
          message:
              'O Google não retornou idToken. Confira SHA-1, SHA-256, OAuth Client e google-services.json.',
        );
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      debugPrint('Google Firebase Auth Error: ${e.code} - ${e.message}');

      if (e.code == 'user-disabled') {
        await FirebaseAuth.instance.signOut();
        await GoogleSignIn().signOut();
      }

      _showSnack(_authErrorMessage(e), backgroundColor: Colors.redAccent);
    } catch (e) {
      debugPrint('Google Sign-In Error: $e');

      _showSnack(
        'Erro ao fazer login com Google: $e',
        backgroundColor: Colors.redAccent,
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> sendAccessEmail({required bool firstAccess}) async {
    if (isLoading) return;

    FocusScope.of(context).unfocus();

    accessEmailController.text = emailController.text.trim();

    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(
            firstAccess ? 'Primeiro acesso' : 'Esqueceu a senha?',
            style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                firstAccess
                    ? 'Informe seu e-mail cadastrado para receber um link de definição de senha.'
                    : 'Informe seu e-mail cadastrado para receber um link de redefinição de senha.',
                style: const TextStyle(color: Color(0xFF414755)),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: accessEmailController,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'E-mail',
                  prefixIcon: const Icon(Icons.email_outlined),
                  filled: true,
                  fillColor: const Color(0xFFE5F6FF),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(accessEmailController.text.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0057C0),
                foregroundColor: Colors.white,
              ),
              child: const Text('Enviar'),
            ),
          ],
        );
      },
    );

    if (email == null || email.isEmpty) return;

    if (!email.contains('@')) {
      _showSnack(
        'Informe um e-mail válido.',
        backgroundColor: Colors.redAccent,
      );
      return;
    }

    if (!mounted) return;

    setState(() {
      isLoading = true;
    });

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);

      _showSnack(
        firstAccess
            ? 'Enviamos um link para definição de senha. Verifique seu e-mail.'
            : 'Enviamos um link para redefinir sua senha. Verifique seu e-mail.',
        backgroundColor: Colors.green,
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('Password email error: ${e.code} - ${e.message}');

      if (e.code == 'user-disabled') {
        _showSnack(
          'Usuário bloqueado pelo administrador. Contate o suporte.',
          backgroundColor: Colors.redAccent,
        );
        return;
      }

      if (e.code == 'user-not-found') {
        _showSnack(
          'Esse e-mail ainda não está cadastrado. Solicite liberação ao administrador.',
          backgroundColor: Colors.redAccent,
        );
        return;
      }

      _showSnack(_authErrorMessage(e), backgroundColor: Colors.redAccent);
    } catch (e) {
      debugPrint('Password email unexpected error: $e');

      _showSnack(
        'Erro ao enviar e-mail. Tente novamente.',
        backgroundColor: Colors.redAccent,
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              children: [
                const SizedBox(height: 32),

                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: const Color(0xFF006FF1),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withOpacity(.22),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.remove_red_eye,
                    color: Colors.white,
                    size: 42,
                  ),
                ),

                const SizedBox(height: 24),

                Text(
                  'Argos',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 52,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0057C0),
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'VISTORIAS INTELIGENTES',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 10,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF414755),
                  ),
                ),

                const SizedBox(height: 42),

                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.92),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: Colors.black.withOpacity(.05)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.05),
                        blurRadius: 40,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Form(
                    key: formKey,
                    child: Column(
                      children: [
                        Text(
                          'Acesse sua conta',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 8),

                        const Text(
                          'Entre com e-mail e senha ou utilize SSO Google',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF414755)),
                        ),

                        const SizedBox(height: 28),

                        TextFormField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: 'E-mail',
                            prefixIcon: const Icon(Icons.email_outlined),
                            filled: true,
                            fillColor: const Color(0xFFE5F6FF),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          validator: (value) {
                            final email = value?.trim() ?? '';

                            if (email.isEmpty) {
                              return 'Informe seu e-mail.';
                            }

                            if (!email.contains('@')) {
                              return 'Informe um e-mail válido.';
                            }

                            return null;
                          },
                        ),

                        const SizedBox(height: 16),

                        TextFormField(
                          controller: passwordController,
                          obscureText: obscurePassword,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) {
                            signInWithEmailAndPassword();
                          },
                          decoration: InputDecoration(
                            labelText: 'Senha',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(() {
                                  obscurePassword = !obscurePassword;
                                });
                              },
                              icon: Icon(
                                obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                            filled: true,
                            fillColor: const Color(0xFFE5F6FF),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          validator: (value) {
                            final password = value?.trim() ?? '';

                            if (password.isEmpty) {
                              return 'Informe sua senha.';
                            }

                            if (password.length < 6) {
                              return 'A senha deve ter pelo menos 6 caracteres.';
                            }

                            return null;
                          },
                        ),

                        const SizedBox(height: 20),

                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0057C0),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(
                                0xFF0057C0,
                              ).withOpacity(.65),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            onPressed: isLoading
                                ? null
                                : signInWithEmailAndPassword,
                            icon: isLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              isLoading ? 'Entrando...' : 'Entrar',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 14),

                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 0,
                          children: [
                            TextButton(
                              onPressed: isLoading
                                  ? null
                                  : () {
                                      sendAccessEmail(firstAccess: true);
                                    },
                              child: const Text('Primeiro acesso'),
                            ),
                            TextButton(
                              onPressed: isLoading
                                  ? null
                                  : () {
                                      sendAccessEmail(firstAccess: false);
                                    },
                              child: const Text('Esqueceu a senha?'),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                'OU',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: OutlinedButton.icon(
                            onPressed: isLoading ? null : signInWithGoogle,
                            icon: const Icon(Icons.g_mobiledata, size: 28),
                            label: const Text(
                              'Continuar com Google',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF0057C0),
                              backgroundColor: const Color(0xFFE5F6FF),
                              side: BorderSide(
                                color: Colors.black.withOpacity(.06),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        const Text(
                          'Acesso exclusivo para mecânicos credenciados.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF414755),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _statusDot(),
                    const SizedBox(width: 8),
                    const Text(
                      'SISTEMA ONLINE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 24),
                    const Icon(Icons.security, size: 14),
                    const SizedBox(width: 6),
                    const Text(
                      'FIREBASE PROTEGIDO',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: Colors.green,
        shape: BoxShape.circle,
      ),
    );
  }
}

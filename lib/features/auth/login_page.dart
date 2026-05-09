import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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

  static const String usersCollection = 'users';

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

  String _normalizeEmail(String email) {
    return email.trim().toLowerCase();
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
      case 'missing-id-token':
        return 'O Google não retornou idToken. Confira as configurações do Firebase/Google Sign-In.';
      case 'account-exists-with-different-credential':
        return 'Já existe uma conta com este e-mail usando outro método de login.';
      case 'credential-already-in-use':
        return 'Essa credencial já está vinculada a outra conta.';
      case 'provider-already-linked':
        return 'Esse método de login já está vinculado à sua conta.';
      case 'google-email-mismatch':
        return 'A conta Google selecionada é diferente do e-mail informado.';
      case 'google-sign-in-cancelled':
        return 'Login com Google cancelado.';
      default:
        return e.message ?? 'Erro ao autenticar.';
    }
  }

  String _accessStatusMessage(String status) {
    switch (status) {
      case 'pendente':
        return 'Seu acesso está pendente de aprovação pelo administrador.';
      case 'bloqueado':
        return 'Seu acesso foi bloqueado pelo administrador.';
      default:
        return 'Você não possui permissão para acessar o sistema.';
    }
  }

  String _tipoAcessoFromProvider(String provider) {
    return provider == 'google' ? 'sso_google' : 'email_senha';
  }

  String _providerIdFromProvider(String provider) {
    return provider == 'google'
        ? GoogleAuthProvider.PROVIDER_ID
        : EmailAuthProvider.PROVIDER_ID;
  }

  String _mergedTipoAcesso({
    required String currentTipoAcesso,
    required String newTipoAcesso,
  }) {
    final hasPassword =
        currentTipoAcesso.contains('email_senha') ||
        currentTipoAcesso.contains('password') ||
        newTipoAcesso == 'email_senha';

    final hasGoogle =
        currentTipoAcesso.contains('sso_google') ||
        currentTipoAcesso.contains('google') ||
        newTipoAcesso == 'sso_google';

    if (hasPassword && hasGoogle) {
      return 'email_senha_sso_google';
    }

    if (hasGoogle) {
      return 'sso_google';
    }

    return 'email_senha';
  }

  Future<void> _signOutDeniedAccess({bool google = false}) async {
    await FirebaseAuth.instance.signOut();

    if (google) {
      try {
        await GoogleSignIn().signOut();
      } catch (_) {
        // Ignora erro ao sair da conta Google.
      }
    }
  }

  Future<bool> _validateUserAccessAfterLogin(
    User user, {
    required String provider,
  }) async {
    final email = _normalizeEmail(user.email ?? '');
    final newTipoAcesso = _tipoAcessoFromProvider(provider);
    final newProviderId = _providerIdFromProvider(provider);

    if (email.isEmpty) {
      await _signOutDeniedAccess(google: provider == 'google');

      _showSnack(
        'Não foi possível identificar o e-mail da conta.',
        backgroundColor: Colors.redAccent,
      );

      return false;
    }

    final userRef = FirebaseFirestore.instance
        .collection(usersCollection)
        .doc(email);

    final userSnap = await userRef.get();

    if (!userSnap.exists) {
      await userRef.set({
        'uid': user.uid,
        'authUid': user.uid,
        'email': email,
        'emailKey': email,
        'nome': user.displayName ?? '',
        'displayName': user.displayName ?? '',
        'photoURL': user.photoURL ?? '',
        'foto': user.photoURL ?? '',
        'telefone': '',
        'empresa': '',
        'departamento': '',
        'provider': provider,
        'tipoAcesso': newTipoAcesso,
        'providers': FieldValue.arrayUnion([newTipoAcesso]),
        'authProviderIds': FieldValue.arrayUnion([newProviderId]),
        'status': 'ativo',
        'origem': provider == 'google' ? 'sso_google' : 'login_email_senha',
        'origens': FieldValue.arrayUnion([
          provider == 'google' ? 'sso_google' : 'login_email_senha',
        ]),
        'criadoEm': FieldValue.serverTimestamp(),
        'atualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _signOutDeniedAccess(google: provider == 'google');

      _showSnack(
        'Solicitação de acesso criada. Aguarde aprovação do administrador.',
        backgroundColor: Colors.green,
      );

      return false;
    }

    final data = userSnap.data() ?? {};
    final status = data['status']?.toString() ?? 'pendente';
    final currentTipoAcesso = data['tipoAcesso']?.toString() ?? '';

    final mergedTipoAcesso = _mergedTipoAcesso(
      currentTipoAcesso: currentTipoAcesso,
      newTipoAcesso: newTipoAcesso,
    );

    // Nova regra:
    // Mesmo e-mail pode usar e-mail/senha e Google.
    // Não bloqueia mais troca de modalidade.
    // O documento continua único em users/{email_normalizado}.
    await userRef.set({
      'uid': user.uid,
      'authUid': user.uid,
      'email': email,
      'emailKey': email,
      'provider': provider,
      'tipoAcesso': mergedTipoAcesso,
      'providers': FieldValue.arrayUnion([newTipoAcesso]),
      'authProviderIds': FieldValue.arrayUnion([newProviderId]),
      'displayName':
          user.displayName ?? data['displayName'] ?? data['nome'] ?? '',
      'nome': data['nome'] ?? user.displayName ?? '',
      'photoURL': user.photoURL ?? data['photoURL'] ?? '',
      'foto': user.photoURL ?? data['foto'] ?? '',
      'ultimoLoginEm': FieldValue.serverTimestamp(),
      'ultimoProvider': provider,
      'atualizadoEm': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (status == 'ativo') {
      await userRef.set({
        'ultimoAcesso': FieldValue.serverTimestamp(),
        'atualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return true;
    }

    await _signOutDeniedAccess(google: provider == 'google');

    _showSnack(
      _accessStatusMessage(status),
      backgroundColor: status == 'bloqueado'
          ? Colors.redAccent
          : const Color(0xFF0057C0),
    );

    return false;
  }

  Future<String?> _showPasswordToLinkGoogleDialog({
    required String email,
  }) async {
    final controller = TextEditingController();

    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool obscure = true;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(
                'Vincular conta Google',
                style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Já existe uma conta com o e-mail $email. Digite a senha atual para vincular o login com Google à mesma conta.',
                    style: const TextStyle(color: Color(0xFF414755)),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: controller,
                    obscureText: obscure,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Senha atual',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setDialogState(() {
                            obscure = !obscure;
                          });
                        },
                        icon: Icon(
                          obscure
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
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(null);
                  },
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(controller.text);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0057C0),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Vincular'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    return password;
  }

  Future<bool> _showConfirmLinkPasswordToGoogleDialog({
    required String email,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(
            'Vincular senha',
            style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Este e-mail parece estar cadastrado com Google. Deseja entrar com Google e vincular a senha informada para acessar também por e-mail e senha?',
            style: const TextStyle(color: Color(0xFF414755)),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0057C0),
                foregroundColor: Colors.white,
              ),
              child: const Text('Entrar com Google'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<UserCredential> _linkGoogleToEmailPasswordAccount({
    required String email,
    required String password,
    required AuthCredential googleCredential,
  }) async {
    final emailCredential = await FirebaseAuth.instance
        .signInWithEmailAndPassword(email: email, password: password);

    final user = emailCredential.user;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-null',
        message: 'Não foi possível carregar os dados do usuário.',
      );
    }

    try {
      return await user.linkWithCredential(googleCredential);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'provider-already-linked' ||
          e.code == 'credential-already-in-use') {
        return emailCredential;
      }

      rethrow;
    }
  }

  Future<UserCredential> _signInWithGoogleAndLinkPassword({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = _normalizeEmail(email);

    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
      serverClientId: webClientId.isEmpty ? null : webClientId,
    );

    await googleSignIn.signOut();

    final googleUser = await googleSignIn.signIn();

    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'google-sign-in-cancelled',
        message: 'Login com Google cancelado.',
      );
    }

    final googleEmail = _normalizeEmail(googleUser.email);

    if (googleEmail != normalizedEmail) {
      await googleSignIn.signOut();

      throw FirebaseAuthException(
        code: 'google-email-mismatch',
        message: 'A conta Google selecionada é diferente do e-mail informado.',
      );
    }

    final googleAuth = await googleUser.authentication;

    if (googleAuth.idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-id-token',
        message:
            'O Google não retornou idToken. Confira SHA-1, SHA-256, OAuth Client e google-services.json.',
      );
    }

    final googleCredential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final firebaseCredential = await FirebaseAuth.instance.signInWithCredential(
      googleCredential,
    );

    final user = firebaseCredential.user;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-null',
        message: 'Não foi possível carregar os dados do usuário Google.',
      );
    }

    final passwordCredential = EmailAuthProvider.credential(
      email: normalizedEmail,
      password: password,
    );

    try {
      return await user.linkWithCredential(passwordCredential);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'provider-already-linked' ||
          e.code == 'email-already-in-use' ||
          e.code == 'credential-already-in-use') {
        return firebaseCredential;
      }

      rethrow;
    }
  }

  Future<void> signInWithEmailAndPassword() async {
    if (isLoading) return;

    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }

    FocusScope.of(context).unfocus();

    final email = _normalizeEmail(emailController.text);
    final password = passwordController.text.trim();

    setState(() {
      isLoading = true;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;

      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-null',
          message: 'Não foi possível carregar os dados do usuário.',
        );
      }

      await _validateUserAccessAfterLogin(user, provider: 'password');
    } on FirebaseAuthException catch (e) {
      debugPrint('Email login error: ${e.code} - ${e.message}');

      if (e.code == 'user-disabled') {
        await FirebaseAuth.instance.signOut();
        _showSnack(_authErrorMessage(e), backgroundColor: Colors.redAccent);
        return;
      }

      if (e.code == 'invalid-credential' || e.code == 'wrong-password') {
        try {
          final userRef = FirebaseFirestore.instance
              .collection(usersCollection)
              .doc(email);

          final userSnap = await userRef.get();
          final data = userSnap.data() ?? {};

          final tipoAcesso = data['tipoAcesso']?.toString() ?? '';
          final provider = data['provider']?.toString() ?? '';
          final ultimoProvider = data['ultimoProvider']?.toString() ?? '';

          final providersRaw = data['providers'];
          final authProviderIdsRaw = data['authProviderIds'];

          final providers = providersRaw is List
              ? providersRaw.map((item) => item.toString()).toList()
              : <String>[];

          final authProviderIds = authProviderIdsRaw is List
              ? authProviderIdsRaw.map((item) => item.toString()).toList()
              : <String>[];

          final hasGoogleProvider =
              tipoAcesso.contains('sso_google') ||
              tipoAcesso.contains('google') ||
              provider == 'google' ||
              ultimoProvider == 'google' ||
              providers.contains('sso_google') ||
              providers.contains('google') ||
              authProviderIds.contains(GoogleAuthProvider.PROVIDER_ID);

          if (hasGoogleProvider) {
            final shouldLink = await _showConfirmLinkPasswordToGoogleDialog(
              email: email,
            );

            if (!shouldLink) {
              _showSnack(
                'Use o botão Continuar com Google para acessar esta conta.',
                backgroundColor: const Color(0xFF0057C0),
              );
              return;
            }

            final linkedCredential = await _signInWithGoogleAndLinkPassword(
              email: email,
              password: password,
            );

            final user = linkedCredential.user;

            if (user == null) {
              throw FirebaseAuthException(
                code: 'user-null',
                message: 'Não foi possível carregar os dados do usuário.',
              );
            }

            _showSnack(
              'Senha vinculada à conta Google com sucesso.',
              backgroundColor: Colors.green,
            );

            await _validateUserAccessAfterLogin(user, provider: 'password');
            return;
          }
        } catch (linkError) {
          debugPrint('Email -> Google link flow error: $linkError');

          if (linkError is FirebaseAuthException) {
            _showSnack(
              _authErrorMessage(linkError),
              backgroundColor: Colors.redAccent,
            );
            return;
          }
        }
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

    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
      serverClientId: webClientId.isEmpty ? null : webClientId,
    );

    try {
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

      UserCredential firebaseCredential;

      try {
        firebaseCredential = await FirebaseAuth.instance.signInWithCredential(
          credential,
        );
      } on FirebaseAuthException catch (e) {
        if (e.code != 'account-exists-with-different-credential') {
          rethrow;
        }

        final email = _normalizeEmail(e.email ?? googleUser.email);

        if (email.isEmpty) {
          rethrow;
        }

        final password = await _showPasswordToLinkGoogleDialog(email: email);

        if (password == null || password.trim().isEmpty) {
          await googleSignIn.signOut();
          return;
        }

        firebaseCredential = await _linkGoogleToEmailPasswordAccount(
          email: email,
          password: password.trim(),
          googleCredential: credential,
        );

        _showSnack(
          'Conta Google vinculada com sucesso.',
          backgroundColor: Colors.green,
        );
      }

      final user = firebaseCredential.user;

      if (user == null) {
        throw FirebaseAuthException(
          code: 'user-null',
          message: 'Não foi possível carregar os dados do usuário Google.',
        );
      }

      await _validateUserAccessAfterLogin(user, provider: 'google');
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
                    ? 'Informe seu e-mail para solicitar liberação de acesso.'
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

    final normalizedEmail = _normalizeEmail(email);

    if (!normalizedEmail.contains('@')) {
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
      if (firstAccess) {
        final existingUserRef = FirebaseFirestore.instance
            .collection(usersCollection)
            .doc(normalizedEmail);
        final existingUserSnap = await existingUserRef.get();

        if (existingUserSnap.exists) {
          final existingData = existingUserSnap.data() ?? {};
          final existingStatus =
              existingData['status']?.toString() ?? 'pendente';

          if (existingStatus == 'ativo') {
            _showSnack(
              'Este e-mail já está liberado. Entre com o método usado anteriormente. Se quiser adicionar outro método, use a opção de vinculação no login.',
              backgroundColor: Colors.green,
            );
            return;
          }

          if (existingStatus == 'bloqueado') {
            _showSnack(
              'Este acesso está bloqueado pelo administrador.',
              backgroundColor: Colors.redAccent,
            );
            return;
          }

          _showSnack(
            'Sua solicitação já está pendente de aprovação.',
            backgroundColor: const Color(0xFF0057C0),
          );
          return;
        }

        await FirebaseFirestore.instance
            .collection(usersCollection)
            .doc(normalizedEmail)
            .set({
              'uid': '',
              'authUid': '',
              'email': normalizedEmail,
              'emailKey': normalizedEmail,
              'nome': '',
              'displayName': '',
              'photoURL': '',
              'foto': '',
              'telefone': '',
              'empresa': '',
              'departamento': '',
              'provider': 'password',
              'tipoAcesso': 'email_senha',
              'providers': FieldValue.arrayUnion(['email_senha']),
              'authProviderIds': FieldValue.arrayUnion([
                EmailAuthProvider.PROVIDER_ID,
              ]),
              'status': 'pendente',
              'origem': 'primeiro_acesso',
              'origens': FieldValue.arrayUnion(['primeiro_acesso']),
              'criadoEm': FieldValue.serverTimestamp(),
              'atualizadoEm': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

        _showSnack(
          'Solicitação de primeiro acesso enviada. Aguarde aprovação do administrador.',
          backgroundColor: Colors.green,
        );

        return;
      }

      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: normalizedEmail,
      );

      _showSnack(
        'Enviamos um link para redefinir sua senha. Verifique seu e-mail.',
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
      debugPrint('Access/password email unexpected error: $e');

      _showSnack(
        'Erro ao processar solicitação. Tente novamente.',
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
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/eye_argos.svg',
                      width: 42,
                      height: 42,
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SvgPicture.asset(
                  'assets/images/display_argos.svg',
                  width: 210,
                  colorFilter: const ColorFilter.mode(
                    Color(0xFF0057C0),
                    BlendMode.srcIn,
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

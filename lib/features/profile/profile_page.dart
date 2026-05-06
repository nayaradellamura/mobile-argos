import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';

class ProfilePage extends StatefulWidget {
  final User user;
  final bool requireCompletion;
  final VoidCallback? onProfileCompleted;

  const ProfilePage({
    super.key,
    required this.user,
    this.requireCompletion = false,
    this.onProfileCompleted,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final formKey = GlobalKey<FormState>();

  final nomeController = TextEditingController();
  final telefoneController = TextEditingController();
  final empresaController = TextEditingController();
  final documentoController = TextEditingController();
  final cidadeController = TextEditingController();
  final ufController = TextEditingController();

  final picker = ImagePicker();

  bool isLoading = true;
  bool isSaving = false;
  bool isEditing = false;

  File? selectedPhoto;
  String? photoURL;

  String provider = '';
  String tipoAcesso = '';
  bool cadastroCompleto = false;

  String get emailKey => (widget.user.email ?? '').trim().toLowerCase();

  bool get isPasswordAccess {
    if (provider == 'password') return true;
    if (tipoAcesso == 'email_senha') return true;

    return widget.user.providerData.any(
      (providerInfo) => providerInfo.providerId == 'password',
    );
  }

  bool get canEdit => widget.requireCompletion || isEditing;

  @override
  void initState() {
    super.initState();

    isEditing = widget.requireCompletion;
    _loadProfileData();
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.requireCompletion && !oldWidget.requireCompletion) {
      setState(() {
        isEditing = true;
      });
    }
  }

  @override
  void dispose() {
    nomeController.dispose();
    telefoneController.dispose();
    empresaController.dispose();
    documentoController.dispose();
    cidadeController.dispose();
    ufController.dispose();
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

  String _inferProvider() {
    final providers = widget.user.providerData.map((p) => p.providerId).toSet();

    if (providers.contains('google.com')) return 'google';
    if (providers.contains('password')) return 'password';

    return provider.isEmpty ? 'password' : provider;
  }

  String _inferTipoAcesso() {
    final inferredProvider = provider.isEmpty ? _inferProvider() : provider;

    if (inferredProvider == 'google') return 'sso_google';

    return 'email_senha';
  }

  Future<void> _loadProfileData() async {
    final email = emailKey;

    if (email.isEmpty) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(email)
          .get();

      final data = snap.data() ?? {};

      provider = data['provider']?.toString() ?? _inferProvider();
      tipoAcesso = data['tipoAcesso']?.toString() ?? _inferTipoAcesso();
      cadastroCompleto = data['cadastroCompleto'] == true;

      nomeController.text = data['nome']?.toString().trim().isNotEmpty == true
          ? data['nome'].toString()
          : widget.user.displayName ?? '';

      telefoneController.text = data['telefone']?.toString() ?? '';
      empresaController.text = data['empresa']?.toString() ?? '';
      documentoController.text = data['documento']?.toString() ?? '';
      cidadeController.text = data['cidade']?.toString() ?? '';
      ufController.text = data['uf']?.toString() ?? '';

      photoURL = data['photoURL']?.toString().trim().isNotEmpty == true
          ? data['photoURL'].toString()
          : widget.user.photoURL;

      if (!mounted) return;

      setState(() {
        isLoading = false;
        isEditing = widget.requireCompletion || !cadastroCompleto;
      });
    } catch (e) {
      debugPrint('Load profile error: $e');

      if (!mounted) return;

      setState(() {
        isLoading = false;
        isEditing = true;
      });

      _showSnack(
        'Não foi possível carregar seu perfil.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  Future<void> _pickPhoto() async {
    if (!canEdit || isSaving) return;

    try {
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 78,
        maxWidth: 1200,
      );

      if (image == null) return;

      setState(() {
        selectedPhoto = File(image.path);
      });
    } catch (e) {
      debugPrint('Pick photo error: $e');

      _showSnack(
        'Não foi possível selecionar a foto.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  Future<String?> _uploadSelectedPhoto() async {
    final photo = selectedPhoto;

    if (photo == null) return photoURL;

    final safeEmail = Uri.encodeComponent(emailKey);
    final path =
        'users/$safeEmail/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

    final ref = FirebaseStorage.instance.ref().child(path);

    await ref.putFile(photo, SettableMetadata(contentType: 'image/jpeg'));

    return ref.getDownloadURL();
  }

  bool _hasProfilePhoto() {
    if (selectedPhoto != null) return true;

    return photoURL != null && photoURL!.trim().isNotEmpty;
  }

  Future<void> _saveProfile() async {
    if (isSaving) return;

    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }

    if (emailKey.isEmpty) {
      _showSnack(
        'Não foi possível identificar o e-mail da conta.',
        backgroundColor: Colors.redAccent,
      );
      return;
    }

    if (isPasswordAccess && !_hasProfilePhoto()) {
      _showSnack(
        'Adicione uma foto de perfil para finalizar o cadastro.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isSaving = true;
    });

    try {
      final uploadedPhotoURL = await _uploadSelectedPhoto();
      final nome = nomeController.text.trim();

      final resolvedProvider = provider.isEmpty ? _inferProvider() : provider;
      final resolvedTipoAcesso = tipoAcesso.isEmpty
          ? _inferTipoAcesso()
          : tipoAcesso;

      await FirebaseFirestore.instance.collection('users').doc(emailKey).set({
        'uid': widget.user.uid,
        'authUid': widget.user.uid,
        'email': emailKey,
        'emailKey': emailKey,
        'nome': nome,
        'displayName': nome,
        'telefone': telefoneController.text.trim(),
        'empresa': empresaController.text.trim(),
        'documento': documentoController.text.trim(),
        'cidade': cidadeController.text.trim(),
        'uf': ufController.text.trim().toUpperCase(),
        'photoURL': uploadedPhotoURL ?? '',
        'provider': resolvedProvider,
        'tipoAcesso': resolvedTipoAcesso,
        'cadastroCompleto': true,
        'cadastroFinalizadoEm': FieldValue.serverTimestamp(),
        'atualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (nome.isNotEmpty && widget.user.displayName != nome) {
        await widget.user.updateDisplayName(nome);
      }

      if (uploadedPhotoURL != null &&
          uploadedPhotoURL.isNotEmpty &&
          widget.user.photoURL != uploadedPhotoURL) {
        await widget.user.updatePhotoURL(uploadedPhotoURL);
      }

      await widget.user.reload();

      if (!mounted) return;

      setState(() {
        cadastroCompleto = true;
        photoURL = uploadedPhotoURL;
        selectedPhoto = null;
        isEditing = false;
      });

      _showSnack(
        widget.requireCompletion
            ? 'Cadastro finalizado com sucesso.'
            : 'Perfil atualizado com sucesso.',
        backgroundColor: Colors.green,
      );

      widget.onProfileCompleted?.call();
    } catch (e) {
      debugPrint('Save profile error: $e');

      _showSnack(
        'Erro ao salvar perfil. Tente novamente.',
        backgroundColor: Colors.redAccent,
      );
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      await FirebaseAuth.instance.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SafeArea(
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF0057C0)),
        ),
      );
    }

    final avatarImage = selectedPhoto != null
        ? FileImage(selectedPhoto!)
        : photoURL != null && photoURL!.isNotEmpty
        ? NetworkImage(photoURL!) as ImageProvider
        : null;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        child: Form(
          key: formKey,
          child: Column(
            children: [
              Text(
                'Perfil',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0057C0),
                ),
              ),

              const SizedBox(height: 12),

              if (widget.requireCompletion)
                _CompletionBanner(isPasswordAccess: isPasswordAccess)
              else
                _StatusBanner(
                  provider: provider,
                  tipoAcesso: tipoAcesso,
                  cadastroCompleto: cadastroCompleto,
                ),

              const SizedBox(height: 28),

              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 52,
                    backgroundColor: const Color(0xFFE5F6FF),
                    backgroundImage: avatarImage,
                    child: avatarImage == null
                        ? const Icon(
                            Icons.person,
                            size: 44,
                            color: Color(0xFF0057C0),
                          )
                        : null,
                  ),
                  if (canEdit)
                    Material(
                      color: const Color(0xFF0057C0),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _pickPhoto,
                        child: const SizedBox(
                          width: 38,
                          height: 38,
                          child: Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 16),

              Text(
                nomeController.text.trim().isEmpty
                    ? 'Usuário sem nome'
                    : nomeController.text.trim(),
                textAlign: TextAlign.center,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 6),

              Text(
                widget.user.email ?? 'Email não informado',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF414755)),
              ),

              const SizedBox(height: 28),

              _ProfileTextField(
                controller: nomeController,
                label: 'Nome completo',
                enabled: canEdit && !isSaving,
                icon: Icons.person_outline,
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Informe seu nome completo.';
                  }

                  return null;
                },
              ),

              const SizedBox(height: 16),

              _ProfileTextField(
                controller: telefoneController,
                label: 'Telefone',
                enabled: canEdit && !isSaving,
                keyboardType: TextInputType.phone,
                icon: Icons.phone_outlined,
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Informe seu telefone.';
                  }

                  return null;
                },
              ),

              const SizedBox(height: 16),

              _ProfileTextField(
                controller: empresaController,
                label: 'Oficina / Empresa',
                enabled: canEdit && !isSaving,
                icon: Icons.business_outlined,
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Informe sua oficina ou empresa.';
                  }

                  return null;
                },
              ),

              const SizedBox(height: 16),

              _ProfileTextField(
                controller: documentoController,
                label: 'CPF/CNPJ',
                enabled: canEdit && !isSaving,
                icon: Icons.badge_outlined,
              ),

              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _ProfileTextField(
                      controller: cidadeController,
                      label: 'Cidade',
                      enabled: canEdit && !isSaving,
                      icon: Icons.location_city_outlined,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ProfileTextField(
                      controller: ufController,
                      label: 'UF',
                      enabled: canEdit && !isSaving,
                      textCapitalization: TextCapitalization.characters,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 28),

              if (canEdit)
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: isSaving ? null : _saveProfile,
                    icon: isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle),
                    label: Text(
                      isSaving
                          ? 'Salvando...'
                          : widget.requireCompletion
                          ? 'Finalizar cadastro'
                          : 'Salvar alterações',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0057C0),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(
                        0xFF0057C0,
                      ).withOpacity(.65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        isEditing = true;
                      });
                    },
                    icon: const Icon(Icons.edit),
                    label: const Text('Editar informações'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0057C0),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),

              if (isEditing && !widget.requireCompletion) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: isSaving
                        ? null
                        : () {
                            setState(() {
                              isEditing = false;
                              selectedPhoto = null;
                            });

                            _loadProfileData();
                          },
                    icon: const Icon(Icons.close),
                    label: const Text('Cancelar edição'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0057C0),
                      backgroundColor: const Color(0xFFE5F6FF),
                      side: BorderSide(color: Colors.black.withOpacity(.05)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 18),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: isSaving ? null : _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Sair da conta'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    backgroundColor: Colors.white,
                    side: BorderSide(color: Colors.black.withOpacity(.05)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompletionBanner extends StatelessWidget {
  final bool isPasswordAccess;

  const _CompletionBanner({required this.isPasswordAccess});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE5F6FF),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF0057C0).withOpacity(.12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.assignment_ind, color: Color(0xFF0057C0)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isPasswordAccess
                  ? 'Finalize seu cadastro para continuar. Como seu acesso é por e-mail e senha, adicione também uma foto de perfil.'
                  : 'Finalize seu cadastro para continuar usando o Argos.',
              style: const TextStyle(
                color: Color(0xFF414755),
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final String provider;
  final String tipoAcesso;
  final bool cadastroCompleto;

  const _StatusBanner({
    required this.provider,
    required this.tipoAcesso,
    required this.cadastroCompleto,
  });

  @override
  Widget build(BuildContext context) {
    final providerLabel = provider == 'google'
        ? 'Google SSO'
        : provider == 'password'
        ? 'E-mail e senha'
        : 'Acesso Argos';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cadastroCompleto
            ? Colors.green.withOpacity(.10)
            : Colors.orange.withOpacity(.10),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            cadastroCompleto ? Icons.verified_user : Icons.info_outline,
            color: cadastroCompleto ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$providerLabel · ${cadastroCompleto ? 'cadastro completo' : 'cadastro pendente'}',
              style: TextStyle(
                color: cadastroCompleto ? Colors.green : Colors.orange,
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final IconData? icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String? Function(String?)? validator;

  const _ProfileTextField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: icon == null ? null : Icon(icon),
        filled: true,
        fillColor: enabled ? const Color(0xFFE5F6FF) : Colors.white,
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF0057C0)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
      ),
    );
  }
}

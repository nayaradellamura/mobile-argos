import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../../services/session_context_service.dart';

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
  static List<CredenciadoOption>? _cachedCredenciados;
  static List<CityOption>? _cachedCities;

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
  bool isLoadingOptions = true;

  File? selectedPhoto;
  String? photoURL;
  String? lockedCredenciadoId;
  ImageProvider? cachedProfileImage;
  String? cachedProfileImageUrl;

  String provider = '';
  String tipoAcesso = '';
  bool cadastroCompleto = false;

  List<CredenciadoOption> credenciados = [];
  List<CityOption> cities = [];

  CredenciadoOption? selectedCredenciado;
  CityOption? selectedCity;

  String get emailKey => (widget.user.email ?? '').trim().toLowerCase();

  bool get isPasswordAccess {
    if (provider == 'password') return true;
    if (tipoAcesso.contains('email_senha')) return true;

    return widget.user.providerData.any(
      (providerInfo) => providerInfo.providerId == 'password',
    );
  }

  bool get canEdit => widget.requireCompletion || isEditing;

  bool get isCredenciadoLocked {
    final lockedId = lockedCredenciadoId?.trim() ?? '';

    return cadastroCompleto && lockedId.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();

    isEditing = widget.requireCompletion;
    _loadInitialData();
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

  Future<void> _loadInitialData() async {
    setState(() {
      isLoading = true;
      isLoadingOptions = true;
    });

    try {
      await Future.wait([_loadCredenciados(), _loadBrazilianCities()]);

      await _loadProfileData();

      if (!mounted) return;

      setState(() {
        isLoading = false;
        isLoadingOptions = false;
      });
    } catch (e) {
      debugPrint('Load initial profile data error: $e');

      if (!mounted) return;

      setState(() {
        isLoading = false;
        isLoadingOptions = false;
        isEditing = true;
      });

      _showSnack(
        'Não foi possível carregar todos os dados do perfil.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  Future<void> _loadCredenciados() async {
    final cached = _cachedCredenciados;

    if (cached != null) {
      credenciados = cached;
      return;
    }

    final snapshot = await FirebaseFirestore.instance
        .collection('credenciados')
        .orderBy('name')
        .get();

    final loaded = snapshot.docs
        .map((doc) {
          final data = doc.data();
          final name = data['name']?.toString().trim() ?? '';

          if (name.isEmpty) return null;

          return CredenciadoOption(id: doc.id, name: name);
        })
        .whereType<CredenciadoOption>()
        .toList();

    _cachedCredenciados = loaded;
    credenciados = loaded;
  }

  Future<void> _loadBrazilianCities() async {
    final cached = _cachedCities;

    if (cached != null) {
      cities = cached;
      return;
    }

    final uri = Uri.parse(
      'https://servicodados.ibge.gov.br/api/v1/localidades/municipios',
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Erro ao buscar cidades do IBGE.');
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! List) {
      throw Exception('Retorno inesperado ao buscar cidades.');
    }

    final loaded = decoded
        .map((item) {
          if (item is! Map<String, dynamic>) return null;

          final cityName = item['nome']?.toString().trim() ?? '';

          final uf =
              item['microrregiao']?['mesorregiao']?['UF']?['sigla']
                  ?.toString()
                  .trim()
                  .toUpperCase() ??
              item['regiao-imediata']?['regiao-intermediaria']?['UF']?['sigla']
                  ?.toString()
                  .trim()
                  .toUpperCase() ??
              '';

          if (cityName.isEmpty || uf.isEmpty) return null;

          return CityOption(name: cityName, uf: uf);
        })
        .whereType<CityOption>()
        .toList();

    loaded.sort((a, b) => a.label.compareTo(b.label));

    _cachedCities = loaded;
    cities = loaded;
  }

  Future<void> _loadProfileData() async {
    final email = emailKey;

    if (email.isEmpty) {
      isLoading = false;
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

      telefoneController.text = BrazilianPhoneFormatter.format(
        data['telefone']?.toString() ?? '',
      );

      final empresa =
          data['empresa']?.toString() ??
          data['credenciadoNome']?.toString() ??
          '';

      empresaController.text = empresa;

      documentoController.text = CpfInputFormatter.format(
        data['cpf']?.toString() ?? data['documento']?.toString() ?? '',
      );

      cidadeController.text = _cleanCityName(data['cidade']?.toString() ?? '');
      ufController.text = data['uf']?.toString().toUpperCase() ?? '';

      photoURL = data['photoURL']?.toString().trim().isNotEmpty == true
          ? data['photoURL'].toString()
          : widget.user.photoURL;

      await _cacheProfilePhoto(photoURL);

      final credenciadoId = data['credenciadoId']?.toString() ?? '';
      lockedCredenciadoId = credenciadoId.isNotEmpty ? credenciadoId : null;

      if (credenciadoId.isNotEmpty) {
        selectedCredenciado = _findCredenciadoById(credenciadoId);
      }

      selectedCredenciado ??= _findCredenciadoByName(empresa);

      if ((lockedCredenciadoId == null || lockedCredenciadoId!.isEmpty) &&
          cadastroCompleto &&
          selectedCredenciado != null) {
        lockedCredenciadoId = selectedCredenciado!.id;
      }

      if (selectedCredenciado != null) {
        empresaController.text = selectedCredenciado!.name;
      }

      selectedCity = _findCity(cidadeController.text, ufController.text);

      if (!mounted) return;

      setState(() {
        isEditing = widget.requireCompletion || !cadastroCompleto;
      });
    } catch (e) {
      debugPrint('Load profile error: $e');

      if (!mounted) return;

      setState(() {
        isEditing = true;
      });

      _showSnack(
        'Não foi possível carregar seu perfil.',
        backgroundColor: Colors.redAccent,
      );
    }
  }

  CredenciadoOption? _findCredenciadoById(String id) {
    for (final credenciado in credenciados) {
      if (credenciado.id == id) return credenciado;
    }

    return null;
  }

  CredenciadoOption? _findCredenciadoByName(String name) {
    final normalized = name.trim().toLowerCase();

    if (normalized.isEmpty) return null;

    for (final credenciado in credenciados) {
      if (credenciado.name.trim().toLowerCase() == normalized) {
        return credenciado;
      }
    }

    return null;
  }

  CityOption? _findCity(String name, String uf) {
    final normalizedName = name.trim().toLowerCase();
    final normalizedUf = uf.trim().toUpperCase();

    if (normalizedName.isEmpty) return null;

    for (final city in cities) {
      final sameName = city.name.trim().toLowerCase() == normalizedName;
      final sameUf = normalizedUf.isEmpty || city.uf == normalizedUf;

      if (sameName && sameUf) return city;
    }

    return null;
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

  Future<void> _syncAssignedProfileToSinistros({
  required String uid,
  required String name,
  required String email,
  required String photoURL,
}) async {
  final db = FirebaseFirestore.instance;

  final snap = await db
      .collection('sinistro')
      .where('assignedToUid', isEqualTo: uid)
      .get();

  if (snap.docs.isEmpty) return;

  WriteBatch batch = db.batch();
  int operationCount = 0;

  for (final doc in snap.docs) {
    batch.set(
      doc.reference,
      {
        'assignedToName': name,
        'assignedToEmail': email,
        'assignedToPhotoURL': photoURL,
        'assignedProfileUpdatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    operationCount++;

    if (operationCount == 450) {
      await batch.commit();
      batch = db.batch();
      operationCount = 0;
    }
  }

  if (operationCount > 0) {
    await batch.commit();
  }
}


  bool _hasProfilePhoto() {
    if (selectedPhoto != null) return true;

    return photoURL != null && photoURL!.trim().isNotEmpty;
  }

  Future<void> _cacheProfilePhoto(String? url) async {
    final cleanUrl = url?.trim() ?? '';

    if (cleanUrl.isEmpty) {
      cachedProfileImage = null;
      cachedProfileImageUrl = null;
      return;
    }

    if (cachedProfileImage != null && cachedProfileImageUrl == cleanUrl) {
      return;
    }

    final provider = NetworkImage(cleanUrl);

    cachedProfileImage = provider;
    cachedProfileImageUrl = cleanUrl;

    if (!mounted) return;

    try {
      await precacheImage(provider, context).timeout(
        const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('Precache profile photo error: $e');
    }
  }

  bool _isValidCpf(String value) {
    final cpf = value.replaceAll(RegExp(r'\D'), '');

    if (cpf.length != 11) return false;

    if (RegExp(r'^(\d)\1{10}$').hasMatch(cpf)) return false;

    int calcDigit(int length) {
      var sum = 0;

      for (var i = 0; i < length; i++) {
        sum += int.parse(cpf[i]) * (length + 1 - i);
      }

      final remainder = (sum * 10) % 11;

      return remainder == 10 ? 0 : remainder;
    }

    final digit1 = calcDigit(9);
    final digit2 = calcDigit(10);

    return digit1 == int.parse(cpf[9]) && digit2 == int.parse(cpf[10]);
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

    final effectiveCredenciado = isCredenciadoLocked
        ? selectedCredenciado ?? _findCredenciadoById(lockedCredenciadoId ?? '')
        : selectedCredenciado;

    if (effectiveCredenciado == null) {
      _showSnack(
        'Selecione sua oficina ou empresa.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    final selectedOrTypedCity =
        selectedCity ?? _findCity(cidadeController.text, ufController.text);

    if (selectedOrTypedCity == null) {
      _showSnack(
        'Selecione uma cidade da lista.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    final cpfDigits = documentoController.text.replaceAll(RegExp(r'\D'), '');

    if (cpfDigits.length != 11 || !_isValidCpf(cpfDigits)) {
      _showSnack('Informe um CPF válido.', backgroundColor: Colors.orange);
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

      final credenciado = effectiveCredenciado;
      final city = selectedOrTypedCity;

      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(emailKey);

      final credenciadoRef = FirebaseFirestore.instance
          .collection('credenciados')
          .doc(credenciado.id);

      final batch = FirebaseFirestore.instance.batch();

      batch.set(userRef, {
        'uid': widget.user.uid,
        'authUid': widget.user.uid,
        'email': emailKey,
        'emailKey': emailKey,
        'nome': nome,
        'displayName': nome,
        'telefone': telefoneController.text.trim(),
        'empresa': credenciado.name,
        'credenciadoId': credenciado.id,
        'credenciadoNome': credenciado.name,
        'documento': CpfInputFormatter.format(cpfDigits),
        'cpf': cpfDigits,
        'tipoDocumento': 'CPF',
        'cidade': city.name,
        'uf': city.uf,
        'photoURL': uploadedPhotoURL ?? '',
        'provider': resolvedProvider,
        'tipoAcesso': resolvedTipoAcesso,
        'cadastroCompleto': true,
        'primeiroAcessoConcluido': true,
        'cadastroFinalizadoEm': FieldValue.serverTimestamp(),
        'atualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      batch.set(credenciadoRef, {
        'funcionariosUids': FieldValue.arrayUnion([widget.user.uid]),
        'atualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await batch.commit();

      if (nome.isNotEmpty && widget.user.displayName != nome) {
        await widget.user.updateDisplayName(nome);
      }

      if (uploadedPhotoURL != null &&
    uploadedPhotoURL.isNotEmpty &&
    widget.user.photoURL != uploadedPhotoURL) {
  await widget.user.updatePhotoURL(uploadedPhotoURL);
}

      await _syncAssignedProfileToSinistros(
        uid: widget.user.uid,
        name: nome,
        email: emailKey,
        photoURL: uploadedPhotoURL ?? '',
      );

      await widget.user.reload();

      await _cacheProfilePhoto(uploadedPhotoURL);

      // O cadastro pode ter mudado nome/credenciadoId — força o
      // SessionContextService a buscar de novo em vez de continuar
      // servindo o contexto antigo do cache para as outras telas.
      unawaited(SessionContextService.instance.resolve(forceRefresh: true));

      if (!mounted) return;

      setState(() {
        cadastroCompleto = true;
        photoURL = uploadedPhotoURL;
        selectedPhoto = null;
        selectedCity = city;
        cidadeController.text = city.name;
        ufController.text = city.uf;
        empresaController.text = credenciado.name;
        lockedCredenciadoId = credenciado.id;
        documentoController.text = CpfInputFormatter.format(cpfDigits);
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
    await SessionContextService.instance.logout();
  }


  InputDecoration _fieldDecoration({
    required String label,
    IconData? icon,
    bool enabled = true,
  }) {
    return InputDecoration(
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
    );
  }

  Widget _buildCredenciadoField() {
    if (!canEdit || isCredenciadoLocked) {
      return _ProfileTextField(
        controller: empresaController,
        label: 'Oficina / Empresa',
        enabled: false,
        icon: Icons.business_outlined,
      );
    }

    return DropdownButtonFormField<CredenciadoOption>(
      value: selectedCredenciado,
      isExpanded: true,
      decoration: _fieldDecoration(
        label: 'Oficina / Empresa',
        icon: Icons.business_outlined,
        enabled: !isSaving && !isLoadingOptions,
      ),
      items: credenciados.map((credenciado) {
        return DropdownMenuItem<CredenciadoOption>(
          value: credenciado,
          child: Text(credenciado.name, overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: isSaving || isLoadingOptions
          ? null
          : (value) {
              setState(() {
                selectedCredenciado = value;
                empresaController.text = value?.name ?? '';
              });
            },
      validator: (value) {
        if (value == null) {
          return isLoadingOptions
              ? 'Aguarde o carregamento das oficinas.'
              : 'Selecione sua oficina ou empresa.';
        }

        return null;
      },
    );
  }

  Widget _buildCityField() {
    if (!canEdit) {
      return Row(
        children: [
          Expanded(
            flex: 2,
            child: _ProfileTextField(
              controller: cidadeController,
              label: 'Cidade',
              enabled: false,
              icon: Icons.location_city_outlined,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _ProfileTextField(
              controller: ufController,
              label: 'UF',
              enabled: false,
              textCapitalization: TextCapitalization.characters,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Autocomplete<CityOption>(
            initialValue: TextEditingValue(text: cidadeController.text),
            displayStringForOption: (option) => option.name,
            optionsBuilder: (textEditingValue) {
              final query = textEditingValue.text.trim().toLowerCase();

              if (query.length < 2 || cities.isEmpty) {
                return const Iterable<CityOption>.empty();
              }

              return cities
                  .where((city) {
                    final cityName = city.name.toLowerCase();
                    final label = city.label.toLowerCase();
                    final uf = city.uf.toLowerCase();

                    return cityName.contains(query) ||
                        label.contains(query) ||
                        uf == query;
                  })
                  .take(40);
            },
            onSelected: (city) {
              setState(() {
                selectedCity = city;
                cidadeController.text = city.name;
                ufController.text = city.uf;
              });
            },
            fieldViewBuilder:
                (context, textEditingController, focusNode, onFieldSubmitted) {
                  if (cidadeController.text.isNotEmpty &&
                      textEditingController.text.isEmpty) {
                    textEditingController.text = cidadeController.text;
                  }

                  return TextFormField(
                    controller: textEditingController,
                    focusNode: focusNode,
                    enabled: !isSaving && !isLoadingOptions,
                    textCapitalization: TextCapitalization.words,
                    decoration: _fieldDecoration(
                      label: 'Cidade',
                      icon: Icons.location_city_outlined,
                      enabled: !isSaving && !isLoadingOptions,
                    ),
                    onChanged: (value) {
                      cidadeController.text = _cleanCityName(value);

                      if (selectedCity != null &&
                          selectedCity!.name.toLowerCase() !=
                              value.trim().toLowerCase()) {
                        setState(() {
                          selectedCity = null;
                          ufController.clear();
                        });
                      }
                    },
                    validator: (value) {
                      final typed = _cleanCityName(value ?? '');

                      if (typed.isEmpty) {
                        return 'Informe sua cidade.';
                      }

                      final found =
                          selectedCity ?? _findCity(typed, ufController.text);

                      if (found == null) {
                        return 'Selecione uma cidade da lista.';
                      }

                      return null;
                    },
                  );
                },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 260,
                      maxWidth: 360,
                    ),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);

                        return ListTile(
                          dense: true,
                          title: Text(option.name),
                          trailing: Text(
                            option.uf,
                            style: const TextStyle(
                              color: Color(0xFF0057C0),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onTap: () {
                            onSelected(option);
                          },
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ProfileTextField(
            controller: ufController,
            label: 'UF',
            enabled: false,
            textCapitalization: TextCapitalization.characters,
          ),
        ),
      ],
    );
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
        ? FileImage(selectedPhoto!) as ImageProvider
        : cachedProfileImage ??
            (photoURL != null && photoURL!.isNotEmpty
                ? NetworkImage(photoURL!) as ImageProvider
                : null);

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
                inputFormatters: [BrazilianPhoneFormatter()],
                validator: (value) {
                  final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');

                  if (digits.isEmpty) {
                    return 'Informe seu telefone.';
                  }

                  if (digits.length != 11) {
                    return 'Informe um telefone válido com DDD.';
                  }

                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildCredenciadoField(),
              const SizedBox(height: 16),
              _ProfileTextField(
                controller: documentoController,
                label: 'CPF',
                enabled: canEdit && !isSaving,
                keyboardType: TextInputType.number,
                icon: Icons.badge_outlined,
                inputFormatters: [CpfInputFormatter()],
                validator: (value) {
                  final cpf = (value ?? '').replaceAll(RegExp(r'\D'), '');

                  if (cpf.isEmpty) {
                    return 'Informe seu CPF.';
                  }

                  if (cpf.length != 11 || !_isValidCpf(cpf)) {
                    return 'Informe um CPF válido.';
                  }

                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildCityField(),
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
  final List<TextInputFormatter>? inputFormatters;

  const _ProfileTextField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      validator: validator,
      inputFormatters: inputFormatters,
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

class CredenciadoOption {
  final String id;
  final String name;

  const CredenciadoOption({required this.id, required this.name});
}

class CityOption {
  final String name;
  final String uf;

  const CityOption({required this.name, required this.uf});

  String get label => '$name - $uf';
}


String _cleanCityName(String value) {
  final text = value.trim();

  if (text.isEmpty) return '';

  final match = RegExp(r'\s-\s[A-Z]{2}$').firstMatch(text);

  if (match == null) return text;

  return text.substring(0, match.start).trim();
}

class BrazilianPhoneFormatter extends TextInputFormatter {
  static String format(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');

    final limited = digits.length > 11 ? digits.substring(0, 11) : digits;

    if (limited.isEmpty) return '';

    if (limited.length <= 2) {
      return '($limited';
    }

    if (limited.length <= 7) {
      return '(${limited.substring(0, 2)}) ${limited.substring(2)}';
    }

    return '(${limited.substring(0, 2)}) ${limited.substring(2, 7)}-${limited.substring(7)}';
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = format(newValue.text);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class CpfInputFormatter extends TextInputFormatter {
  static String format(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');

    final limited = digits.length > 11 ? digits.substring(0, 11) : digits;

    if (limited.isEmpty) return '';

    if (limited.length <= 3) {
      return limited;
    }

    if (limited.length <= 6) {
      return '${limited.substring(0, 3)}.${limited.substring(3)}';
    }

    if (limited.length <= 9) {
      return '${limited.substring(0, 3)}.${limited.substring(3, 6)}.${limited.substring(6)}';
    }

    return '${limited.substring(0, 3)}.${limited.substring(3, 6)}.${limited.substring(6, 9)}-${limited.substring(9)}';
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = format(newValue.text);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

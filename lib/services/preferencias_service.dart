import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Preferências do usuário guardadas em `users/{email}.preferencias`.
///
/// Por enquanto só a opção de teste "ouvir mensagens do Argos", ligada por
/// um atalho oculto no perfil (7 toques na linha do tipo de acesso).
class PreferenciasService {
  PreferenciasService._();

  static final PreferenciasService instance = PreferenciasService._();

  /// Mostra o botão de ouvir nas mensagens do Argos no chat.
  final ValueNotifier<bool> ouvirMensagensArgos = ValueNotifier<bool>(false);

  DocumentReference<Map<String, dynamic>>? _docDoUsuario() {
    final email = FirebaseAuth.instance.currentUser?.email?.trim().toLowerCase();
    if (email == null || email.isEmpty) return null;
    return FirebaseFirestore.instance.collection('users').doc(email);
  }

  Future<void> carregar() async {
    try {
      final data = (await _docDoUsuario()?.get())?.data() ?? const {};
      final prefs = data['preferencias'];
      ouvirMensagensArgos.value =
          prefs is Map && prefs['ouvirMensagensArgos'] == true;
    } catch (e) {
      debugPrint('Erro ao carregar preferências: $e');
    }
  }

  Future<void> definirOuvirMensagensArgos(bool valor) async {
    ouvirMensagensArgos.value = valor;
    await _docDoUsuario()?.set({
      'preferencias': {'ouvirMensagensArgos': valor},
    }, SetOptions(merge: true));
  }
}

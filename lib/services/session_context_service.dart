import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Contexto do usuário logado: quem ele é e a qual oficina credenciada
/// pertence.
class UserSessionContext {
  final String uid;
  final String email;
  final String nome;
  final String credenciadoId;
  final String credenciadoNome;

  const UserSessionContext({
    required this.uid,
    required this.email,
    required this.nome,
    required this.credenciadoId,
    required this.credenciadoNome,
  });
}

/// Lançada quando o usuário logado não está vinculado a nenhuma oficina
/// credenciada.
class NoCredenciadoLinkedException implements Exception {
  const NoCredenciadoLinkedException();
}

/// Resolve e mantém em cache — em memória, pela duração do processo do
/// app — o contexto de sessão do usuário (uid, nome, e a oficina/
/// credenciado a que pertence).
///
/// Antes deste serviço existir, a mesma descoberta ("a qual oficina esse
/// usuário pertence") era refeita do zero, com até 3 leituras sequenciais
/// no Firestore, toda vez que uma tela precisava dela — em
/// `InspectionsPage` e de novo, de forma independente, em
/// `VistoriaChatSessionService`. Como esse dado quase nunca muda durante
/// uma sessão de uso, resolver uma vez e reaproveitar entre telas corta
/// esse tempo de carregamento sem risco de mostrar dado desatualizado.
class SessionContextService {
  SessionContextService._();

  static final SessionContextService instance = SessionContextService._();

  Future<UserSessionContext>? _pending;
  UserSessionContext? _cached;
  String? _cachedForUid;

  /// Retorna o contexto do usuário logado, reaproveitando o cache em
  /// memória quando possível.
  ///
  /// - Se o uid autenticado mudar (troca de conta/login de outro usuário
  ///   no mesmo aparelho), o cache é descartado automaticamente.
  /// - Chamadas concorrentes enquanto a primeira resolução ainda está em
  ///   andamento reaproveitam a mesma requisição em vez de disparar
  ///   leituras duplicadas no Firestore.
  /// - Passe [forceRefresh] depois de uma edição de perfil que possa ter
  ///   mudado o credenciado vinculado.
  Future<UserSessionContext> resolve({bool forceRefresh = false}) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;

    if (_cachedForUid != currentUid) {
      _cached = null;
      _pending = null;
    }

    final cached = _cached;
    if (!forceRefresh && cached != null) {
      return Future.value(cached);
    }

    final pending = _pending;
    if (!forceRefresh && pending != null) {
      return pending;
    }

    final future = _resolve();
    _pending = future;

    future.then((context) {
      _cached = context;
      _cachedForUid = context.uid;
      _pending = null;
    }).catchError((Object _) {
      _pending = null;
    });

    return future;
  }

  /// Descarta o cache. Chamar no logout, para não vazar o contexto de um
  /// usuário para a sessão do próximo que fizer login no mesmo aparelho.
  void clear() {
    _cached = null;
    _cachedForUid = null;
    _pending = null;
  }

  Future<UserSessionContext> _resolve() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    final uid = user.uid;
    final email = (user.email ?? '').trim().toLowerCase();

    final usersCollection = FirebaseFirestore.instance.collection('users');

    // Documentos de "users" são gravados com o e-mail normalizado como id
    // (ver login_page.dart), então checar por e-mail primeiro evita uma
    // leitura desperdiçada na maioria dos casos.
    Map<String, dynamic> userData = {};

    if (email.isNotEmpty) {
      // Tenta o cache local do Firestore antes do servidor: se o app já
      // resolveu esse usuário numa sessão anterior, isso volta quase
      // instantâneo, sem depender da rede.
      userData = await _getDataCacheFirst(usersCollection.doc(email));
    }

    if (userData.isEmpty) {
      userData = await _getDataCacheFirst(usersCollection.doc(uid));
    }

    String credenciadoId = _stringValue(userData['credenciadoId']);
    String credenciadoNome = _stringValue(userData['credenciadoNome']);
    String nome = _stringValue(
      userData['displayName'],
      fallback: _stringValue(userData['nome'], fallback: email),
    );

    if (credenciadoId.isEmpty) {
      final credSnap = await FirebaseFirestore.instance
          .collection('credenciados')
          .where('funcionariosUids', arrayContains: uid)
          .limit(1)
          .get();

      if (credSnap.docs.isEmpty) {
        throw const NoCredenciadoLinkedException();
      }

      final doc = credSnap.docs.first;
      final data = doc.data();

      credenciadoId = doc.id;
      credenciadoNome = _stringValue(data['name']);
    }

    if (nome.isEmpty) {
      nome = email.isEmpty ? uid : email;
    }

    return UserSessionContext(
      uid: uid,
      email: email,
      nome: nome,
      credenciadoId: credenciadoId,
      credenciadoNome: credenciadoNome,
    );
  }

  /// Lê um documento tentando primeiro o cache local do Firestore (rápido,
  /// não depende de rede) e só recorre ao servidor se não houver nada em
  /// cache ainda (ex.: primeiro login do usuário neste aparelho).
  Future<Map<String, dynamic>> _getDataCacheFirst(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    try {
      final cached = await ref.get(const GetOptions(source: Source.cache));

      if (cached.exists) {
        return cached.data() ?? {};
      }
    } catch (_) {
      // Sem cache local ainda — segue para a leitura normal (servidor).
    }

    final snap = await ref.get();
    return snap.data() ?? {};
  }

  String _stringValue(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;

    final text = value.toString().trim();

    return text.isEmpty ? fallback : text;
  }
}

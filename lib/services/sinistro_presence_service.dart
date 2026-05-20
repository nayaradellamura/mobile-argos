import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SinistroPresenceService {
  SinistroPresenceService._();

  static final SinistroPresenceService instance = SinistroPresenceService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const Duration _viewerTtl = Duration(seconds: 70);
  static const Duration _heartbeatInterval = Duration(seconds: 25);

  Timer? _heartbeatTimer;
  String? _currentSinistroId;
  int _viewingGeneration = 0;
  _UserPresenceProfile? _cachedProfile;

  CollectionReference<Map<String, dynamic>> get _sinistros =>
      _db.collection('sinistro');

  Future<void> startViewing(String sinistroId) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    final cleanSinistroId = sinistroId.trim();

    if (cleanSinistroId.isEmpty) {
      throw Exception('sinistroId vazio.');
    }

    if (_currentSinistroId != null && _currentSinistroId != cleanSinistroId) {
      await stopViewing();
    }

    _currentSinistroId = cleanSinistroId;

    final generation = ++_viewingGeneration;

    await _writeViewer(cleanSinistroId, generation);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _writeViewer(cleanSinistroId, generation).catchError((_) {});
    });
  }

  Future<void> stopViewing() async {
    final user = _auth.currentUser;
    final sinistroId = _currentSinistroId;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _currentSinistroId = null;

    // Invalida qualquer escrita em background que tenha começado antes do stop.
    _viewingGeneration++;

    if (user == null || sinistroId == null || sinistroId.isEmpty) {
      return;
    }

    final viewerRef = _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .doc(user.uid);

    await viewerRef.delete().catchError((_) {});

    // Remove imediatamente do resumo do documento principal.
    // Isso evita o "rastro fantasma" no card/lista de outros usuários.
    await _removeViewerFromSummary(
      sinistroId: sinistroId,
      uid: user.uid,
    ).catchError((_) {});

    // Recalcula o resumo pela subcoleção, excluindo o usuário atual por segurança.
    await _refreshActiveViewersSummary(
      sinistroId,
      excludeUid: user.uid,
    ).catchError((_) {});
  }

  bool _isViewingActive(String sinistroId, int generation) {
    return _currentSinistroId == sinistroId &&
        _viewingGeneration == generation;
  }

  Future<void> _writeViewer(String sinistroId, int generation) async {
    final user = _auth.currentUser;

    if (user == null || !_isViewingActive(sinistroId, generation)) return;

    final fallbackProfile = _cachedProfile ??
        _UserPresenceProfile(
          uid: user.uid,
          name: user.displayName?.trim().isNotEmpty == true
              ? user.displayName!.trim()
              : user.email?.trim().toLowerCase() ?? 'Usuário',
          email: user.email?.trim().toLowerCase() ?? '',
          photoURL: user.photoURL ?? '',
        );

    await _writeViewerData(
      sinistroId: sinistroId,
      profile: fallbackProfile,
      generation: generation,
    );

    // Atualiza com dados completos do Firestore em background.
    // O generation impede que essa escrita recrie o viewer depois que a tela fechou.
    unawaited(() async {
      try {
        final fullProfile = await _loadUserProfile(user);

        if (!_isViewingActive(sinistroId, generation)) return;

        _cachedProfile = fullProfile;

        await _writeViewerData(
          sinistroId: sinistroId,
          profile: fullProfile,
          generation: generation,
        );

        if (!_isViewingActive(sinistroId, generation)) return;

        await _refreshActiveViewersSummary(sinistroId);
      } catch (_) {
        // Não deixa presença quebrar a tela.
      }
    }());
  }

  Future<void> _writeViewerData({
    required String sinistroId,
    required _UserPresenceProfile profile,
    int? generation,
  }) async {
    final user = _auth.currentUser;

    if (user == null) return;

    if (generation != null && !_isViewingActive(sinistroId, generation)) {
      return;
    }

    final now = Timestamp.now();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    final sinistroRef = _sinistros.doc(sinistroId);
    final viewerRef = sinistroRef.collection('viewers').doc(user.uid);

    final viewerData = {
      'uid': user.uid,
      'name': profile.name,
      'email': profile.email,
      'photoURL': profile.photoURL,
      'openedAt': FieldValue.serverTimestamp(),
      'lastSeenAt': now,
      'lastSeenAtMillis': nowMillis,
    };

    final viewerSummary = {
      'uid': user.uid,
      'name': profile.name,
      'email': profile.email,
      'photoURL': profile.photoURL,
      'lastSeenAtMillis': nowMillis,
    };

    final cutoffMillis = DateTime.now()
        .subtract(_viewerTtl)
        .millisecondsSinceEpoch;

    await _db.runTransaction((transaction) async {
      if (generation != null && !_isViewingActive(sinistroId, generation)) {
        return;
      }

      final sinistroSnap = await transaction.get(sinistroRef);
      final sinistroData = sinistroSnap.data() ?? {};

      final rawViewers = sinistroData['activeViewers'];

      final currentViewers = rawViewers is List
          ? rawViewers
              .whereType<Map>()
              .map(
                (item) => item.map(
                  (key, value) => MapEntry(key.toString(), value),
                ),
              )
              .where((item) => item['uid']?.toString() != user.uid)
              .where((item) {
                final value = item['lastSeenAtMillis'];
                if (value is int) return value > cutoffMillis;
                return false;
              })
              .toList()
          : <Map<String, dynamic>>[];

      final updatedViewers = [
        viewerSummary,
        ...currentViewers,
      ]..sort((a, b) {
          final aMillis = a['lastSeenAtMillis'] is int
              ? a['lastSeenAtMillis'] as int
              : 0;
          final bMillis = b['lastSeenAtMillis'] is int
              ? b['lastSeenAtMillis'] as int
              : 0;
          return bMillis.compareTo(aMillis);
        });

      transaction.set(
        viewerRef,
        viewerData,
        SetOptions(merge: true),
      );

      final limitedViewers = updatedViewers.take(5).toList();

      transaction.set(
        sinistroRef,
        {
          'activeViewers': limitedViewers,
          'activeViewersCount': limitedViewers.length,
          'activeViewersUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<void> _removeViewerFromSummary({
    required String sinistroId,
    required String uid,
  }) async {
    final sinistroRef = _sinistros.doc(sinistroId);

    await _db.runTransaction((transaction) async {
      final snap = await transaction.get(sinistroRef);
      final data = snap.data() ?? {};
      final rawViewers = data['activeViewers'];

      final updatedViewers = rawViewers is List
          ? rawViewers
              .whereType<Map>()
              .map(
                (item) => item.map(
                  (key, value) => MapEntry(key.toString(), value),
                ),
              )
              .where((item) => item['uid']?.toString() != uid)
              .toList()
          : <Map<String, dynamic>>[];

      transaction.set(
        sinistroRef,
        {
          'activeViewers': updatedViewers,
          'activeViewersCount': updatedViewers.length,
          'activeViewersUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<void> _refreshActiveViewersSummary(
    String sinistroId, {
    String? excludeUid,
  }) async {
    final cutoffMillis = DateTime.now()
        .subtract(_viewerTtl)
        .millisecondsSinceEpoch;

    final viewersSnap = await _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .where('lastSeenAtMillis', isGreaterThan: cutoffMillis)
        .limit(10)
        .get();

    final viewers = viewersSnap.docs
        .where((doc) => excludeUid == null || doc.id != excludeUid)
        .map((doc) {
      final data = doc.data();

      return {
        'uid': data['uid']?.toString() ?? doc.id,
        'name': data['name']?.toString() ?? '',
        'email': data['email']?.toString() ?? '',
        'photoURL': data['photoURL']?.toString() ?? '',
        'lastSeenAtMillis': data['lastSeenAtMillis'] is int
            ? data['lastSeenAtMillis'] as int
            : 0,
      };
    }).toList()
      ..sort((a, b) {
        final aMillis = a['lastSeenAtMillis'] is int
            ? a['lastSeenAtMillis'] as int
            : 0;
        final bMillis = b['lastSeenAtMillis'] is int
            ? b['lastSeenAtMillis'] as int
            : 0;
        return bMillis.compareTo(aMillis);
      });

    final limitedViewers = viewers.take(5).toList();

    await _sinistros.doc(sinistroId).set({
      'activeViewers': limitedViewers,
      'activeViewersCount': limitedViewers.length,
      'activeViewersUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<List<SinistroViewer>> watchViewers(String sinistroId) {
    return _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .snapshots()
        .map((snapshot) {
      final cutoffMillis = DateTime.now()
          .subtract(_viewerTtl)
          .millisecondsSinceEpoch;

      final list = snapshot.docs
          .map((doc) => SinistroViewer.fromMap(doc.id, doc.data()))
          .where((viewer) => viewer.lastSeenAtMillis > cutoffMillis)
          .toList();

      list.sort((a, b) => b.lastSeenAtMillis.compareTo(a.lastSeenAtMillis));

      return list;
    });
  }

  /// Compatível com os dois jeitos de chamar:
  ///
  /// Novo:
  /// await claimSinistroForCurrentUser(sinistroId: inspection.id)
  ///
  /// Jeito que seu inspections_page atual usa:
  /// final updatedInspection = await claimSinistroForCurrentUser(inspection: inspection)
  ///
  /// Como o service não importa a tela/modelo para evitar dependência circular,
  /// o parâmetro inspection é dynamic e é devolvido no final.
  Future<dynamic> claimSinistroForCurrentUser({
    String? sinistroId,
    dynamic inspection,
    String action = 'check_in',
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    final cleanSinistroId =
        (sinistroId ?? _extractInspectionId(inspection)).trim();

    if (cleanSinistroId.isEmpty) {
      throw Exception('sinistroId vazio.');
    }

    final profile = await _loadUserProfile(user);
    _cachedProfile = profile;

    final sinistroRef = _sinistros.doc(cleanSinistroId);

    await _db.runTransaction((transaction) async {
      final snap = await transaction.get(sinistroRef);

      if (!snap.exists) {
        throw Exception('Sinistro não encontrado.');
      }

      final data = snap.data() ?? {};
      final assignedToUid = data['assignedToUid']?.toString().trim() ?? '';

      if (assignedToUid.isNotEmpty && assignedToUid != user.uid) {
        final assignedToName =
            data['assignedToName']?.toString().trim() ?? 'outro profissional';

        throw Exception(
          'Esta vistoria já está vinculada a $assignedToName.',
        );
      }

      transaction.set(
        sinistroRef,
        {
          'assignedToUid': user.uid,
          'assignedToName': profile.name,
          'assignedToEmail': profile.email,
          'assignedToPhotoURL': profile.photoURL,
          'assignedAt': FieldValue.serverTimestamp(),
          'assignedByAction': action,
          'isAssigned': true,
          'status': 'EM_ANDAMENTO',
          'chatEnabled': true,
          'chatStatus': 'Aberto',
          'checkInAt': DateTime.now().toIso8601String(),
          'statusUpdatedAt': DateTime.now().toIso8601String(),
        },
        SetOptions(merge: true),
      );
    });

    final currentSinistroId = _currentSinistroId;
    final generation = _viewingGeneration;

    await _writeViewerData(
      sinistroId: cleanSinistroId,
      profile: profile,
      generation: currentSinistroId == cleanSinistroId ? generation : null,
    );

    return inspection;
  }

  bool canCurrentUserEdit(Map<String, dynamic> sinistro) {
    final user = _auth.currentUser;

    if (user == null) return false;

    final assignedToUid = sinistro['assignedToUid']?.toString().trim() ?? '';

    return assignedToUid.isEmpty || assignedToUid == user.uid;
  }

  bool isAssignedToCurrentUser(Map<String, dynamic> sinistro) {
    final user = _auth.currentUser;

    if (user == null) return false;

    final assignedToUid = sinistro['assignedToUid']?.toString().trim() ?? '';

    return assignedToUid == user.uid;
  }

  Future<_UserPresenceProfile> _loadUserProfile(User user) async {
    final email = user.email?.trim().toLowerCase() ?? '';

    Map<String, dynamic> data = {};

    if (email.isNotEmpty) {
      final byEmail = await _db.collection('users').doc(email).get();
      data = byEmail.data() ?? {};
    }

    if (data.isEmpty) {
      final byUid = await _db.collection('users').doc(user.uid).get();
      data = byUid.data() ?? {};
    }

    if (data.isEmpty) {
      final query = await _db
          .collection('users')
          .where('uid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        data = query.docs.first.data();
      }
    }

    final name = data['displayName']?.toString().trim().isNotEmpty == true
        ? data['displayName'].toString().trim()
        : data['nome']?.toString().trim().isNotEmpty == true
            ? data['nome'].toString().trim()
            : user.displayName?.trim().isNotEmpty == true
                ? user.displayName!.trim()
                : email;

    final photoURL = data['photoURL']?.toString().trim().isNotEmpty == true
        ? data['photoURL'].toString().trim()
        : data['foto']?.toString().trim().isNotEmpty == true
            ? data['foto'].toString().trim()
            : user.photoURL ?? '';

    return _UserPresenceProfile(
      uid: user.uid,
      name: name,
      email: email,
      photoURL: photoURL,
    );
  }

  String _extractInspectionId(dynamic inspection) {
    if (inspection == null) return '';

    try {
      final dynamic value = inspection.id;
      return value?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }
}

class SinistroViewer {
  final String uid;
  final String name;
  final String email;
  final String photoURL;
  final int lastSeenAtMillis;

  const SinistroViewer({
    required this.uid,
    required this.name,
    required this.email,
    required this.photoURL,
    required this.lastSeenAtMillis,
  });

  String get displayName {
    final cleanName = name.trim();
    if (cleanName.isNotEmpty) return cleanName;

    final cleanEmail = email.trim();
    if (cleanEmail.isNotEmpty) return cleanEmail;

    return 'Usuário';
  }

  factory SinistroViewer.fromMap(String id, Map<String, dynamic> data) {
    return SinistroViewer(
      uid: data['uid']?.toString() ?? id,
      name: data['name']?.toString() ?? '',
      email: data['email']?.toString() ?? '',
      photoURL: data['photoURL']?.toString() ?? '',
      lastSeenAtMillis: data['lastSeenAtMillis'] is int
          ? data['lastSeenAtMillis'] as int
          : 0,
    );
  }
}

class _UserPresenceProfile {
  final String uid;
  final String name;
  final String email;
  final String photoURL;

  const _UserPresenceProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.photoURL,
  });
}

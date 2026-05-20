import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SinistroPresenceService {
  SinistroPresenceService._();

  static final SinistroPresenceService instance = SinistroPresenceService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Timer? _heartbeatTimer;
  String? _currentSinistroId;
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

    await _writeViewer(cleanSinistroId);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _writeViewer(cleanSinistroId).catchError((_) {});
    });
  }

  Future<void> stopViewing() async {
    final user = _auth.currentUser;
    final sinistroId = _currentSinistroId;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _currentSinistroId = null;

    if (user == null || sinistroId == null || sinistroId.isEmpty) {
      return;
    }

    final viewerRef = _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .doc(user.uid);

    await viewerRef.delete().catchError((_) {});

    await _refreshActiveViewersSummary(sinistroId).catchError((_) {});
  }

  Future<void> _writeViewer(String sinistroId) async {
    final user = _auth.currentUser;

    if (user == null) return;

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
    );

    // Atualiza com dados completos do Firestore em background.
    // Assim o card recebe presença rápido, e a foto/nome definitivo chega logo depois.
    unawaited(() async {
      try {
        final fullProfile = await _loadUserProfile(user);
        _cachedProfile = fullProfile;

        await _writeViewerData(
          sinistroId: sinistroId,
          profile: fullProfile,
        );

        await _refreshActiveViewersSummary(sinistroId);
      } catch (_) {
        // Não deixa presença quebrar a tela.
      }
    }());
  }

  Future<void> _writeViewerData({
    required String sinistroId,
    required _UserPresenceProfile profile,
  }) async {
    final user = _auth.currentUser;

    if (user == null) return;

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
        .subtract(const Duration(seconds: 70))
        .millisecondsSinceEpoch;

    await _db.runTransaction((transaction) async {
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

      transaction.set(
        sinistroRef,
        {
          'activeViewers': updatedViewers.take(5).toList(),
          'activeViewersCount': updatedViewers.take(5).length,
          'activeViewersUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<void> _refreshActiveViewersSummary(String sinistroId) async {
    final cutoffMillis = DateTime.now()
        .subtract(const Duration(seconds: 70))
        .millisecondsSinceEpoch;

    final viewersSnap = await _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .where('lastSeenAtMillis', isGreaterThan: cutoffMillis)
        .limit(10)
        .get();

    final viewers = viewersSnap.docs.map((doc) {
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
    final cutoffMillis = DateTime.now()
        .subtract(const Duration(seconds: 70))
        .millisecondsSinceEpoch;

    return _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .where('lastSeenAtMillis', isGreaterThan: cutoffMillis)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => SinistroViewer.fromMap(doc.id, doc.data()))
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

    final cleanSinistroId = (sinistroId ?? _extractInspectionId(inspection)).trim();

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

    await _writeViewerData(
      sinistroId: cleanSinistroId,
      profile: profile,
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

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

    _currentSinistroId = cleanSinistroId;

    await _writeViewer(cleanSinistroId);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _writeViewer(cleanSinistroId);
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

    await _refreshActiveViewersSummary(sinistroId);
  }

  Future<void> _writeViewer(String sinistroId) async {
    final user = _auth.currentUser;

    if (user == null) return;

    final profile = await _loadUserProfile(user);
    final now = Timestamp.now();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    final viewerData = {
      'uid': user.uid,
      'name': profile.name,
      'email': profile.email,
      'photoURL': profile.photoURL,
      'openedAt': FieldValue.serverTimestamp(),
      'lastSeenAt': now,
      'lastSeenAtMillis': nowMillis,
    };

    await _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .doc(user.uid)
        .set(viewerData, SetOptions(merge: true));

    await _refreshActiveViewersSummary(sinistroId);
  }

  Future<void> _refreshActiveViewersSummary(String sinistroId) async {
    final cutoffMillis =
        DateTime.now().subtract(const Duration(seconds: 70)).millisecondsSinceEpoch;

    final viewersSnap = await _sinistros
        .doc(sinistroId)
        .collection('viewers')
        .where('lastSeenAtMillis', isGreaterThan: cutoffMillis)
        .limit(5)
        .get();

    final viewers = viewersSnap.docs.map((doc) {
      final data = doc.data();

      return {
        'uid': data['uid']?.toString() ?? doc.id,
        'name': data['name']?.toString() ?? '',
        'email': data['email']?.toString() ?? '',
        'photoURL': data['photoURL']?.toString() ?? '',
        'lastSeenAtMillis': data['lastSeenAtMillis'] ?? 0,
      };
    }).toList();

    await _sinistros.doc(sinistroId).set({
      'activeViewers': viewers,
      'activeViewersCount': viewers.length,
      'activeViewersUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<List<SinistroViewer>> watchViewers(String sinistroId) {
    final cutoffMillis =
        DateTime.now().subtract(const Duration(seconds: 70)).millisecondsSinceEpoch;

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

  Future<void> claimSinistroForCurrentUser({
    required String sinistroId,
    String action = 'check_in',
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    final profile = await _loadUserProfile(user);
    final sinistroRef = _sinistros.doc(sinistroId);

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
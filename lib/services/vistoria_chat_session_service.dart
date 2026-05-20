
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class VistoriaChatSessionService {
  VistoriaChatSessionService._();
  static final instance = VistoriaChatSessionService._();

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  static const activeStatus = 'em_andamento';
  static const abandonedStatus = 'abandonada';
  static const finishedStatus = 'finalizada';

  /// Trava de segurança: base64 dentro de Firestore estoura fácil o limite do documento.
  /// Para fotos/áudios grandes, prefira Storage + URL.
  static const maxBase64CharsPerEvidence = 650000;

  CollectionReference<Map<String, dynamic>> get _vistorias =>
      _db.collection('vistorias');
  CollectionReference<Map<String, dynamic>> get _sinistros =>
      _db.collection('sinistro');
  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _credenciados =>
      _db.collection('credenciados');

  Future<VistoriaSession?> findOpenVistoria({String? sinistroId}) async {
    final ctx = await _currentContext();

    Query<Map<String, dynamic>> query = _vistorias
        .where('inspectorId', isEqualTo: ctx.uid)
        .where('status', isEqualTo: activeStatus)
        .limit(5);

    if ((sinistroId ?? '').trim().isNotEmpty) {
      query = query.where('sinistroId', isEqualTo: sinistroId!.trim());
    }

    final snap = await query.get();

    if (snap.docs.isEmpty) return null;

    final docs = snap.docs.toList()
      ..sort((a, b) => _dateValue(b.data()['updatedAt'])
          .compareTo(_dateValue(a.data()['updatedAt'])));

    return VistoriaSession.fromFirestore(docs.first);
  }

  Future<List<SinistroVistoriaOption>> listCheckedInSinistrosForCurrentUser() async {
    final ctx = await _currentContext();

    if (ctx.credenciadoId.isEmpty) return [];

    final snap = await _sinistros
        .where('credenciadoId', isEqualTo: ctx.credenciadoId)
        .get();

    final list = snap.docs
        .where((doc) {
          final data = doc.data();
          final assignedToUid = _str(data['assignedToUid']);

          return _hasCheckIn(data['checkInAt']) && assignedToUid == ctx.uid;
        })
        .map(SinistroVistoriaOption.fromFirestore)
        .toList();

    list.sort((a, b) => a.placa.compareTo(b.placa));
    return list;
  }

  Future<VistoriaSession> createOrResumeFromSinistro({
    required String sinistroId,
    bool addInitialOiInHistory = true,
  }) async {
    final cleanSinistroId = sinistroId.trim();

    if (cleanSinistroId.isEmpty) {
      throw ArgumentError('sinistroId vazio.');
    }

    final existing = await findOpenVistoria(sinistroId: cleanSinistroId);
    if (existing != null) return existing;

    final ctx = await _currentContext();
    final sinistroDoc = await _sinistros.doc(cleanSinistroId).get();

    if (!sinistroDoc.exists) {
      throw Exception('Sinistro não encontrado: $cleanSinistroId');
    }

    final sinistro = sinistroDoc.data() ?? {};

    if (!_hasCheckIn(sinistro['checkInAt'])) {
      throw Exception('Este sinistro ainda não possui check-in.');
    }

    final assignedToUid = _str(sinistro['assignedToUid']);
    final assignedToName = _str(
      sinistro['assignedToName'],
      fallback: 'outro profissional',
    );

    if (assignedToUid.isEmpty) {
      throw Exception(
        'Faça o check-in e assuma a vistoria antes de iniciar o Chat IA.',
      );
    }

    if (assignedToUid != ctx.uid) {
      throw Exception(
        'Esta vistoria está vinculada a $assignedToName. Você pode visualizar, mas não continuar o Chat IA.',
      );
    }

    final idvistoria = await _createVistoriaId();
    final now = DateTime.now();

    final clienteSnapshot = _asMap(sinistro['clienteSnapshot']);
    final veiculoSnapshot = _asMap(sinistro['veiculoSnapshot']);
    final credenciadoSnapshot = _asMap(sinistro['credenciadoSnapshot']);

    final placa = _str(
      veiculoSnapshot['placa'],
      fallback: _str(sinistro['plate'], fallback: _str(sinistro['placa'])),
    );

    final veiculo = _vehicleName(
      marca: _str(veiculoSnapshot['marca']),
      modelo: _str(
        veiculoSnapshot['modelo'],
        fallback: _str(sinistro['vehicle'], fallback: _str(sinistro['veiculo'])),
      ),
    );

    final cliente = _str(
      clienteSnapshot['nomeCompleto'],
      fallback: _str(sinistro['owner'], fallback: _str(sinistro['cliente'])),
    );

    final credenciado = _str(
      credenciadoSnapshot['name'],
      fallback: _str(
        sinistro['credenciadoNome'],
        fallback: _str(sinistro['workshop'], fallback: ctx.credenciadoNome),
      ),
    );

    final chatMessages = <Map<String, dynamic>>[];

    if (addInitialOiInHistory) {
      chatMessages.add({
        'role': 'system',
        'text': 'Sessão de vistoria iniciada.',
        'createdAt': Timestamp.fromDate(now),
      });
      chatMessages.add({
        'role': 'user',
        'text': 'oi',
        'backgroundStart': true,
        'createdAt': Timestamp.fromDate(now),
      });
    }

    final data = {
      'audios': <Map<String, dynamic>>[],
      'chatmessages': chatMessages,
      'checkInAt': _str(sinistro['checkInAt']),
      'cliente': cliente,
      'credenciado': credenciado,
      'data': _formatDate(now),
      'descricaoArtigos': _str(
        sinistro['damageDescription'],
        fallback: _str(sinistro['descricaoArtigos']),
      ),
      'hora': _formatTime(now),
      'idvistoria': idvistoria,
      'images': <Map<String, dynamic>>[],
      'inspectorId': ctx.uid,
      'inspectorEmail': ctx.email,
      'laudo': '',
      'local': _str(credenciadoSnapshot['address'], fallback: _str(sinistro['local'])),
      'observacoes': _str(
        sinistro['observations'],
        fallback: _str(sinistro['observacoes']),
      ),
      'pdfLaudoUrl': '',
      'placa': placa,
      'sinistroId': cleanSinistroId,
      'status': activeStatus,
      'veiculo': veiculo,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await _vistorias.doc(idvistoria).set(data);

    return VistoriaSession(
      docId: idvistoria,
      idvistoria: idvistoria,
      sinistroId: cleanSinistroId,
      placa: placa,
      veiculo: veiculo,
      cliente: cliente,
      credenciado: credenciado,
      status: activeStatus,
      chatMessages: chatMessages,
    );
  }

  Future<void> discardVistoria({
    required String vistoriaDocId,
    bool hardDelete = true,
  }) async {
    await _assertVistoriaOwnedByCurrentUser(vistoriaDocId);

    final ref = _vistorias.doc(vistoriaDocId);

    if (hardDelete) {
      await ref.delete();
      return;
    }

    await ref.set({
      'status': abandonedStatus,
      'abandonedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> appendUserMessage({
    required String vistoriaDocId,
    required String text,
  }) {
    return appendChatMessage(vistoriaDocId: vistoriaDocId, role: 'user', text: text);
  }

  Future<void> appendAiMessage({
    required String vistoriaDocId,
    required String text,
  }) {
    return appendChatMessage(vistoriaDocId: vistoriaDocId, role: 'ai', text: text);
  }

  Future<void> appendChatMessage({
    required String vistoriaDocId,
    required String role,
    required String text,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    await _assertVistoriaOwnedByCurrentUser(vistoriaDocId);

    await _vistorias.doc(vistoriaDocId).set({
      'chatmessages': FieldValue.arrayUnion([
        {
          'role': role,
          'text': cleanText,
          'createdAt': Timestamp.now(),
        }
      ]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<String> appendImageBase64FromFile({
    required String vistoriaDocId,
    required String imagePath,
    String contentType = 'image/jpeg',
  }) {
    return _appendBase64Evidence(
      vistoriaDocId: vistoriaDocId,
      fieldName: 'images',
      filePath: imagePath,
      contentType: contentType,
    );
  }

  Future<String> appendAudioBase64FromFile({
    required String vistoriaDocId,
    required String audioPath,
    String contentType = 'audio/mpeg',
  }) {
    return _appendBase64Evidence(
      vistoriaDocId: vistoriaDocId,
      fieldName: 'audios',
      filePath: audioPath,
      contentType: contentType,
    );
  }

  Future<String> _appendBase64Evidence({
    required String vistoriaDocId,
    required String fieldName,
    required String filePath,
    required String contentType,
  }) async {
    await _assertVistoriaOwnedByCurrentUser(vistoriaDocId);

    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('Arquivo não encontrado.', filePath);
    }

    final bytes = await file.readAsBytes();
    final base64Value = base64Encode(bytes);

    if (base64Value.length > maxBase64CharsPerEvidence) {
      throw Exception(
        'Arquivo muito grande para base64 no Firestore. '
        'Tamanho base64: ${base64Value.length}. '
        'Reduza o arquivo ou use Storage + URL.',
      );
    }

    final ref = _vistorias.doc(vistoriaDocId);

    return _db.runTransaction((transaction) async {
      final snap = await transaction.get(ref);

      if (!snap.exists) {
        throw Exception('Vistoria não encontrada: $vistoriaDocId');
      }

      final data = snap.data() ?? {};
      final current = data[fieldName];
      final count = current is List ? current.length : 0;
      final key = 'vistoria_${count + 1}';

      final evidence = {
        key: base64Value,
        'fileName': file.uri.pathSegments.isEmpty ? key : file.uri.pathSegments.last,
        'contentType': contentType,
        'sizeBytes': bytes.length,
        'createdAt': Timestamp.now(),
      };

      transaction.set(
        ref,
        {
          fieldName: FieldValue.arrayUnion([evidence]),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      return key;
    });
  }

  Future<void> finishVistoria({
    required String vistoriaDocId,
    String? laudo,
    String? observacoes,
  }) async {
    await _assertVistoriaOwnedByCurrentUser(vistoriaDocId);

    await _vistorias.doc(vistoriaDocId).set({
      'status': finishedStatus,
      if (laudo != null) 'laudo': laudo,
      if (observacoes != null) 'observacoes': observacoes,
      'finishedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _assertVistoriaOwnedByCurrentUser(String vistoriaDocId) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    final snap = await _vistorias.doc(vistoriaDocId).get();

    if (!snap.exists) {
      throw Exception('Vistoria não encontrada: $vistoriaDocId');
    }

    final data = snap.data() ?? {};
    final inspectorId = _str(data['inspectorId']);

    if (inspectorId.isNotEmpty && inspectorId != user.uid) {
      throw Exception('Esta vistoria pertence a outro profissional.');
    }

    final sinistroId = _str(data['sinistroId']);

    if (sinistroId.isEmpty) return;

    final sinistroSnap = await _sinistros.doc(sinistroId).get();
    final sinistro = sinistroSnap.data() ?? {};
    final assignedToUid = _str(sinistro['assignedToUid']);

    if (assignedToUid.isNotEmpty && assignedToUid != user.uid) {
      final assignedToName = _str(
        sinistro['assignedToName'],
        fallback: 'outro profissional',
      );

      throw Exception('Esta vistoria está vinculada a $assignedToName.');
    }
  }

  Future<_CurrentContext> _currentContext() async {
    final user = _auth.currentUser;

    if (user == null) throw Exception('Usuário não autenticado.');

    final uid = user.uid;
    final email = (user.email ?? '').trim().toLowerCase();

    Map<String, dynamic> userData = {};

    if (email.isNotEmpty) {
      final byEmail = await _users.doc(email).get();
      userData = byEmail.data() ?? {};
    }

    if (userData.isEmpty) {
      final byUid = await _users.doc(uid).get();
      userData = byUid.data() ?? {};
    }

    String credenciadoId = _str(userData['credenciadoId']);
    String credenciadoNome = _str(userData['credenciadoNome']);

    if (credenciadoId.isEmpty) {
      final credSnap = await _credenciados
          .where('funcionariosUids', arrayContains: uid)
          .limit(1)
          .get();

      if (credSnap.docs.isNotEmpty) {
        final doc = credSnap.docs.first;
        final data = doc.data();

        credenciadoId = doc.id;
        credenciadoNome = _str(data['name']);
      }
    }

    return _CurrentContext(
      uid: uid,
      email: email,
      credenciadoId: credenciadoId,
      credenciadoNome: credenciadoNome,
    );
  }

 Future<String> _createVistoriaId() async {
  final year = DateTime.now().year;
  final counterRef = _db.collection('counters').doc('vistorias_$year');

  final nextNumber = await _db.runTransaction<int>((transaction) async {
    final snapshot = await transaction.get(counterRef);
    final data = snapshot.data();

    final current = snapshot.exists && data != null
        ? (data['lastNumber'] as int? ?? 0)
        : 0;

    final next = current + 1;

    transaction.set(
      counterRef,
      {
        'lastNumber': next,
        'year': year,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    return next;
  });

  return 'VIS-$year-${nextNumber.toString().padLeft(4, '0')}';
}

  static bool _hasCheckIn(dynamic value) {
    final text = _str(value).toLowerCase();
    return text.isNotEmpty && text != 'null' && text != 'false';
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;

    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }

    return <String, dynamic>{};
  }

  static String _str(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  static DateTime _dateValue(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String _vehicleName({
    required String marca,
    required String modelo,
  }) {
    if (marca.isEmpty && modelo.isEmpty) return '';
    if (marca.isEmpty) return modelo;
    if (modelo.isEmpty) return marca;

    if (modelo.toLowerCase().contains(marca.toLowerCase())) {
      return modelo;
    }

    return '$marca $modelo';
  }

  static String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final y = date.year.toString();
    return '$d/$m/$y';
  }

  static String _formatTime(DateTime date) {
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class VistoriaSession {
  final String docId;
  final String idvistoria;
  final String sinistroId;
  final String placa;
  final String veiculo;
  final String cliente;
  final String credenciado;
  final String status;
  final List<Map<String, dynamic>> chatMessages;

  const VistoriaSession({
    required this.docId,
    required this.idvistoria,
    required this.sinistroId,
    required this.placa,
    required this.veiculo,
    required this.cliente,
    required this.credenciado,
    required this.status,
    required this.chatMessages,
  });

  factory VistoriaSession.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};
    final rawMessages = data['chatmessages'];

    final messages = rawMessages is List
        ? rawMessages
            .whereType<Map>()
            .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
            .toList()
        : <Map<String, dynamic>>[];

    return VistoriaSession(
      docId: doc.id,
      idvistoria: VistoriaChatSessionService._str(data['idvistoria'], fallback: doc.id),
      sinistroId: VistoriaChatSessionService._str(data['sinistroId']),
      placa: VistoriaChatSessionService._str(data['placa']),
      veiculo: VistoriaChatSessionService._str(data['veiculo']),
      cliente: VistoriaChatSessionService._str(data['cliente']),
      credenciado: VistoriaChatSessionService._str(data['credenciado']),
      status: VistoriaChatSessionService._str(data['status']),
      chatMessages: messages,
    );
  }
}

class SinistroVistoriaOption {
  final String sinistroId;
  final String placa;
  final String veiculo;
  final String cliente;
  final String checkInAt;
  final String status;

  const SinistroVistoriaOption({
    required this.sinistroId,
    required this.placa,
    required this.veiculo,
    required this.cliente,
    required this.checkInAt,
    required this.status,
  });

  factory SinistroVistoriaOption.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final clienteSnapshot = VistoriaChatSessionService._asMap(data['clienteSnapshot']);
    final veiculoSnapshot = VistoriaChatSessionService._asMap(data['veiculoSnapshot']);

    final placa = VistoriaChatSessionService._str(
      veiculoSnapshot['placa'],
      fallback: VistoriaChatSessionService._str(
        data['plate'],
        fallback: VistoriaChatSessionService._str(data['placa']),
      ),
    );

    final veiculo = VistoriaChatSessionService._vehicleName(
      marca: VistoriaChatSessionService._str(veiculoSnapshot['marca']),
      modelo: VistoriaChatSessionService._str(
        veiculoSnapshot['modelo'],
        fallback: VistoriaChatSessionService._str(
          data['vehicle'],
          fallback: VistoriaChatSessionService._str(data['veiculo']),
        ),
      ),
    );

    final cliente = VistoriaChatSessionService._str(
      clienteSnapshot['nomeCompleto'],
      fallback: VistoriaChatSessionService._str(
        data['owner'],
        fallback: VistoriaChatSessionService._str(data['cliente']),
      ),
    );

    return SinistroVistoriaOption(
      sinistroId: doc.id,
      placa: placa,
      veiculo: veiculo,
      cliente: cliente,
      checkInAt: VistoriaChatSessionService._str(data['checkInAt']),
      status: VistoriaChatSessionService._str(data['status']),
    );
  }

  String get label {
    final p = placa.trim().isEmpty ? 'Sem placa' : placa.trim();
    final v = veiculo.trim().isEmpty ? 'Veículo não informado' : veiculo.trim();
    return '$p • $v';
  }
}

class _CurrentContext {
  final String uid;
  final String email;
  final String credenciadoId;
  final String credenciadoNome;

  const _CurrentContext({
    required this.uid,
    required this.email,
    required this.credenciadoId,
    required this.credenciadoNome,
  });
}

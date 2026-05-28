import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class VistoriaChatSessionService {
  VistoriaChatSessionService._();

  static final VistoriaChatSessionService instance =
      VistoriaChatSessionService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  static const String statusEmAndamento = 'EM_ANDAMENTO';
  static const String statusEmAnaliseOperacional = 'EM_ANALISE_OPERACIONAL';
  static const String statusFinalizada = 'FINALIZADA';
  static const String statusRejeitada = 'REJEITADA';
  static const String statusCancelada = 'CANCELADA';

  static const String tipoOriginal = 'ORIGINAL';
  static const String tipoRetificacao = 'RETIFICACAO';

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
        .where('status', isEqualTo: statusEmAndamento)
        .limit(10);

    if ((sinistroId ?? '').trim().isNotEmpty) {
      query = query.where('sinistroId', isEqualTo: sinistroId!.trim());
    }

    final snap = await query.get();

    if (snap.docs.isEmpty) return null;

    final docs = snap.docs.toList()
      ..sort(
        (a, b) => _dateValue(
          b.data()['updatedAt'],
        ).compareTo(_dateValue(a.data()['updatedAt'])),
      );

    return VistoriaSession.fromFirestore(docs.first);
  }

  Future<List<SinistroVistoriaOption>>
      listCheckedInSinistrosForCurrentUser() async {
    final ctx = await _currentContext();

    if (ctx.credenciadoId.isEmpty) return [];

    final snap = await _sinistros
        .where('credenciadoId', isEqualTo: ctx.credenciadoId)
        .get();

    final list = snap.docs
        .where((doc) => _hasCheckIn(doc.data()['checkInAt']))
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

    final idvistoria = await _createVistoriaId();
    final now = DateTime.now();

    final clienteSnapshot = _asMap(sinistro['clienteSnapshot']);
    final veiculoSnapshot = _asMap(sinistro['veiculoSnapshot']);
    final credenciadoSnapshot = _asMap(sinistro['credenciadoSnapshot']);

    final placa = _str(
      veiculoSnapshot['placa'],
      fallback: _str(
        sinistro['plate'],
        fallback: _str(sinistro['placa']),
      ),
    );

    final veiculo = _vehicleName(
      marca: _str(veiculoSnapshot['marca']),
      modelo: _str(
        veiculoSnapshot['modelo'],
        fallback: _str(
          sinistro['vehicle'],
          fallback: _str(sinistro['veiculo']),
        ),
      ),
    );

    final cliente = _str(
      clienteSnapshot['nomeCompleto'],
      fallback: _str(
        sinistro['owner'],
        fallback: _str(sinistro['cliente']),
      ),
    );

    final credenciado = _str(
      credenciadoSnapshot['name'],
      fallback: _str(
        sinistro['credenciadoNome'],
        fallback: _str(
          sinistro['workshop'],
          fallback: ctx.credenciadoNome,
        ),
      ),
    );

    final chatMessages = <Map<String, dynamic>>[];

    if (addInitialOiInHistory) {
      chatMessages.add({
        'role': 'system',
        'type': 'session_start',
        'text': 'Sessão de vistoria iniciada.',
        'createdAt': Timestamp.fromDate(now),
      });
      chatMessages.add({
        'role': 'user',
        'type': 'session_start',
        'text': 'oi',
        'backgroundStart': true,
        'createdAt': Timestamp.fromDate(now),
      });
    }

    final agentParameters = {
      'id_vistoria': idvistoria,
      'sinistro_id': cleanSinistroId,
      'placa_veiculo': placa,
      'modelo_veiculo': veiculo,
      'cliente_nome': cliente,
      'oficina_nome': credenciado,
      'prioridade_sinistro': _str(sinistro['priority']),
      'status_sinistro': _str(sinistro['status']),
      'tipo_sinistro': _str(sinistro['claimType']),
      'tipo_vistoria': tipoOriginal,
    };

    final data = {
      'idvistoria': idvistoria,
      'sinistroId': cleanSinistroId,
      'status': statusEmAndamento,
      'tipoVistoria': tipoOriginal,
      'checkInAt': _str(sinistro['checkInAt']),
      'cliente': cliente,
      'credenciado': credenciado,
      'data': _formatDate(now),
      'hora': _formatTime(now),
      'descricaoArtigos': _str(
        sinistro['damageDescription'],
        fallback: _str(sinistro['descricaoArtigos']),
      ),
      'local': _str(
        credenciadoSnapshot['address'],
        fallback: _str(sinistro['local']),
      ),
      'observacoes': _str(
        sinistro['observations'],
        fallback: _str(sinistro['observacoes']),
      ),
      'placa': placa,
      'veiculo': veiculo,
      'inspectorId': ctx.uid,
      'inspectorEmail': ctx.email,
      'audios': <Map<String, dynamic>>[],
      'images': <Map<String, dynamic>>[],
      'chatmessages': chatMessages,
      'lastAudioNumber': 0,
      'laudo': '',
      'pdfLaudoUrl': '',
      'agentParameters': agentParameters,
      'agentSessionPolicy': {
        'description': 'Sessão do agente Argos vinculada à vistoria.',
        'ttlBusinessHours': 24,
        'workdays': [1, 2, 3, 4, 5],
      },
      'agentSessionTtlSeconds': 86400,
      'agentLastTurnAt': FieldValue.serverTimestamp(),
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
      status: statusEmAndamento,
      tipoVistoria: tipoOriginal,
      vistoriaOrigemId: '',
      ajustesNecessarios: '',
      contextoVistoriaAnterior: '',
      chatMessages: chatMessages,
    );
  }

  Future<VistoriaSession> createRetificacaoFromVistoria({
    required VistoriaSession original,
    required String ajustesNecessarios,
    required String contextoVistoriaAnterior,
  }) async {
    final ctx = await _currentContext();
    final newId = await _createVistoriaId();
    final now = DateTime.now();

    final cleanAjustes = ajustesNecessarios.trim();
    final cleanContexto = contextoVistoriaAnterior.trim();

    final chatMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'type': 'retificacao_start',
        'text': 'Nova vistoria de retificação iniciada.',
        'createdAt': Timestamp.fromDate(now),
      },
      {
        'role': 'user',
        'type': 'retificacao_start',
        'text': 'Iniciar fluxo de correção',
        'ajustesNecessarios': cleanAjustes,
        'contextoVistoriaAnterior': cleanContexto,
        'backgroundStart': true,
        'createdAt': Timestamp.fromDate(now),
      },
    ];

    final agentParameters = {
      'id_vistoria': newId,
      'sinistro_id': original.sinistroId,
      'placa_veiculo': original.placa,
      'modelo_veiculo': original.veiculo,
      'cliente_nome': original.cliente,
      'oficina_nome': original.credenciado,
      'tipo_vistoria': tipoRetificacao,
      'vistoria_origem_id': original.idvistoria,
      'ajustes_necessarios': cleanAjustes,
      'contexto_vistoria_anterior': cleanContexto,
    };

    final data = {
      'idvistoria': newId,
      'sinistroId': original.sinistroId,
      'status': statusEmAndamento,
      'tipoVistoria': tipoRetificacao,
      'vistoriaOrigemId': original.idvistoria,
      'ajustesNecessarios': cleanAjustes,
      'contextoVistoriaAnterior': cleanContexto,
      'checkInAt': '',
      'cliente': original.cliente,
      'credenciado': original.credenciado,
      'data': _formatDate(now),
      'hora': _formatTime(now),
      'descricaoArtigos': cleanAjustes,
      'local': '',
      'observacoes': cleanContexto,
      'placa': original.placa,
      'veiculo': original.veiculo,
      'inspectorId': ctx.uid,
      'inspectorEmail': ctx.email,
      'audios': <Map<String, dynamic>>[],
      'images': <Map<String, dynamic>>[],
      'chatmessages': chatMessages,
      'lastAudioNumber': 0,
      'laudo': '',
      'pdfLaudoUrl': '',
      'agentParameters': agentParameters,
      'agentSessionPolicy': {
        'description': 'Sessão de retificação vinculada à vistoria original.',
        'ttlBusinessHours': 24,
        'workdays': [1, 2, 3, 4, 5],
      },
      'agentSessionTtlSeconds': 86400,
      'agentLastTurnAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final batch = _db.batch();

    final newRef = _vistorias.doc(newId);
    final originalRef = _vistorias.doc(original.docId);

    batch.set(newRef, data);

    batch.set(originalRef, {
      'status': statusRejeitada,
      'retificacaoAtualId': newId,
      'ajustesNecessarios': cleanAjustes,
      'motivoRejeicao': cleanAjustes,
      'rejeitadaEm': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();

    return VistoriaSession(
      docId: newId,
      idvistoria: newId,
      sinistroId: original.sinistroId,
      placa: original.placa,
      veiculo: original.veiculo,
      cliente: original.cliente,
      credenciado: original.credenciado,
      status: statusEmAndamento,
      tipoVistoria: tipoRetificacao,
      vistoriaOrigemId: original.idvistoria,
      ajustesNecessarios: cleanAjustes,
      contextoVistoriaAnterior: cleanContexto,
      chatMessages: chatMessages,
    );
  }

  Future<void> discardVistoria({
    required String vistoriaDocId,
    bool hardDelete = true,
  }) async {
    final ref = _vistorias.doc(vistoriaDocId);

    if (hardDelete) {
      await ref.delete();
      return;
    }

    await ref.set({
      'status': statusCancelada,
      'cancelledAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> submitForOperationalAnalysis({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusEmAnaliseOperacional,
      'submittedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markAsFinalizada({
    required String vistoriaDocId,
    String? operadorUid,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusFinalizada,
      if (operadorUid != null) 'analisadoPorUid': operadorUid,
      'finalizadaEm': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> rejectVistoria({
    required String vistoriaDocId,
    required String motivoRejeicao,
    required String ajustesNecessarios,
    String? operadorUid,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusRejeitada,
      'motivoRejeicao': motivoRejeicao.trim(),
      'ajustesNecessarios': ajustesNecessarios.trim(),
      if (operadorUid != null) 'analisadoPorUid': operadorUid,
      'rejeitadaEm': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> cancelVistoria({
    required String vistoriaDocId,
    String? motivoCancelamento,
    String? operadorUid,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusCancelada,
      if (motivoCancelamento != null)
        'motivoCancelamento': motivoCancelamento.trim(),
      if (operadorUid != null) 'analisadoPorUid': operadorUid,
      'cancelledAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> appendUserMessage({
    required String vistoriaDocId,
    required String text,
  }) {
    return appendChatMessage(
      vistoriaDocId: vistoriaDocId,
      role: 'user',
      text: text,
    );
  }

  Future<void> appendAiMessage({
    required String vistoriaDocId,
    required String text,
  }) {
    return appendChatMessage(
      vistoriaDocId: vistoriaDocId,
      role: 'ai',
      text: text,
    );
  }

  Future<void> appendChatMessage({
    required String vistoriaDocId,
    required String role,
    required String text,
    Map<String, dynamic>? extraData,
  }) async {
    final cleanText = text.trim();

    if (cleanText.isEmpty && role != 'audio') return;

    await _vistorias.doc(vistoriaDocId).set({
      'chatmessages': FieldValue.arrayUnion([
        {
          'role': role,
          'text': cleanText,
          if (extraData != null) ...extraData,
          'createdAt': Timestamp.now(),
        }
      ]),
      'agentLastTurnAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<UploadedImageEvidence> uploadImageFile({
    required String vistoriaDocId,
    required String imagePath,
  }) async {
    final file = File(imagePath);

    if (!await file.exists()) {
      throw FileSystemException('Imagem não encontrada.', imagePath);
    }

    final bytes = await file.length();
    final imageId = 'img_${DateTime.now().millisecondsSinceEpoch}';
    final fileName = '$imageId.jpg';
    final storagePath = 'vistorias/$vistoriaDocId/images/$fileName';

    final ref = _storage.ref(storagePath);

    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    final url = await ref.getDownloadURL();

    return UploadedImageEvidence(
      imageId: imageId,
      storagePath: storagePath,
      downloadUrl: url,
      fileName: fileName,
      contentType: 'image/jpeg',
      sizeBytes: bytes,
    );
  }

  Future<void> appendImageEvidence({
    required String vistoriaDocId,
    required String imageUrl,
    required String imagePath,
    required String imageId,
    required String storagePath,
    required String fileName,
    required String contentType,
    required int sizeBytes,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'images': FieldValue.arrayUnion([
        {
          'imageId': imageId,
          'url': imageUrl,
          'localPath': imagePath,
          'storagePath': storagePath,
          'fileName': fileName,
          'contentType': contentType,
          'sizeBytes': sizeBytes,
          'createdAt': Timestamp.now(),
        }
      ]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> finishVistoria({
    required String vistoriaDocId,
    String? laudo,
    String? observacoes,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusFinalizada,
      if (laudo != null) 'laudo': laudo,
      if (observacoes != null) 'observacoes': observacoes,
      'finalizadaEm': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> cleanupRootTranscriptionFields({
    int batchSize = 450,
  }) async {
    final snap = await _vistorias.limit(batchSize).get();

    if (snap.docs.isEmpty) return;

    final batch = _db.batch();

    for (final doc in snap.docs) {
      batch.update(doc.reference, {
        'transcriptionStatus': FieldValue.delete(),
        'ultimaTranscricaoOriginal': FieldValue.delete(),
        'ultimaTranscricaoRevisada': FieldValue.delete(),
      });
    }

    await batch.commit();
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
  final String tipoVistoria;
  final String vistoriaOrigemId;
  final String ajustesNecessarios;
  final String contextoVistoriaAnterior;
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
    required this.tipoVistoria,
    required this.vistoriaOrigemId,
    required this.ajustesNecessarios,
    required this.contextoVistoriaAnterior,
    required this.chatMessages,
  });

  bool get isRetificacao =>
      tipoVistoria.toUpperCase() == VistoriaChatSessionService.tipoRetificacao;

  factory VistoriaSession.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};
    final rawMessages = data['chatmessages'];

    final messages = rawMessages is List
        ? rawMessages
            .whereType<Map>()
            .map(
              (item) => item.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            )
            .toList()
        : <Map<String, dynamic>>[];

    return VistoriaSession(
      docId: doc.id,
      idvistoria: VistoriaChatSessionService._str(
        data['idvistoria'],
        fallback: doc.id,
      ),
      sinistroId: VistoriaChatSessionService._str(data['sinistroId']),
      placa: VistoriaChatSessionService._str(data['placa']),
      veiculo: VistoriaChatSessionService._str(data['veiculo']),
      cliente: VistoriaChatSessionService._str(data['cliente']),
      credenciado: VistoriaChatSessionService._str(data['credenciado']),
      status: VistoriaChatSessionService._str(data['status']),
      tipoVistoria: VistoriaChatSessionService._str(
        data['tipoVistoria'],
        fallback: VistoriaChatSessionService.tipoOriginal,
      ),
      vistoriaOrigemId: VistoriaChatSessionService._str(
        data['vistoriaOrigemId'],
      ),
      ajustesNecessarios: VistoriaChatSessionService._str(
        data['ajustesNecessarios'],
      ),
      contextoVistoriaAnterior: VistoriaChatSessionService._str(
        data['contextoVistoriaAnterior'],
      ),
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
    final clienteSnapshot = VistoriaChatSessionService._asMap(
      data['clienteSnapshot'],
    );
    final veiculoSnapshot = VistoriaChatSessionService._asMap(
      data['veiculoSnapshot'],
    );

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

class UploadedImageEvidence {
  final String imageId;
  final String storagePath;
  final String downloadUrl;
  final String fileName;
  final String contentType;
  final int sizeBytes;

  const UploadedImageEvidence({
    required this.imageId,
    required this.storagePath,
    required this.downloadUrl,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
  });
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

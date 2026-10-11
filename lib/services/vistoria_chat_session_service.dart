import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'argos_connectivity_service.dart';
import 'session_context_service.dart';

// Serviço central de vistorias: cria, busca, atualiza e sincroniza sessões
// de vistoria (e sua contraparte no sinistro), incluindo os fluxos offline.
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
  static const String statusExpirada = 'EXPIRADA';
  static const String statusAbandonada = 'ABANDONADA';

  static const String tipoOriginal = 'ORIGINAL';
  static const String tipoRetificacao = 'RETIFICACAO';

  CollectionReference<Map<String, dynamic>> get _vistorias =>
      _db.collection('vistorias');

  CollectionReference<Map<String, dynamic>> get _sinistros =>
      _db.collection('sinistro');

  // Observa o status da vistoria e se o laudo analítico já foi preenchido.
  Stream<VistoriaChatCompletionState> watchCompletionState({
    required String vistoriaDocId,
  }) {
    return _vistorias.doc(vistoriaDocId).snapshots().map((doc) {
      final data = doc.data() ?? <String, dynamic>{};
      final status = _str(data['status']);
      final hasAnalyticalReport = _hasFilledAnalyticalReport(data);

      return VistoriaChatCompletionState(
        status: status,
        isCompleted: status.isNotEmpty &&
            status != statusEmAndamento &&
            hasAnalyticalReport,
      );
    });
  }

  // Busca a vistoria EM_ANDAMENTO mais recente do inspetor atual (opcionalmente
  // filtrando por sinistro), expirando no caminho as que já passaram do prazo.
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

    for (final doc in docs) {
      final session = VistoriaSession.fromFirestore(doc);

      if (!session.isAgentSessionExpired) {
        return session;
      }

      await _expireVistoria(vistoriaDocId: doc.id);
    }

    return null;
  }

  // Lista os sinistros com check-in atribuídos ao mecânico atual que ainda
  // podem receber uma vistoria nova (fonte de dados do picker do Argos IA).
  Future<List<SinistroVistoriaOption>>
      listCheckedInSinistrosForCurrentUser() async {
    final ctx = await _currentContext();

    if (ctx.credenciadoId.isEmpty) return [];

    final snap = await _sinistros
        .where('credenciadoId', isEqualTo: ctx.credenciadoId)
        .get();

    final list = snap.docs
        .where((doc) {
          final data = doc.data();
          final assignedToUid = _str(data['assignedToUid']);
          final vistoriaStatus = _str(data['vistoriaAtualStatus']).toUpperCase();

          final isMine = assignedToUid == ctx.uid;

          final isBlocked = vistoriaStatus.contains('ANALISE') ||
              vistoriaStatus.contains('FINALIZADA') ||
              vistoriaStatus.contains('FINALIZADO') ||
              vistoriaStatus.contains('APROVADA') ||
              vistoriaStatus.contains('APROVADO') ||
              vistoriaStatus.contains('CANCELADA') ||
              vistoriaStatus.contains('REJEITADA');

          return _hasCheckIn(data['checkInAt']) && isMine && !isBlocked;
        })
        .map(SinistroVistoriaOption.fromFirestore)
        .toList();

    list.sort((a, b) => a.placa.compareTo(b.placa));

    return list;
  }

  // Reaproveita a vistoria em andamento do sinistro, se houver, ou cria uma
  // nova (modo online) a partir dos dados do sinistro e do contexto do user.
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

    final sinistroCredenciadoId = _str(sinistro['credenciadoId']);

    if (ctx.credenciadoId.isNotEmpty &&
        sinistroCredenciadoId.isNotEmpty &&
        sinistroCredenciadoId != ctx.credenciadoId) {
      throw Exception('Este sinistro não pertence à sua oficina.');
    }

    final assignedToUid = _str(sinistro['assignedToUid']);

    if (assignedToUid.isNotEmpty && assignedToUid != ctx.uid) {
      final assignedToName = _str(
        sinistro['assignedToName'],
        fallback: 'outro profissional',
      );

      throw Exception('Esta vistoria está vinculada a $assignedToName.');
    }

    final idvistoria = await _createVistoriaId();
    final now = DateTime.now();
    final agentExpiresAt = _addBusinessHours(now, 24);

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
      'credenciadoId': ctx.credenciadoId,
      'credenciadoNome': ctx.credenciadoNome,
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
      'inspectorName': ctx.nome,
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
      'agentBusinessExpiresAt': Timestamp.fromDate(agentExpiresAt),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final batch = _db.batch();

    batch.set(_vistorias.doc(idvistoria), data);
    batch.set(
      _sinistros.doc(cleanSinistroId),
      {
        'vistoriaAtualId': idvistoria,
        'vistoriaAtualStatus': statusEmAndamento,
        'vistoriaAtualTipo': tipoOriginal,
        'vistoriaAtualOrigemId': FieldValue.delete(),
        'retificacaoAtualId': FieldValue.delete(),
        'ultimaVistoriaAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    await batch.commit();

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

  // Prefixo que marca um docId de vistoria como provisório/offline, ainda sem
  // o número sequencial real (ver `reconcilePendingVistoriaId`).
  static const String pendingVistoriaIdPrefix = 'VIS-OFFLINE-';

  bool isPendingVistoriaId(String vistoriaDocId) =>
      vistoriaDocId.startsWith(pendingVistoriaIdPrefix);

  // Gera o sufixo numérico de 4 dígitos usado no id provisório offline.
  static String _randomOfflineSuffix() =>
      Random().nextInt(10000).toString().padLeft(4, '0');

  // Executa uma escrita no Firestore sem esperar o round-trip com o servidor
  // quando offline (fica rodando em segundo plano); online, espera normal.
  Future<void> _writeNoWaitOffline(
    Future<void> Function() write, {
    required String debugLabel,
  }) async {
    if (ArgosConnectivityService.instance.isOnline.value) {
      await write().timeout(const Duration(seconds: 45));
      return;
    }

    unawaited(
      write().catchError((e) {
        debugPrint(
          'Sincronização em segundo plano ($debugLabel) falhou -- dado '
          'já estava correto no cache local: $e',
        );
      }),
    );
  }

  // Lê um doc do cache local quando offline (evita ficar pendurado esperando
  // rede); online, é um `.get()` normal com timeout de segurança.
  Future<DocumentSnapshot<Map<String, dynamic>>> _getCacheAware(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    final online = ArgosConnectivityService.instance.isOnline.value;

    if (!online) {
      return ref.get(const GetOptions(source: Source.cache));
    }

    return ref.get().timeout(const Duration(seconds: 8));
  }

  // Cria uma vistoria 100% offline (modo em_massa, com id provisório) a
  // partir dos dados do sinistro já em cache local.
  Future<VistoriaSession> createVistoriaOffline({
    required String sinistroId,
  }) async {
    final cleanSinistroId = sinistroId.trim();

    if (cleanSinistroId.isEmpty) {
      throw ArgumentError('sinistroId vazio.');
    }

    final ctx = await _currentContext();

    final sinistroDoc = await _getCacheAware(_sinistros.doc(cleanSinistroId));

    if (!sinistroDoc.exists) {
      throw Exception('Sinistro não encontrado no cache: $cleanSinistroId');
    }

    final sinistro = sinistroDoc.data() ?? {};
    final tempId = '$pendingVistoriaIdPrefix${_randomOfflineSuffix()}';
    final now = DateTime.now();
    final agentExpiresAt = _addBusinessHours(now, 24);

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

    final agentParameters = {
      'id_vistoria': tempId,
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
      'idvistoria': tempId,
      'sinistroId': cleanSinistroId,
      'status': statusEmAndamento,
      'coletaModo': 'em_massa',
      'credenciadoId': ctx.credenciadoId,
      'credenciadoNome': ctx.credenciadoNome,
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
      'inspectorName': ctx.nome,
      'inspectorEmail': ctx.email,
      'audios': <Map<String, dynamic>>[],
      'images': <Map<String, dynamic>>[],
      'chatmessages': <Map<String, dynamic>>[],
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
      'agentLastTurnAt': Timestamp.fromDate(now),
      'agentBusinessExpiresAt': Timestamp.fromDate(agentExpiresAt),
      'createdAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
    };

    final batch = _db.batch();

    batch.set(_vistorias.doc(tempId), data);
    batch.set(
      _sinistros.doc(cleanSinistroId),
      {
        'vistoriaAtualId': tempId,
        'vistoriaAtualStatus': statusEmAndamento,
        'vistoriaAtualTipo': tipoOriginal,
        'vistoriaAtualOrigemId': FieldValue.delete(),
        'retificacaoAtualId': FieldValue.delete(),
        'ultimaVistoriaAt': Timestamp.fromDate(now),
      },
      SetOptions(merge: true),
    );

    await _writeNoWaitOffline(
      () => batch.commit(),
      debugLabel: 'criar vistoria offline $tempId',
    );

    return VistoriaSession(
      docId: tempId,
      idvistoria: tempId,
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
      chatMessages: const [],
      coletaModo: 'em_massa',
    );
  }

  // Troca o docId provisório de uma vistoria offline pelo número sequencial
  // real, copiando o doc inteiro e apagando o provisório atomicamente.
  Future<String> reconcilePendingVistoriaId({
    required String tempDocId,
    required String sinistroId,
  }) async {
    if (!isPendingVistoriaId(tempDocId)) return tempDocId;

    final doc = await _vistorias.doc(tempDocId).get();

    if (!doc.exists) return tempDocId;

    final data = Map<String, dynamic>.from(doc.data() ?? {});

    final rascunhoAindaPendente = _asMap(data['envioEmMassaRascunho'])
        .values
        .any((item) => item is Map && item['status'] != 'enviado');

    if (rascunhoAindaPendente) return tempDocId;

    final realId = await _createVistoriaId();

    data['idvistoria'] = realId;
    data['updatedAt'] = FieldValue.serverTimestamp();

    final agentParameters = _asMap(data['agentParameters']);

    if (agentParameters.isNotEmpty) {
      data['agentParameters'] = {
        ...agentParameters,
        'id_vistoria': realId,
      };
    }

    final batch = _db.batch();

    batch.set(_vistorias.doc(realId), data);
    batch.update(_sinistros.doc(sinistroId), {'vistoriaAtualId': realId});
    batch.delete(_vistorias.doc(tempDocId));

    await batch.commit();

    return realId;
  }

  // Cria uma nova vistoria de retificação a partir de uma vistoria rejeitada,
  // marcando a original como REJEITADA e apontando o sinistro pra nova.
  Future<VistoriaSession> createRetificacaoFromVistoria({
    required VistoriaSession original,
    required String ajustesNecessarios,
    required String contextoVistoriaAnterior,
  }) async {
    final ctx = await _currentContext();
    final newId = await _createVistoriaId();
    final now = DateTime.now();
    final agentExpiresAt = _addBusinessHours(now, 24);

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
      'credenciadoId': ctx.credenciadoId,
      'credenciadoNome': ctx.credenciadoNome,
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
      'inspectorName': ctx.nome,
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
      'agentBusinessExpiresAt': Timestamp.fromDate(agentExpiresAt),
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

    batch.set(
      _sinistros.doc(original.sinistroId),
      {
        'vistoriaAtualId': newId,
        'vistoriaAtualStatus': statusEmAndamento,
        'vistoriaAtualTipo': tipoRetificacao,
        'vistoriaAtualOrigemId': original.idvistoria,
        'retificacaoAtualId': newId,
        'ultimaVistoriaAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

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

  // Busca uma vistoria específica pelo id do documento.
  Future<VistoriaSession?> getVistoriaById(String vistoriaDocId) async {
    final doc = await _vistorias.doc(vistoriaDocId).get();
    if (!doc.exists) return null;
    return VistoriaSession.fromFirestore(doc);
  }

  // Busca a vistoria que o sinistro aponta como atual (vistoriaAtualId).
  Future<VistoriaSession?> getVistoriaAtualDoSinistro({
    required String sinistroId,
  }) async {
    final sinistroDoc = await _sinistros.doc(sinistroId).get();
    final vistoriaAtualId = _str(sinistroDoc.data()?['vistoriaAtualId']);

    if (vistoriaAtualId.isEmpty) return null;

    final vistoriaDoc = await _vistorias.doc(vistoriaAtualId).get();
    if (!vistoriaDoc.exists) return null;

    return VistoriaSession.fromFirestore(vistoriaDoc);
  }

  // Ponto de entrada da retificação: acha a vistoria rejeitada do sinistro e
  // cria a nova vistoria de correção a partir dela.
  Future<VistoriaSession> startRetificacaoFromSinistro({
    required String sinistroId,
  }) async {
    final original = await getVistoriaAtualDoSinistro(sinistroId: sinistroId);

    if (original == null) {
      throw Exception(
        'Não foi encontrada uma vistoria rejeitada para este sinistro.',
      );
    }

    return createRetificacaoFromVistoria(
      original: original,
      ajustesNecessarios: original.ajustesNecessarios,
      contextoVistoriaAnterior: original.contextoVistoriaAnterior,
    );
  }

  // Cancela e opcionalmente apaga de vez uma vistoria (e sua subcoleção de
  // áudios), sincronizando o status de volta no sinistro.
  Future<void> discardVistoria({
    required String vistoriaDocId,
    bool hardDelete = true,
  }) async {
    final ref = _vistorias.doc(vistoriaDocId);

    if (hardDelete) {
      await _syncSinistroVistoriaStatus(
        vistoriaDocId: vistoriaDocId,
        status: statusCancelada,
      );

      await _deleteSubcollection(ref.collection('audios'));

      await ref.delete();
      return;
    }

    await ref.set({
      'status': statusCancelada,
      'cancelledAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusCancelada,
    );
  }

  // Marca a vistoria como ABANDONADA ("Começar nova" do mecânico), liberando
  // o sinistro pra uma nova tentativa sem envolver decisão do analista.
  Future<void> abandonVistoria({required String vistoriaDocId}) async {
    await _writeNoWaitOffline(
      () => _vistorias.doc(vistoriaDocId).set({
        'status': statusAbandonada,
        'abandonedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)),
      debugLabel: 'abandonar vistoria $vistoriaDocId',
    );

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusAbandonada,
    );
  }

  // Apaga todos os documentos de uma subcoleção em lotes.
  Future<void> _deleteSubcollection(
    CollectionReference<Map<String, dynamic>> collection, {
    int batchSize = 450,
  }) async {
    while (true) {
      final snap = await collection.limit(batchSize).get();

      if (snap.docs.isEmpty) return;

      final batch = _db.batch();

      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();

      if (snap.docs.length < batchSize) return;
    }
  }

  // Marca a vistoria como EXPIRADA e sincroniza o status no sinistro.
  Future<void> _expireVistoria({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusExpirada,
      'expiredAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusExpirada,
    );
  }

  // Envia a vistoria pra análise operacional e sincroniza o sinistro.
  Future<void> submitForOperationalAnalysis({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'status': statusEmAnaliseOperacional,
      'submittedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusEmAnaliseOperacional,
    );
  }

  // Marca a vistoria como FINALIZADA e sincroniza o sinistro.
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

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusFinalizada,
    );
  }

  // Rejeita a vistoria, registrando motivo e ajustes necessários, e marca o
  // sinistro como precisando de retificação.
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

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusRejeitada,
      extra: {
        'precisaRetificacao': true,
        'motivoRejeicao': motivoRejeicao.trim(),
        'ajustesNecessarios': ajustesNecessarios.trim(),
      },
    );
  }

  // Cancela a vistoria e sincroniza o sinistro.
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

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusCancelada,
      extra: {
        if (motivoCancelamento != null)
          'motivoCancelamento': motivoCancelamento.trim(),
      },
    );
  }

  // Adiciona uma mensagem do usuário ao histórico de chat da vistoria.
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

  // Adiciona uma mensagem da IA ao histórico de chat da vistoria.
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

  // Adiciona uma mensagem genérica ao histórico de chat da vistoria.
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

  // Persiste o modo de coleta (guiado/em_massa) escolhido pelo mecânico.
  Future<void> setColetaModo({
    required String vistoriaDocId,
    required String coletaModo,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'coletaModo': coletaModo,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Adiciona um item de orçamento digitado pelo mecânico (envio em massa).
  Future<void> appendOrcamentoMecanicoItem({
    required String vistoriaDocId,
    required String peca,
    required String tipoIntervencao,
    required double valorPeca,
    required double horasMaoObra,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'orcamentoRascunho': FieldValue.arrayUnion([
        {
          'peca': peca.trim(),
          'tipoIntervencao': tipoIntervencao.trim(),
          'valorPeca': valorPeca,
          'horasMaoObra': horasMaoObra,
          'origem': 'mecanico',
        }
      ]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Grava/atualiza um item do rascunho de envio em massa, por localId.
  Future<void> upsertEnvioEmMassaRascunhoItem({
    required String vistoriaDocId,
    required String localId,
    required Map<String, dynamic> item,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'envioEmMassaRascunho': {localId: item},
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Remove um item do rascunho de envio em massa.
  Future<void> removeEnvioEmMassaRascunhoItem({
    required String vistoriaDocId,
    required String localId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho.$localId': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Marca um item do rascunho de envio em massa como já enviado.
  Future<void> markEnvioEmMassaRascunhoItemEnviado({
    required String vistoriaDocId,
    required String localId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho.$localId.status': 'enviado',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Lê o estado mais recente do rascunho de envio em massa direto do servidor.
  Future<Map<String, dynamic>> fetchEnvioEmMassaRascunho(
    String vistoriaDocId,
  ) async {
    final doc = await _vistorias.doc(vistoriaDocId).get();
    final raw = doc.data()?['envioEmMassaRascunho'];

    if (raw is! Map) return {};

    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  // Limpa o rascunho de envio em massa e a marca de confirmado offline.
  Future<void> clearEnvioEmMassaRascunho({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho': FieldValue.delete(),
      'envioEmMassaConfirmadoOffline': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Marca que o mecânico confirmou o envio em massa enquanto offline.
  Future<void> markEnvioEmMassaConfirmadoOffline({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'envioEmMassaConfirmadoOffline': true,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    }, SetOptions(merge: true));
  }

  // Sobe uma foto pro Storage e retorna seus metadados de evidência.
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

  // Adiciona os metadados de uma foto já enviada à lista de imagens da vistoria.
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

  // Finaliza a vistoria com o laudo/observações informados.
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

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusFinalizada,
    );
  }

  // Remove campos legados de transcrição de todos os docs de vistoria,
  // paginando a coleção inteira.
  Future<void> cleanupRootTranscriptionFields({
    int batchSize = 450,
  }) async {
    Query<Map<String, dynamic>> query = _vistorias
        .orderBy(FieldPath.documentId)
        .limit(batchSize);

    while (true) {
      final snap = await query.get();

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

      if (snap.docs.length < batchSize) return;

      query = _vistorias
          .orderBy(FieldPath.documentId)
          .startAfterDocument(snap.docs.last)
          .limit(batchSize);
    }
  }

  // Espelha o status/tipo atual da vistoria de volta nos campos do sinistro.
  Future<void> _syncSinistroVistoriaStatus({
    required String vistoriaDocId,
    required String status,
    Map<String, dynamic> extra = const {},
  }) async {
    final vistoriaDoc = await _getCacheAware(_vistorias.doc(vistoriaDocId));
    final data = vistoriaDoc.data() ?? <String, dynamic>{};
    final sinistroId = _str(data['sinistroId']);

    if (sinistroId.isEmpty) return;

    final tipoVistoria = _str(data['tipoVistoria'], fallback: tipoOriginal);
    final origemId = _str(data['vistoriaOrigemId']);

    await _writeNoWaitOffline(
      () => _sinistros.doc(sinistroId).set({
        'vistoriaAtualId': _str(data['idvistoria'], fallback: vistoriaDocId),
        'vistoriaAtualStatus': status,
        'vistoriaAtualTipo': tipoVistoria,
        'vistoriaAtualOrigemId':
            origemId.isEmpty ? FieldValue.delete() : origemId,
        'ultimaVistoriaAt': FieldValue.serverTimestamp(),
        ...extra,
      }, SetOptions(merge: true)),
      debugLabel: 'sincronizar status do sinistro $sinistroId',
    );
  }

  // Resolve uid/email/nome/credenciado do usuário logado, via
  // SessionContextService, tratando o caso de usuário sem credenciado vinculado.
  Future<_CurrentContext> _currentContext() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    try {
      final session = await SessionContextService.instance.resolve();

      return _CurrentContext(
        uid: session.uid,
        email: session.email,
        nome: session.nome,
        credenciadoId: session.credenciadoId,
        credenciadoNome: session.credenciadoNome,
      );
    } on NoCredenciadoLinkedException {
      final email = (user.email ?? '').trim().toLowerCase();

      return _CurrentContext(
        uid: user.uid,
        email: email,
        nome: email.isEmpty ? user.uid : email,
        credenciadoId: '',
        credenciadoNome: '',
      );
    }
  }

  // Gera o próximo id sequencial `VIS-YYYY-NNNN` via transação no contador
  // do ano corrente.
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
    }).timeout(const Duration(seconds: 15));

    return 'VIS-$year-${nextNumber.toString().padLeft(4, '0')}';
  }

  // Verifica se um valor de checkInAt representa um check-in válido.
  static bool _hasCheckIn(dynamic value) {
    final text = _str(value).toLowerCase();

    return text.isNotEmpty && text != 'null' && text != 'false';
  }

  // Converte qualquer Map dinâmico num Map<String, dynamic>.
  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;

    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }

    return <String, dynamic>{};
  }

  // Converte um valor dinâmico pra String, usando fallback se vazio/nulo.
  static String _str(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;

    final text = value.toString().trim();

    return text.isEmpty ? fallback : text;
  }

  // Verifica se o doc já tem algum campo de laudo analítico preenchido.
  static bool _hasFilledAnalyticalReport(Map<String, dynamic> data) {
    const candidateFields = [
      'laudo_analitico',
      'laudoAnalitico',
    ];

    return candidateFields.any((field) => _hasAnyFilledValue(data[field]));
  }

  // Verifica recursivamente se um valor (String/Iterable/Map) tem conteúdo.
  static bool _hasAnyFilledValue(dynamic value) {
    if (value == null) return false;

    if (value is String) return value.trim().isNotEmpty;

    if (value is Iterable) {
      return value.any(_hasAnyFilledValue);
    }

    if (value is Map) {
      return value.values.any(_hasAnyFilledValue);
    }

    return true;
  }

  // Converte Timestamp/DateTime pra DateTime, com fallback pra epoch.
  static DateTime _dateValue(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Converte Timestamp/DateTime/String pra DateTime, ou null se inválido.
  static DateTime? _dateValueOrNull(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }

  // Soma N horas úteis (dias de semana) a uma data, pulando fins de semana.
  static DateTime _addBusinessHours(DateTime startDate, int hours) {
    if (hours <= 0) return startDate;

    var current = _normalizeBusinessStart(startDate);
    var remaining = hours;

    while (remaining > 0) {
      if (_isBusinessDay(current)) {
        remaining -= 1;
      }

      current = _normalizeBusinessStart(current.add(const Duration(hours: 1)));
    }

    return current;
  }

  // Avança a data até cair num dia útil, se já não estiver em um.
  static DateTime _normalizeBusinessStart(DateTime date) {
    var current = date;

    while (!_isBusinessDay(current)) {
      current = current.add(const Duration(days: 1));
    }

    return current;
  }

  // Verifica se a data cai de segunda a sexta.
  static bool _isBusinessDay(DateTime date) {
    return date.weekday >= DateTime.monday && date.weekday <= DateTime.friday;
  }

  // Monta o nome de exibição do veículo a partir de marca e modelo.
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

  // Formata a data como dd/mm/yyyy.
  static String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final y = date.year.toString();

    return '$d/$m/$y';
  }

  // Formata a hora como hh:mm.
  static String _formatTime(DateTime date) {
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');

    return '$h:$m';
  }
}

// Status atual da vistoria e se o laudo analítico já foi concluído.
class VistoriaChatCompletionState {
  final String status;
  final bool isCompleted;

  const VistoriaChatCompletionState({
    required this.status,
    required this.isCompleted,
  });
}

// Representa uma sessão de vistoria (dados do veículo/sinistro, status,
// histórico de chat e estado do envio em massa).
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
  final String motivoRejeicao;
  final List<Map<String, dynamic>> chatMessages;
  final DateTime? agentLastTurnAt;
  final DateTime? agentBusinessExpiresAt;

  // Modo de coleta: 'guiado' | 'em_massa' | '' (vistorias antigas).
  final String coletaModo;

  // Rascunho do envio em massa no momento em que a sessão foi carregada.
  final Map<String, dynamic> envioEmMassaRascunho;

  // true se o mecânico já confirmou o envio em massa enquanto offline.
  final bool envioEmMassaConfirmadoOffline;

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
    this.motivoRejeicao = '',
    required this.chatMessages,
    this.agentLastTurnAt,
    this.agentBusinessExpiresAt,
    this.coletaModo = '',
    this.envioEmMassaRascunho = const {},
    this.envioEmMassaConfirmadoOffline = false,
  });

  // Se a vistoria está no modo de envio em massa.
  bool get isEmMassa => coletaModo == 'em_massa';

  // Se a vistoria é uma retificação (correção de uma vistoria rejeitada).
  bool get isRetificacao =>
      tipoVistoria.toUpperCase() == VistoriaChatSessionService.tipoRetificacao;

  // Se a sessão do agente (ADK) já passou do prazo de expiração.
  bool get isAgentSessionExpired {
    final expiresAt = agentBusinessExpiresAt ??
        (agentLastTurnAt == null
            ? null
            : VistoriaChatSessionService._addBusinessHours(
                agentLastTurnAt!,
                24,
              ));

    if (expiresAt == null) return false;

    return DateTime.now().isAfter(expiresAt);
  }

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
      motivoRejeicao: VistoriaChatSessionService._str(
        data['motivoRejeicao'],
      ),
      chatMessages: messages,
      agentLastTurnAt: VistoriaChatSessionService._dateValueOrNull(
        data['agentLastTurnAt'],
      ),
      agentBusinessExpiresAt: VistoriaChatSessionService._dateValueOrNull(
        data['agentBusinessExpiresAt'],
      ),
      coletaModo: VistoriaChatSessionService._str(data['coletaModo']),
      envioEmMassaRascunho: (data['envioEmMassaRascunho'] is Map)
          ? (data['envioEmMassaRascunho'] as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            )
          : const {},
      envioEmMassaConfirmadoOffline:
          data['envioEmMassaConfirmadoOffline'] == true,
    );
  }
}

// Opção de sinistro com check-in elegível a receber uma vistoria, exibida no picker do Argos IA.
class SinistroVistoriaOption {
  final String sinistroId;
  final String placa;
  final String veiculo;
  final String cliente;
  final String checkInAt;
  final String status;
  // vistoriaAtualStatus do sinistro — não confundir com `status` acima (esse
  // é o sinistro.status, que fica EM_ANDAMENTO o tempo todo até finalizar).
  final String vistoriaStatus;

  const SinistroVistoriaOption({
    required this.sinistroId,
    required this.placa,
    required this.veiculo,
    required this.cliente,
    required this.checkInAt,
    required this.status,
    required this.vistoriaStatus,
  });

  bool get isRetificacaoPendente =>
      vistoriaStatus.toUpperCase().contains('REJEITADA');

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
      vistoriaStatus: VistoriaChatSessionService._str(data['vistoriaAtualStatus']),
    );
  }

  String get label {
    final p = placa.trim().isEmpty ? 'Sem placa' : placa.trim();
    final v = veiculo.trim().isEmpty ? 'Veículo não informado' : veiculo.trim();

    return '$p • $v';
  }
}

// Metadados de uma foto de evidência já enviada ao Storage.
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

// Dados do usuário logado resolvidos (uid, email, nome e oficina vinculada).
class _CurrentContext {
  final String uid;
  final String email;
  final String nome;
  final String credenciadoId;
  final String credenciadoNome;

  const _CurrentContext({
    required this.uid,
    required this.email,
    required this.nome,
    required this.credenciadoId,
    required this.credenciadoNome,
  });
}

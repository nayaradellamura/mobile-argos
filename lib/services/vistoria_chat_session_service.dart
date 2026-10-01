import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'argos_connectivity_service.dart';
import 'session_context_service.dart';

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

          // Só o veículo atribuído ao mecânico logado — sinistros ainda sem
          // dono (assignedToUid vazio) não aparecem aqui mais, mesmo sendo
          // da mesma oficina.
          final isMine = assignedToUid == ctx.uid;

          // Em andamento (estado normal após o check-in), rejeitada
          // (precisa de retificação), ou abandonada/expirada (o mecânico
          // pode começar uma vistoria nova do zero pra ela, igual ao botão
          // "Começar nova" já permite -- sem isso, uma vistoria abandonada
          // simplesmente sumia desta lista e não dava pra selecionar o
          // veículo de novo). Exclui EM_ANALISE_OPERACIONAL (já enviada),
          // FINALIZADA e CANCELADA de verdade (decisão do analista).
          final isEmAndamento = vistoriaStatus.contains('ANDAMENTO');
          final isRejeitada = vistoriaStatus.contains('REJEITADA');
          final isAbandonadaOuExpirada = vistoriaStatus.contains('ABANDONADA') ||
              vistoriaStatus.contains('EXPIRADA');

          return _hasCheckIn(data['checkInAt']) &&
              isMine &&
              (isEmAndamento || isRejeitada || isAbandonadaOuExpirada);
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

  /// Prefixo que marca um docId de vistoria como provisório -- criado
  /// 100% offline, ainda sem o número sequencial real (esse exige uma
  /// transação contra `counters/vistorias_{year}`, que não enfileira
  /// offline como uma escrita comum). É só uma convenção de nome, não um
  /// campo novo no schema -- ver `reconcilePendingVistoriaId`.
  ///
  /// Formato `VIS-OFFLINE-NNNN` (4 dígitos aleatórios) pra seguir o mesmo
  /// padrão visual de `VIS-YYYY-NNNN` -- risco de colisão aceito de
  /// propósito (só 10 mil combinações): pedido explícito do usuário por
  /// um número curto e legível pro mecânico, e o volume real de vistorias
  /// offline simultâneas neste app é baixo o bastante pra isso não ser um
  /// problema prático. Se colidir, o segundo a sincronizar sobrescreve o
  /// primeiro -- mesma categoria de risco já aceita em
  /// `reconcilePendingVistoriaId` (número sequencial "queimado").
  static const String pendingVistoriaIdPrefix = 'VIS-OFFLINE-';

  bool isPendingVistoriaId(String vistoriaDocId) =>
      vistoriaDocId.startsWith(pendingVistoriaIdPrefix);

  static String _randomOfflineSuffix() =>
      Random().nextInt(10000).toString().padLeft(4, '0');

  /// Cria uma vistoria do zero 100% offline. Só chamada quando o sinistro
  /// já tem check-in feito (é assim que ele aparece em "Minhas vistorias" --
  /// check-in e atribuição são gravados juntos pela mesma transação, então
  /// nunca existe uma vistoria alcançável por aqui sem check-in já
  /// confirmado online antes) -- por isso este método NUNCA precisa chamar
  /// a transação de check-in.
  ///
  /// Nasce sempre em modo `em_massa`: o guiado depende do agente (ADK), que
  /// exige internet, então bifurcar não faz sentido offline.
  ///
  /// Usa `_db.batch()`, não `runTransaction` -- batch enfileira no cache
  /// local igual uma escrita comum; transação exige round-trip com o
  /// servidor, por isso `_createVistoriaId()` (usado no fluxo online) não
  /// serve aqui. O docId é um ID aleatório gerado localmente pelo próprio
  /// Firestore (`_vistorias.doc().id`, sem chamada de rede), prefixado com
  /// `temp-vist-` -- ver `reconcilePendingVistoriaId` pra trocar pelo
  /// número sequencial real quando a conexão voltar.
  ///
  /// Roda uma escrita (set/update/batch.commit) -- confirmado com o log
  /// verboso do próprio SDK (`FirebaseFirestore.setLoggingEnabled`) que a
  /// escrita é aplicada ao cache local em menos de 100ms (o dado já fica
  /// certo e visível pra qualquer leitura a partir daí), mas o `Future`
  /// só resolve depois de um round-trip bem-sucedido com o servidor -- e
  /// o SDK fica tentando de novo sozinho (backoff exponencial)
  /// indefinidamente enquanto não há rede. Esperar por isso offline só
  /// trava a UI à toa por um `Future` que não ia resolver tão cedo,
  /// não importa o timeout. Online, espera normalmente (com um timeout de
  /// segurança a mais, caso algo genuinamente trave).
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

  /// Lê um doc tentando o cache primeiro quando offline -- um `.get()`
  /// padrão (sem `Source.cache`) pode ficar pendurado indefinidamente sem
  /// conexão quando não há nada em cache ainda pra essa doc específica
  /// (bug real, achado testando `createVistoriaOffline`/`abandonVistoria`
  /// offline -- travava a tela em "Preparando sessão..." pra sempre).
  /// Online, comporta-se como um `.get()` normal, só com um timeout de
  /// segurança a mais.
  Future<DocumentSnapshot<Map<String, dynamic>>> _getCacheAware(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    final online = ArgosConnectivityService.instance.isOnline.value;

    if (!online) {
      return ref.get(const GetOptions(source: Source.cache));
    }

    return ref.get().timeout(const Duration(seconds: 8));
  }

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

    // `Timestamp.fromDate`, não `FieldValue.serverTimestamp()`, em
    // createdAt/updatedAt/agentLastTurnAt -- esse último fica `null` no
    // cache local até sincronizar, e `findOpenVistoria` ordena sessões por
    // `updatedAt` pra escolher a mais recente. Precisa de um valor de
    // verdade já, enquanto ainda offline.
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

  /// Troca o docId provisório (`temp-vist-...`, criado por
  /// `createVistoriaOffline`) pelo número sequencial real, assim que a
  /// conexão volta. Como todos os dados de uma vistoria são campos simples
  /// no próprio doc (sem subcoleção nenhuma -- `chatmessages`/`images`/
  /// `audios`/`orcamentoRascunho`/`envioEmMassaRascunho` são tudo campo), a
  /// "migração" é só copiar o doc inteiro pra um doc novo com o ID real e
  /// apagar o provisório, atomicamente com o ponteiro do sinistro.
  ///
  /// Só deve ser chamado já confirmadamente online (é aqui que
  /// `_createVistoriaId()` -- a transação real -- roda pela primeira vez
  /// nesse fluxo). Se o app morrer entre o `_createVistoriaId()` e o resto
  /// do batch, aquele número sequencial fica "queimado" (nunca associado a
  /// nenhuma vistoria) -- risco já aceito hoje no caminho online
  /// (`createOrResumeFromSinistro`/`createRetificacaoFromVistoria`), não é
  /// uma fragilidade nova.
  Future<String> reconcilePendingVistoriaId({
    required String tempDocId,
    required String sinistroId,
  }) async {
    if (!isPendingVistoriaId(tempDocId)) return tempDocId;

    final doc = await _vistorias.doc(tempDocId).get();

    if (!doc.exists) return tempDocId;

    final data = Map<String, dynamic>.from(doc.data() ?? {});

    // Não reconcilia enquanto o BulkSyncCoordinator ainda não terminou de
    // subir o pacote pra este docId provisório -- se a migração copiasse o
    // doc pro ID real e apagasse o antigo NO MEIO do upload, as escritas
    // seguintes do coordenador (que ainda apontam pro ID antigo) cairiam
    // num doc já apagado, perdendo dado. Só reconcilia depois que o
    // rascunho estiver vazio/sem pendência -- a próxima varredura de
    // conectividade tenta de novo.
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

  /// Busca uma vistoria específica pelo id do documento — usado pra
  /// recuperar a vistoria REJEITADA original quando o mecânico descarta uma
  /// retificação já em andamento e pede pra começar outra do zero (nesse
  /// caso sinistro.vistoriaAtualId já não aponta mais pra ela).
  Future<VistoriaSession?> getVistoriaById(String vistoriaDocId) async {
    final doc = await _vistorias.doc(vistoriaDocId).get();
    if (!doc.exists) return null;
    return VistoriaSession.fromFirestore(doc);
  }

  /// Busca a vistoria que o sinistro aponta como atual (sinistro.vistoriaAtualId)
  /// — usado pra pegar a vistoria REJEITADA como base de uma retificação, já
  /// que ela não está mais em EM_ANDAMENTO (findOpenVistoria não a acha).
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

  /// Ponto de entrada da retificação: acha a vistoria rejeitada do sinistro e
  /// cria a nova vistoria de correção a partir dela. Separado de
  /// createOrResumeFromSinistro de propósito — não deve ser possível cair
  /// aqui sem ter uma vistoria rejeitada de verdade por trás.
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

  Future<void> discardVistoria({
    required String vistoriaDocId,
    bool hardDelete = true,
  }) async {
    final ref = _vistorias.doc(vistoriaDocId);

    if (hardDelete) {
      // Sincroniza o sinistro (marcando a vistoria como cancelada) ANTES de
      // apagar o documento: _syncSinistroVistoriaStatus precisa ler o
      // próprio documento da vistoria para saber a qual sinistro ele
      // pertence, então isso tem que acontecer antes do delete.
      await _syncSinistroVistoriaStatus(
        vistoriaDocId: vistoriaDocId,
        status: statusCancelada,
      );

      // Firestore não apaga subcoleções ao deletar o documento pai — a
      // subcoleção "audios" (gravada pela Cloud Function de transcrição)
      // ficaria órfã se não for limpa explicitamente aqui.
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

  /// "Começar nova" (botão do mecânico, sem sinistro nenhum sendo anulado --
  /// isso é decisão do analista no web, não dele). Diferente de
  /// `discardVistoria(hardDelete: false)`, que grava CANCELADA -- um status
  /// que o resto do sistema trata como decisão do analista (encerramento
  /// definitivo). ABANDONADA é o mesmo status que o job de expiração já usa
  /// pra "essa tentativa parou, mas o mecânico pode simplesmente começar de
  /// novo pelo botão comum" (ver `isExpiredOrAbandonedCategory` no app).
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

  /// Persiste a escolha guiado/em_massa assim que o mecânico decide -- sem
  /// isso, sair do app antes de confirmar o envio em massa faz a vistoria
  /// esquecer o modo escolhido ao reabrir (ver ColetaModo em ai_chat_page).
  Future<void> setColetaModo({
    required String vistoriaDocId,
    required String coletaModo,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'coletaModo': coletaModo,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Item de orçamento digitado pelo próprio mecânico (fluxo de envio em
  /// massa) -- mesma lista que o ADK já preenche durante o fluxo guiado
  /// (`orcamentoRascunho`), só com `origem: 'mecanico'` em vez de
  /// `'vistoria'`. Não é um campo/modelo paralelo de propósito.
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

  /// Rascunho persistido do modo em massa -- gravado a cada item
  /// adicionado/removido no `BulkUploadSheet`, não só quando "Enviar" é
  /// tocado. É o que sobrevive o app fechar/morrer no meio da montagem do
  /// pacote (a persistência offline do Firestore já cobre isso sozinha,
  /// tanto pra sem-internet quanto pra "app matou o processo") ou no meio
  /// do envio em si (cada item sabe se já foi 'enviado', pra não duplicar
  /// ao retomar). Mapa por `localId` em vez de array pra dar pra
  /// atualizar/remover um item só sem reescrever a lista inteira.
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

  Future<void> removeEnvioEmMassaRascunhoItem({
    required String vistoriaDocId,
    required String localId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho.$localId': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> markEnvioEmMassaRascunhoItemEnviado({
    required String vistoriaDocId,
    required String localId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho.$localId.status': 'enviado',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Lê o estado mais recente do rascunho direto do servidor -- usado no
  /// início do envio pra saber, com certeza, o que já foi confirmado
  /// enviado numa tentativa anterior interrompida (o `VistoriaSession` em
  /// memória pode estar desatualizado se o rascunho mudou depois que a
  /// sessão foi carregada).
  Future<Map<String, dynamic>> fetchEnvioEmMassaRascunho(
    String vistoriaDocId,
  ) async {
    final doc = await _vistorias.doc(vistoriaDocId).get();
    final raw = doc.data()?['envioEmMassaRascunho'];

    if (raw is! Map) return {};

    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> clearEnvioEmMassaRascunho({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).update({
      'envioEmMassaRascunho': FieldValue.delete(),
      // Some junto -- a marca de "já confirmado, só esperando rede" não
      // tem mais sentido depois que o rascunho de verdade já foi
      // enviado/limpo.
      'envioEmMassaConfirmadoOffline': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Marca que o mecânico já tocou "Enviar" pra este pacote enquanto
  /// offline -- o pacote não é mais um rascunho em edição, é um envio
  /// confirmado esperando só a rede voltar. Persistido (não só em memória
  /// na tela) pra qualquer instância do `AiChatPage` que reabrir essa
  /// vistoria saber mostrar a tela travada de "aguardando sincronização"
  /// em vez do botão de montar o pacote de novo -- sem isso, sair e voltar
  /// antes de reconectar deixava reabrir/editar um pacote que já tinha
  /// sido confirmado.
  Future<void> markEnvioEmMassaConfirmadoOffline({
    required String vistoriaDocId,
  }) async {
    await _vistorias.doc(vistoriaDocId).set({
      'envioEmMassaConfirmadoOffline': true,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
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

    await _syncSinistroVistoriaStatus(
      vistoriaDocId: vistoriaDocId,
      status: statusFinalizada,
    );
  }

  Future<void> cleanupRootTranscriptionFields({
    int batchSize = 450,
  }) async {
    // Pagina por toda a coleção usando um cursor estável (id do documento);
    // sem isso, chamadas repetidas sempre reprocessavam o mesmo primeiro
    // lote e nunca alcançavam o restante da coleção.
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

  Future<_CurrentContext> _currentContext() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado.');
    }

    try {
      // Resolvido (e cacheado em memória para a sessão) pelo
      // SessionContextService — evita refazer estas leituras toda vez que
      // um método deste service precisa do contexto do usuário.
      final session = await SessionContextService.instance.resolve();

      return _CurrentContext(
        uid: session.uid,
        email: session.email,
        nome: session.nome,
        credenciadoId: session.credenciadoId,
        credenciadoNome: session.credenciadoNome,
      );
    } on NoCredenciadoLinkedException {
      // Diferente de InspectionsPage, este service historicamente não trata
      // "sem credenciado vinculado" como erro — quem chama (ex.:
      // listCheckedInSinistrosForCurrentUser) já sabe lidar com
      // credenciadoId vazio. Mantém esse comportamento.
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

  Future<String> _createVistoriaId() async {
    final year = DateTime.now().year;
    final counterRef = _db.collection('counters').doc('vistorias_$year');

    // Timeout de segurança -- uma transação exige round-trip com o
    // servidor e, diferente de `.get()`/`.set()`, não tem fallback local
    // nenhum. Se a conexão cair bem no meio (ex: `reconcilePendingVistoriaId`
    // começou com `isOnline==true` e a rede sumiu um instante depois), ela
    // fica esperando pra sempre -- e pode travar a fila de escrita do
    // Firestore pro resto do processo, impedindo até escritas SIMPLES em
    // outros documentos de completarem (bug real, achado testando).
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

  static bool _hasFilledAnalyticalReport(Map<String, dynamic> data) {
    const candidateFields = [
      'laudo_analitico',
      'laudoAnalitico',
    ];

    return candidateFields.any((field) => _hasAnyFilledValue(data[field]));
  }

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

  static DateTime _dateValue(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static DateTime? _dateValueOrNull(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }

  static DateTime _addBusinessHours(DateTime startDate, int hours) {
    if (hours <= 0) return startDate;

    var current = _normalizeBusinessStart(startDate);
    var remaining = hours;

    while (remaining > 0) {
      // Conta a hora que está prestes a decorrer (a que começa em `current`),
      // não a hora seguinte — checar a hora seguinte descartava a última
      // hora de sexta (23h-24h), porque o timestamp final cai bem na virada
      // pra sábado, mesmo essa hora inteira pertencendo à sexta.
      if (_isBusinessDay(current)) {
        remaining -= 1;
      }

      current = _normalizeBusinessStart(current.add(const Duration(hours: 1)));
    }

    return current;
  }

  static DateTime _normalizeBusinessStart(DateTime date) {
    var current = date;

    while (!_isBusinessDay(current)) {
      current = current.add(const Duration(days: 1));
    }

    return current;
  }

  static bool _isBusinessDay(DateTime date) {
    return date.weekday >= DateTime.monday && date.weekday <= DateTime.friday;
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

class VistoriaChatCompletionState {
  final String status;
  final bool isCompleted;

  const VistoriaChatCompletionState({
    required this.status,
    required this.isCompleted,
  });
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
  final String motivoRejeicao;
  final List<Map<String, dynamic>> chatMessages;
  final DateTime? agentLastTurnAt;
  final DateTime? agentBusinessExpiresAt;

  /// 'guiado' | 'em_massa' | '' (vistorias antigas, de antes desse campo
  /// existir -- tratadas como guiado por compatibilidade). Persistido assim
  /// que o mecânico escolhe, pra retomar corretamente se ele sair antes de
  /// confirmar o envio em massa.
  final String coletaModo;

  /// Rascunho persistido do modo em massa (ver
  /// `upsertEnvioEmMassaRascunhoItem`) -- snapshot de quando a sessão foi
  /// carregada; pra ter certeza absoluta no início do envio, usar
  /// `fetchEnvioEmMassaRascunho` direto.
  final Map<String, dynamic> envioEmMassaRascunho;

  /// true depois que o mecânico toca "Enviar" offline -- o pacote já foi
  /// confirmado, só falta a rede. Persistido (ver
  /// `markEnvioEmMassaConfirmadoOffline`) pra qualquer tela que reabrir
  /// esta vistoria saber mostrar o estado travado, não o botão de montar
  /// de novo.
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

  bool get isEmMassa => coletaModo == 'em_massa';

  bool get isRetificacao =>
      tipoVistoria.toUpperCase() == VistoriaChatSessionService.tipoRetificacao;

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

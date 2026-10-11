import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../features/ai_chat/bulk_upload_sheet.dart';
import 'argos_ai_service.dart';
import 'argos_connectivity_service.dart';
import 'user_audio_storage_service.dart';
import 'vistoria_chat_session_service.dart';

// Coordenador único (singleton) do upload e reconciliação de vistorias em
// massa pendentes, disparado tanto por toque manual quanto por reconexão.
class BulkSyncCoordinator {
  BulkSyncCoordinator._() {
    ArgosConnectivityService.instance.isOnline.addListener(
      _handleConnectivityChanged,
    );
  }

  static final BulkSyncCoordinator instance = BulkSyncCoordinator._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // IDs de vistoria sendo processadas agora, pra evitar duas chamadas
  // concorrentes processarem a mesma vistoria.
  final Set<String> _processingVistoriaIds = <String>{};

  // Espelho observável de _processingVistoriaIds, pras telas mostrarem
  // "Sincronizando..." enquanto o upload está rolando.
  final ValueNotifier<Set<String>> syncingVistoriaIds =
      ValueNotifier<Set<String>>(const <String>{});

  // Marca a vistoria como em processamento; retorna false se já estava.
  bool _tryMarkProcessing(String vistoriaDocId) {
    final added = _processingVistoriaIds.add(vistoriaDocId);

    if (added) {
      syncingVistoriaIds.value = Set<String>.from(_processingVistoriaIds);
    }

    return added;
  }

  // Remove a vistoria da lista de processamento.
  void _unmarkProcessing(String vistoriaDocId) {
    _processingVistoriaIds.remove(vistoriaDocId);
    syncingVistoriaIds.value = Set<String>.from(_processingVistoriaIds);
  }

  // Guarda de reentrância pra reconcilePendingVistoriaId, por docId.
  final Set<String> _reconcilingVistoriaIds = <String>{};

  final StreamController<String> _submittedController =
      StreamController<String>.broadcast();

  // Emite o docId sempre que um pacote em massa termina de ser enviado.
  Stream<String> get onPackageSubmitted => _submittedController.stream;

  // Dispara a varredura de envio/reconciliação pendente ao reconectar.
  void _handleConnectivityChanged() {
    if (!ArgosConnectivityService.instance.isOnline.value) return;
    unawaited(_syncAndReconcileAllPending());
  }

  // Busca minhas vistorias em massa em aberto e, pra cada uma, envia o
  // rascunho pendente e só então reconcilia o ID provisório.
  Future<void> _syncAndReconcileAllPending() async {
    final uid = _auth.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    try {
      final snapshot = await _fetchMyOpenBulkVistorias(uid);

      for (final doc in snapshot.docs) {
        final submission = _trySubmitIfPending(doc);

        if (submission == null) {
          _tryReconcileIfPending(doc);
          continue;
        }

        unawaited(
          submission.catchError((e) {
            debugPrint('Erro ao sincronizar envio em massa pendente: $e');
          }).whenComplete(() => _tryReconcileIfPending(doc)),
        );
      }
    } catch (e) {
      debugPrint('Erro ao varrer vistorias em massa pendentes: $e');
    }
  }

  // Busca as vistorias em massa em aberto do mecânico logado.
  Future<QuerySnapshot<Map<String, dynamic>>> _fetchMyOpenBulkVistorias(
    String uid,
  ) {
    return _db
        .collection('vistorias')
        .where('inspectorId', isEqualTo: uid)
        .where('status', isEqualTo: VistoriaChatSessionService.statusEmAndamento)
        .where('coletaModo', isEqualTo: 'em_massa')
        .get();
  }

  // Reconcilia o ID provisório do doc, se aplicável, evitando chamadas concorrentes.
  void _tryReconcileIfPending(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final tempId = doc.id;

    if (!VistoriaChatSessionService.instance.isPendingVistoriaId(tempId)) {
      return;
    }

    if (!_reconcilingVistoriaIds.add(tempId)) return;

    final sinistroId = (doc.data()['sinistroId'] ?? '').toString();

    unawaited(
      VistoriaChatSessionService.instance
          .reconcilePendingVistoriaId(
            tempDocId: tempId,
            sinistroId: sinistroId,
          )
          .catchError((e) {
        debugPrint('Erro ao reconciliar vistoria offline $tempId: $e');
        return tempId;
      }).whenComplete(() => _reconcilingVistoriaIds.remove(tempId)),
    );
  }

  // Retorna o Future do upload se houver rascunho pendente pra subir, senão null.
  Future<void>? _trySubmitIfPending(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final rascunho = _asStringKeyedMap(data['envioEmMassaRascunho']);

    final hasPending = rascunho.values.any(
      (item) => item is Map && item['status'] != 'enviado',
    );

    if (!hasPending) return null;

    final result = buildBulkUploadResultFromRascunho(rascunho);

    final hasAnything = result.photos.isNotEmpty ||
        result.audios.isNotEmpty ||
        result.text.trim().isNotEmpty ||
        result.orcamentoItems.isNotEmpty;

    if (!hasAnything) return null;

    return submitPackage(
      vistoriaDocId: doc.id,
      sinistroId: (data['sinistroId'] ?? '').toString(),
      idvistoria: (data['idvistoria'] ?? doc.id).toString(),
      result: result,
    );
  }

  // Varre e reconcilia o ID provisório de todas as minhas vistorias em massa em aberto.
  Future<void> reconcileAllPendingIds() async {
    final uid = _auth.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    try {
      final snapshot = await _fetchMyOpenBulkVistorias(uid);

      for (final doc in snapshot.docs) {
        _tryReconcileIfPending(doc);
      }
    } catch (e) {
      debugPrint('Erro ao varrer vistorias offline pendentes de id real: $e');
    }
  }

  // Varre e reenvia o rascunho pendente de todas as minhas vistorias em massa em aberto.
  Future<void> syncAllPending() async {
    final uid = _auth.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    try {
      final snapshot = await _fetchMyOpenBulkVistorias(uid);

      for (final doc in snapshot.docs) {
        final submission = _trySubmitIfPending(doc);
        if (submission != null) unawaited(submission);
      }
    } catch (e) {
      debugPrint('Erro ao varrer envios em massa pendentes: $e');
    }
  }

  // Normaliza um valor dinâmico pra Map<String, dynamic>.
  static Map<String, dynamic> _asStringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return <String, dynamic>{};
  }

  // Sobe fotos, áudios, texto e orçamento do pacote e finaliza a vistoria
  // pra análise operacional; `onStatus` reporta o progresso de cada etapa.
  Future<void> submitPackage({
    required String vistoriaDocId,
    required String sinistroId,
    required String idvistoria,
    required BulkUploadResult result,
    void Function(String status)? onStatus,
  }) async {
    if (!_tryMarkProcessing(vistoriaDocId)) return;

    try {
      onStatus?.call('Enviando fotos...');

      for (final photo in result.photos) {
        try {
          final uploadedImage =
              await VistoriaChatSessionService.instance.uploadImageFile(
            vistoriaDocId: vistoriaDocId,
            imagePath: photo.path,
          );

          await VistoriaChatSessionService.instance.appendImageEvidence(
            vistoriaDocId: vistoriaDocId,
            imageUrl: uploadedImage.downloadUrl,
            imagePath: photo.path,
            imageId: uploadedImage.imageId,
            storagePath: uploadedImage.storagePath,
            fileName: uploadedImage.fileName,
            contentType: uploadedImage.contentType,
            sizeBytes: uploadedImage.sizeBytes,
          );

          await VistoriaChatSessionService.instance.appendChatMessage(
            vistoriaDocId: vistoriaDocId,
            role: 'photo',
            text: 'Foto anexada à vistoria (tudo de uma vez)',
            extraData: {
              'imageId': uploadedImage.imageId,
              'url': uploadedImage.downloadUrl,
              'storagePath': uploadedImage.storagePath,
              'fileName': uploadedImage.fileName,
            },
          );

          await VistoriaChatSessionService.instance
              .markEnvioEmMassaRascunhoItemEnviado(
            vistoriaDocId: vistoriaDocId,
            localId: photo.localId,
          );
        } catch (e) {
          debugPrint('Erro ao subir foto do envio em massa: $e');
        }
      }

      if (result.audios.isNotEmpty) {
        onStatus?.call('Ouvindo os áudios...');

        for (final audio in result.audios) {
          try {
            final uploadedAudio = await UserAudioStorageService.instance
                .uploadOriginalAudioForMp3Conversion(
              localAudioPath: audio.path,
              idvistoria: idvistoria,
              sinistroId: sinistroId,
              duration: Duration(seconds: audio.durationSeconds),
            );

            await ArgosAiService.instance.sendAudioMessage(
              idvistoria: idvistoria,
              sinistroId: sinistroId,
              audioId: uploadedAudio.audioId,
              storagePath: uploadedAudio.mp3StoragePath,
              durationSeconds: audio.durationSeconds,
            );

            await VistoriaChatSessionService.instance
                .markEnvioEmMassaRascunhoItemEnviado(
              vistoriaDocId: vistoriaDocId,
              localId: audio.localId,
            );
          } catch (e) {
            debugPrint('Erro ao subir/transcrever áudio do envio em massa: $e');
          }
        }
      }

      if (result.text.trim().isNotEmpty) {
        onStatus?.call('Registrando observações...');

        await VistoriaChatSessionService.instance.appendChatMessage(
          vistoriaDocId: vistoriaDocId,
          role: 'user',
          text: result.text.trim(),
        );

        await VistoriaChatSessionService.instance
            .markEnvioEmMassaRascunhoItemEnviado(
          vistoriaDocId: vistoriaDocId,
          localId: kBulkTextRascunhoKey,
        );
      }

      if (result.orcamentoItems.isNotEmpty) {
        onStatus?.call('Calculando o orçamento...');

        for (final item in result.orcamentoItems) {
          await VistoriaChatSessionService.instance.appendOrcamentoMecanicoItem(
            vistoriaDocId: vistoriaDocId,
            peca: item.peca,
            tipoIntervencao: item.tipoIntervencao,
            valorPeca: item.valorPeca,
            horasMaoObra: item.horasMaoObra,
          );

          await VistoriaChatSessionService.instance
              .markEnvioEmMassaRascunhoItemEnviado(
            vistoriaDocId: vistoriaDocId,
            localId: item.localId,
          );
        }
      }

      onStatus?.call('Finalizando...');

      await VistoriaChatSessionService.instance.clearEnvioEmMassaRascunho(
        vistoriaDocId: vistoriaDocId,
      );

      await VistoriaChatSessionService.instance.submitForOperationalAnalysis(
        vistoriaDocId: vistoriaDocId,
      );

      _submittedController.add(vistoriaDocId);
    } finally {
      _unmarkProcessing(vistoriaDocId);
    }
  }
}

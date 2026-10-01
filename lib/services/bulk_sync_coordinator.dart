import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../features/ai_chat/bulk_upload_sheet.dart';
import 'argos_ai_service.dart';
import 'argos_connectivity_service.dart';
import 'user_audio_storage_service.dart';
import 'vistoria_chat_session_service.dart';

/// Dono único do upload de verdade de um pacote em massa (Storage + ADK pra
/// transcrição de áudio) -- extraído de `_AiChatPageState._submitBulkPackage`
/// pra ter UM lugar só que sabe fazer isso, chamado tanto pelo toque manual
/// em "Enviar" (tela aberta, online) quanto pela varredura automática ao
/// reconectar (`syncAllPending`, que roda sozinha, sem nenhuma tela aberta).
///
/// Isso resolve uma limitação real: antes, a retomada automática
/// (`_handleConnectivityRestored` dentro do `AiChatPage`) só funcionava
/// enquanto a MESMA instância daquela vistoria continuasse montada -- sair e
/// voltar a entrar criava um widget novo (via `ValueKey`) e perdia o
/// listener. Como `ArgosConnectivityService` já é um singleton que sobrevive
/// a troca de tela, um coordenador no mesmo molde cobre TODAS as vistorias
/// pendentes do mecânico, não só a que porventura estiver na tela.
class BulkSyncCoordinator {
  BulkSyncCoordinator._() {
    ArgosConnectivityService.instance.isOnline.addListener(
      _handleConnectivityChanged,
    );
  }

  static final BulkSyncCoordinator instance = BulkSyncCoordinator._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Reentrância-safe: se os dois caminhos (toque manual e varredura
  /// automática) tentarem processar a mesma vistoria quase juntos, só o
  /// primeiro vence -- o segundo encontra o id já aqui e não faz nada.
  final Set<String> _processingVistoriaIds = <String>{};

  final StreamController<String> _submittedController =
      StreamController<String>.broadcast();

  /// Emite o docId toda vez que um pacote termina de ser enviado com
  /// sucesso -- não importa se foi um toque manual ou a varredura
  /// automática. `AiChatPage` escuta isso pra virar a própria tela de
  /// "concluído" quando a vistoria que ela mostra é a que acabou de
  /// sincronizar sozinha em segundo plano. Necessário porque
  /// `watchCompletionState` não serve pro modo em massa -- ele exige
  /// `laudo_analitico` preenchido, campo que só o agente guiado preenche
  /// numa conversa de verdade.
  Stream<String> get onPackageSubmitted => _submittedController.stream;

  void _handleConnectivityChanged() {
    if (!ArgosConnectivityService.instance.isOnline.value) return;
    unawaited(syncAllPending());
  }

  /// Varre TODAS as vistorias em massa em aberto do mecânico logado atrás
  /// de rascunho ainda não enviado -- não depende de nenhuma tela estar
  /// montada. Disparado sozinho ao reconectar; seguro de chamar de novo
  /// manualmente (ex: ao abrir a lista de vistorias).
  Future<void> syncAllPending() async {
    final uid = _auth.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    if (!ArgosConnectivityService.instance.isOnline.value) return;

    try {
      final snapshot = await _db
          .collection('vistorias')
          .where('inspectorId', isEqualTo: uid)
          .where('status', isEqualTo: VistoriaChatSessionService.statusEmAndamento)
          .where('coletaModo', isEqualTo: 'em_massa')
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final rascunho = _asStringKeyedMap(data['envioEmMassaRascunho']);

        final hasPending = rascunho.values.any(
          (item) => item is Map && item['status'] != 'enviado',
        );

        if (!hasPending) continue;

        final result = buildBulkUploadResultFromRascunho(rascunho);

        final hasAnything = result.photos.isNotEmpty ||
            result.audios.isNotEmpty ||
            result.text.trim().isNotEmpty ||
            result.orcamentoItems.isNotEmpty;

        if (!hasAnything) continue;

        unawaited(
          submitPackage(
            vistoriaDocId: doc.id,
            sinistroId: (data['sinistroId'] ?? '').toString(),
            idvistoria: (data['idvistoria'] ?? doc.id).toString(),
            result: result,
          ),
        );
      }
    } catch (e) {
      // Melhor esforço -- se a varredura falhar (ex: rede caiu nesse
      // meio-tempo de novo), a próxima reconexão tenta de novo sozinha.
      debugPrint('Erro ao varrer envios em massa pendentes: $e');
    }
  }

  static Map<String, dynamic> _asStringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return <String, dynamic>{};
  }

  /// Faz o upload de verdade (fotos, áudios, texto, orçamento) e finaliza a
  /// vistoria (`submitForOperationalAnalysis`). `onStatus`, se passado, é
  /// chamado a cada etapa -- usado pela tela pra alimentar a animação do
  /// olho quando quem chamou é o toque manual (a varredura automática em
  /// segundo plano não passa `onStatus`, não tem UI nenhuma olhando).
  Future<void> submitPackage({
    required String vistoriaDocId,
    required String sinistroId,
    required String idvistoria,
    required BulkUploadResult result,
    void Function(String status)? onStatus,
  }) async {
    if (!_processingVistoriaIds.add(vistoriaDocId)) return;

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
            text: 'Foto anexada à vistoria (envio em massa)',
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

            // Transcreve de verdade (o backend grava em chatmessages) --
            // descartamos a resposta conversacional do agente de propósito:
            // o modo em massa não mostra ida-e-volta com o ADK.
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
      _processingVistoriaIds.remove(vistoriaDocId);
    }
  }
}

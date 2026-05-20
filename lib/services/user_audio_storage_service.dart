import 'dart:io';

import 'package:audio_converter_native/audio_converter_native.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Serviço para gravar o áudio do chat já convertido em MP3 no Firebase Storage.
///
/// Nova estrutura final no Storage:
/// vistorias/{idvistoria}/audio/{audioId}.mp3
///
/// Exemplo:
/// vistorias/VIS-2026-0001/audio/VIS_2026_0001_AUD_01.mp3
///
/// Observação:
/// Este service NÃO grava mais áudio em base64 no Firestore.
/// A subcoleção vistorias/{idvistoria}/audios/{audioId} continua sendo gravada
/// pela Cloud Function sendArgosAudioMessage, com storagePath, gcsUri,
/// transcricaoOriginal, transcricaoRevisada e agentReply.
class UserAudioStorageService {
  UserAudioStorageService._();

  static final UserAudioStorageService instance = UserAudioStorageService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Mantive o nome do método para reduzir impacto no ai_chat_page.dart.
  ///
  /// Agora ele:
  /// 1. Recebe o áudio local gravado em .m4a.
  /// 2. Gera um ID sequencial por vistoria:
  ///    VIS_2026_0001_AUD_01, VIS_2026_0001_AUD_02...
  /// 3. Converte no dispositivo para .mp3 usando audio_converter_native.
  /// 4. Salva somente o MP3 no Storage em:
  ///    vistorias/{idvistoria}/audio/{audioId}.mp3
  /// 5. Retorna o storagePath para a Cloud Function salvar na subcoleção:
  ///    vistorias/{idvistoria}/audios/{audioId}
  Future<UploadedUserAudio> uploadOriginalAudioForMp3Conversion({
    required String localAudioPath,
    required String idvistoria,
    String? sinistroId,
    String? chatMessageId,
    Duration? duration,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: 'not-authenticated',
        message: 'Usuário precisa estar logado para enviar áudio.',
      );
    }

    final cleanVistoriaId = idvistoria.trim();

    if (cleanVistoriaId.isEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'missing-idvistoria',
        message: 'idvistoria é obrigatório para salvar áudio da vistoria.',
      );
    }

    final email = _normalizeEmail(user.email);

    final originalFile = File(localAudioPath);

    if (!await originalFile.exists()) {
      throw FileSystemException(
        'Arquivo de áudio original não encontrado.',
        localAudioPath,
      );
    }

    final audioId = await _createSequentialAudioId(cleanVistoriaId);
    final mp3StoragePath = 'vistorias/$cleanVistoriaId/audio/$audioId.mp3';

    try {
      final converterAvailable =
          await AudioConverterService.instance.isAvailable();

      if (!converterAvailable) {
        throw Exception('Conversor nativo indisponível neste dispositivo.');
      }

      final dynamic conversionResult =
          await AudioConverterService.instance.convertToMP3(
        inputPath: localAudioPath,
        bitrate: 128,
        sampleRate: 44100,
      );

      final bool success = conversionResult.success == true;
      final String outputPath = conversionResult.outputPath?.toString() ?? '';
      final String error = conversionResult.error?.toString() ?? '';

      if (!success || outputPath.isEmpty) {
        throw Exception(
          error.isEmpty ? 'Falha ao converter áudio para MP3.' : error,
        );
      }

      final mp3File = File(outputPath);

      if (!await mp3File.exists()) {
        throw FileSystemException(
          'Arquivo MP3 convertido não encontrado.',
          outputPath,
        );
      }

      final mp3Ref = _storage.ref(mp3StoragePath);

      await mp3Ref.putFile(
        mp3File,
        SettableMetadata(
          contentType: 'audio/mpeg',
          customMetadata: {
            'uid': user.uid,
            'email': email,
            'audioId': audioId,
            'idvistoria': cleanVistoriaId,
            'conversionEngine': 'audio_converter_native',
            if (sinistroId != null && sinistroId.trim().isNotEmpty)
              'sinistroId': sinistroId.trim(),
            if (chatMessageId != null && chatMessageId.trim().isNotEmpty)
              'chatMessageId': chatMessageId.trim(),
            if (duration != null) 'durationSeconds': '${duration.inSeconds}',
          },
        ),
      );

      final mp3DownloadUrl = await mp3Ref.getDownloadURL();

      return UploadedUserAudio(
        uid: user.uid,
        email: email,
        audioId: audioId,
        idvistoria: cleanVistoriaId,
        mp3StoragePath: mp3StoragePath,
        mp3DownloadUrl: mp3DownloadUrl,

        // Campos mantidos por compatibilidade com o ai_chat_page.dart atual.
        // Agora apontam para o próprio MP3, porque não subimos mais o .m4a.
        originalStoragePath: mp3StoragePath,
        originalDownloadUrl: mp3DownloadUrl,
      );
    } catch (_) {
      // Se falhar após reservar o número, não decrementamos o contador.
      // Isso evita colisão de nome. Pode ficar um "buraco" na sequência,
      // mas nunca teremos dois AUD_01 para a mesma vistoria.
      rethrow;
    }
  }

  /// Gera o próximo ID de áudio dentro da vistoria usando transaction.
  ///
  /// Salva/atualiza no documento vistorias/{idvistoria}:
  /// lastAudioNumber: 1, 2, 3...
  ///
  /// Retorna:
  /// VIS_2026_0001_AUD_01
  Future<String> _createSequentialAudioId(String idvistoria) async {
    final vistoriaRef = _firestore.collection('vistorias').doc(idvistoria);

    final nextNumber = await _firestore.runTransaction<int>((transaction) async {
      final snapshot = await transaction.get(vistoriaRef);

      if (!snapshot.exists) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'vistoria-not-found',
          message: 'Vistoria não encontrada: $idvistoria',
        );
      }

      final data = snapshot.data() ?? {};
      final current = data['lastAudioNumber'] is int
          ? data['lastAudioNumber'] as int
          : 0;

      final next = current + 1;

      transaction.set(
        vistoriaRef,
        {
          'lastAudioNumber': next,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      return next;
    });

    final safeVistoriaId = _safeStorageName(idvistoria);
    final number = nextNumber.toString().padLeft(2, '0');

    return '${safeVistoriaId}_AUD_$number';
  }

  String _safeStorageName(String value) {
    return value
        .trim()
        .replaceAll('-', '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  String _normalizeEmail(String? email) {
    return (email ?? '').trim().toLowerCase();
  }
}

class UploadedUserAudio {
  final String uid;
  final String email;
  final String audioId;
  final String idvistoria;

  /// Caminho final do MP3 no Storage:
  /// vistorias/{idvistoria}/audio/{audioId}.mp3
  final String mp3StoragePath;
  final String mp3DownloadUrl;

  /// Campos mantidos por compatibilidade com o chat atual.
  /// Como agora salvamos somente MP3, eles apontam para o mesmo arquivo MP3.
  final String originalStoragePath;
  final String originalDownloadUrl;

  const UploadedUserAudio({
    required this.uid,
    required this.email,
    required this.audioId,
    required this.idvistoria,
    required this.mp3StoragePath,
    required this.mp3DownloadUrl,
    required this.originalStoragePath,
    required this.originalDownloadUrl,
  });
}

import 'dart:io';

import 'package:audio_converter_native/audio_converter_native.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Converte o áudio gravado no chat para MP3 e sobe pro Firebase Storage em
/// `vistorias/{idvistoria}/audio/{audioId}.mp3`.
class UserAudioStorageService {
  UserAudioStorageService._();

  static final UserAudioStorageService instance = UserAudioStorageService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Recebe o áudio local (.m4a), gera um ID sequencial por vistoria,
  /// converte para MP3 no dispositivo e sobe o resultado pro Storage.
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
        originalStoragePath: mp3StoragePath,
        originalDownloadUrl: mp3DownloadUrl,
      );
    } catch (_) {
      rethrow;
    }
  }

  /// Gera o próximo ID sequencial de áudio da vistoria via transaction
  /// (ex.: `VIS_2026_0001_AUD_01`), incrementando `lastAudioNumber`.
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

  /// Sanitiza um id de vistoria para uso em path/nome de arquivo no Storage.
  String _safeStorageName(String value) {
    return value
        .trim()
        .replaceAll('-', '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  /// Normaliza o e-mail (minúsculo, sem espaços) pra gravar no Storage.
  String _normalizeEmail(String? email) {
    return (email ?? '').trim().toLowerCase();
  }
}

/// Resultado do upload de um áudio do chat já convertido para MP3.
class UploadedUserAudio {
  final String uid;
  final String email;
  final String audioId;
  final String idvistoria;

  final String mp3StoragePath;
  final String mp3DownloadUrl;
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

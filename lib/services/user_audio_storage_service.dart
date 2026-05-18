import 'dart:io';

import 'package:audio_converter_native/audio_converter_native.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Serviço para gravar o áudio do chat já convertido em MP3 no Firebase Storage.
///
/// Estrutura final no Storage:
/// users/{email_da_pessoa_logada}/audios/{audioId}.mp3
///
/// Exemplo:
/// users/matheus.opuscolo@gmail.com/audios/audio_1715200000000.mp3
///
/// Também grava metadados em:
/// users/{email_da_pessoa_logada}/audios/{audioId}
class UserAudioStorageService {
  UserAudioStorageService._();

  static final UserAudioStorageService instance = UserAudioStorageService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Mantive o nome do método para não precisar alterar o ai_chat_page.dart.
  ///
  /// Agora ele:
  /// 1. Recebe o áudio local gravado em .m4a.
  /// 2. Converte no dispositivo para .mp3 usando audio_converter_native.
  /// 3. Salva somente o MP3 no Storage em:
  ///    users/{email}/audios/{audioId}.mp3
  /// 4. Cria/atualiza metadados no Firestore em:
  ///    users/{email}/audios/{audioId}
  Future<UploadedUserAudio> uploadOriginalAudioForMp3Conversion({
    required String localAudioPath,
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

    final email = _normalizeEmail(user.email);

    if (email.isEmpty) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: 'missing-email',
        message: 'Não foi possível identificar o e-mail do usuário logado.',
      );
    }

    final originalFile = File(localAudioPath);

    if (!await originalFile.exists()) {
      throw FileSystemException(
        'Arquivo de áudio original não encontrado.',
        localAudioPath,
      );
    }

    final audioId = _buildAudioId();
    final mp3StoragePath = 'users/$email/audios/$audioId.mp3';

    final audioDocRef = _firestore
        .collection('users')
        .doc(email)
        .collection('audios')
        .doc(audioId);

    await audioDocRef.set({
      'uid': user.uid,
      'email': email,
      'audioId': audioId,
      'sinistroId': sinistroId ?? '',
      'chatMessageId': chatMessageId ?? '',
      'localAudioPath': localAudioPath,
      'mp3StoragePath': mp3StoragePath,
      'mp3DownloadUrl': '',
      'mp3ContentType': 'audio/mpeg',
      'mp3Status': 'converting_on_device',
      'conversionEngine': 'audio_converter_native',
      'durationSeconds': duration == null ? null : duration.inSeconds,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final converterAvailable = await AudioConverterService.instance
          .isAvailable();

      if (!converterAvailable) {
        throw Exception('Conversor nativo indisponível neste dispositivo.');
      }

      final dynamic conversionResult = await AudioConverterService.instance
          .convertToMP3(
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

      await audioDocRef.set({
        'mp3Status': 'uploading',
        'convertedLocalPath': outputPath,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final mp3Ref = _storage.ref(mp3StoragePath);

      await mp3Ref.putFile(
        mp3File,
        SettableMetadata(
          contentType: 'audio/mpeg',
          customMetadata: {
            'uid': user.uid,
            'email': email,
            'audioId': audioId,
            'conversionEngine': 'audio_converter_native',
            if (sinistroId != null && sinistroId.trim().isNotEmpty)
              'sinistroId': sinistroId,
            if (chatMessageId != null && chatMessageId.trim().isNotEmpty)
              'chatMessageId': chatMessageId,
          },
        ),
      );

      final mp3DownloadUrl = await mp3Ref.getDownloadURL();

      await audioDocRef.set({
        'mp3DownloadUrl': mp3DownloadUrl,
        'mp3Status': 'done',
        'convertedAt': FieldValue.serverTimestamp(),
        'uploadedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return UploadedUserAudio(
        uid: user.uid,
        email: email,
        audioId: audioId,
        mp3StoragePath: mp3StoragePath,
        mp3DownloadUrl: mp3DownloadUrl,
        audioDocPath: audioDocRef.path,

        // Campos mantidos por compatibilidade com o ai_chat_page.dart atual.
        // Agora apontam para o próprio MP3, porque não subimos mais o .m4a.
        originalStoragePath: mp3StoragePath,
        originalDownloadUrl: mp3DownloadUrl,
      );
    } catch (error) {
      await audioDocRef.set({
        'mp3Status': 'error',
        'errorMessage': error.toString(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      rethrow;
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchAudioConversion({
    required String audioId,
  }) {
    final user = _auth.currentUser;
    final email = _normalizeEmail(user?.email);

    if (user == null || email.isEmpty) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: 'not-authenticated',
        message: 'Usuário precisa estar logado para acompanhar áudio.',
      );
    }

    return _firestore
        .collection('users')
        .doc(email)
        .collection('audios')
        .doc(audioId)
        .snapshots();
  }

  Future<String?> getMp3DownloadUrl({required String audioId}) async {
    final user = _auth.currentUser;
    final email = _normalizeEmail(user?.email);

    if (user == null || email.isEmpty) {
      throw FirebaseException(
        plugin: 'firebase_auth',
        code: 'not-authenticated',
        message: 'Usuário precisa estar logado para buscar áudio.',
      );
    }

    final doc = await _firestore
        .collection('users')
        .doc(email)
        .collection('audios')
        .doc(audioId)
        .get();

    final data = doc.data();

    if (data == null) return null;

    final status = data['mp3Status']?.toString() ?? '';
    final savedUrl = data['mp3DownloadUrl']?.toString() ?? '';
    final mp3StoragePath = data['mp3StoragePath']?.toString() ?? '';

    if (status != 'done') return null;

    if (savedUrl.isNotEmpty) {
      return savedUrl;
    }

    if (mp3StoragePath.isEmpty) {
      return null;
    }

    return _storage.ref(mp3StoragePath).getDownloadURL();
  }

  String _buildAudioId() {
    return 'audio_${DateTime.now().millisecondsSinceEpoch}';
  }

  String _normalizeEmail(String? email) {
    return (email ?? '').trim().toLowerCase();
  }
}

class UploadedUserAudio {
  final String uid;
  final String email;
  final String audioId;

  /// Caminho final do MP3 no Storage:
  /// users/{email}/audios/{audioId}.mp3
  final String mp3StoragePath;
  final String mp3DownloadUrl;

  /// Caminho do documento no Firestore:
  /// users/{email}/audios/{audioId}
  final String audioDocPath;

  /// Campos mantidos por compatibilidade com o chat atual.
  /// Como agora salvamos somente MP3, eles apontam para o mesmo arquivo MP3.
  final String originalStoragePath;
  final String originalDownloadUrl;

  const UploadedUserAudio({
    required this.uid,
    required this.email,
    required this.audioId,
    required this.mp3StoragePath,
    required this.mp3DownloadUrl,
    required this.audioDocPath,
    required this.originalStoragePath,
    required this.originalDownloadUrl,
  });
}

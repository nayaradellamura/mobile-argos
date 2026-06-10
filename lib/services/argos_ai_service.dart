import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';

class ArgosAiService {
  ArgosAiService._();

  static final ArgosAiService instance = ArgosAiService._();

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  Future<String> sendMessage({
    required String text,
    required String inspectionId,
  }) async {
    final cleanText = text.trim();

    if (cleanText.isEmpty) {
      return 'Digite uma mensagem para eu conseguir ajudar na vistoria.';
    }

    final callable = _functions.httpsCallable('sendArgosMessage');

    final result = await callable.call<Map<String, dynamic>>({
      'text': cleanText,
      'inspectionId': inspectionId,
    });

    final data = result.data;

    return data['reply']?.toString() ??
        'Entendi. Pode continuar descrevendo a vistoria.';
  }

  Future<void> sendBackgroundMessage({
    required String text,
    required String inspectionId,
  }) async {
    final cleanText = text.trim();

    if (cleanText.isEmpty) return;

    final callable = _functions.httpsCallable('sendmessageargos');

    await callable.call<Map<String, dynamic>>({
      'text': cleanText,
      'inspectionId': inspectionId,
    });
  }

  Future<ArgosAudioMessageResult> sendAudioMessage({
    required String idvistoria,
    required String sinistroId,
    required String audioId,
    required String storagePath,
    int? durationSeconds,
  }) async {
    final cleanIdVistoria = idvistoria.trim();
    final cleanStoragePath = storagePath.trim();

    if (cleanIdVistoria.isEmpty) {
      throw ArgumentError('idvistoria não pode ser vazio.');
    }

    if (cleanStoragePath.isEmpty) {
      throw ArgumentError('storagePath não pode ser vazio.');
    }

    final bucket = Firebase.app().options.storageBucket ?? '';

    final callable = _functions.httpsCallable(
      'sendArgosAudioMessage',
      options: HttpsCallableOptions(
        timeout: const Duration(seconds: 120),
      ),
    );

    final result = await callable.call<Map<String, dynamic>>({
      'idvistoria': cleanIdVistoria,
      'inspectionId': cleanIdVistoria,
      'sinistroId': sinistroId.trim(),
      'audioId': audioId.trim(),
      'storagePath': cleanStoragePath,
      'bucket': bucket,
      'durationSeconds': durationSeconds,
    });

    return ArgosAudioMessageResult.fromMap(result.data);
  }
}

class ArgosAudioMessageResult {
  final String audioId;
  final String idvistoria;
  final String originalTranscript;
  final String revisedTranscript;
  final String reply;

  const ArgosAudioMessageResult({
    required this.audioId,
    required this.idvistoria,
    required this.originalTranscript,
    required this.revisedTranscript,
    required this.reply,
  });

  factory ArgosAudioMessageResult.fromMap(Map<String, dynamic> data) {
    return ArgosAudioMessageResult(
      audioId: data['audioId']?.toString() ?? '',
      idvistoria: data['idvistoria']?.toString() ??
          data['inspectionId']?.toString() ??
          '',
      originalTranscript: data['originalTranscript']?.toString() ??
          data['transcricaoOriginal']?.toString() ??
          '',
      revisedTranscript: data['revisedTranscript']?.toString() ??
          data['transcricaoRevisada']?.toString() ??
          data['transcript']?.toString() ??
          '',
      reply: data['reply']?.toString() ??
          'Entendi. Pode continuar descrevendo a vistoria.',
    );
  }
}

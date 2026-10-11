import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';

/// Chama as Cloud Functions do agente de IA (ADK) que conduz o chat de
/// vistoria: mensagens de texto/áudio e checagem de expiração.
class ArgosAiService {
  ArgosAiService._();

  static final ArgosAiService instance = ArgosAiService._();

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  static const Duration _agentTimeout = Duration(seconds: 540);

  /// Envia uma mensagem de texto do mecânico e retorna a resposta do agente.
  Future<String> sendMessage({
    required String text,
    required String inspectionId,
    bool isRetificacao = false,
    String? ajustesNecessarios,
    String? contextoVistoriaAnterior,
  }) async {
    final cleanText = text.trim();

    if (cleanText.isEmpty) {
      return 'Digite uma mensagem para eu conseguir ajudar na vistoria.';
    }

    final callable = _functions.httpsCallable(
      'sendArgosMessage',
      options: HttpsCallableOptions(timeout: _agentTimeout),
    );

    final result = await callable.call<Map<String, dynamic>>({
      'text': cleanText,
      'inspectionId': inspectionId,
      if (isRetificacao) ...{
        'modo': 'retificacao',
        'ajustesNecessarios': ajustesNecessarios ?? '',
        'contextoVistoriaAnterior': contextoVistoriaAnterior ?? '',
      },
    });

    final data = result.data;

    return data['reply']?.toString() ??
        'Entendi. Pode continuar descrevendo a vistoria.';
  }

  /// Manda uma mensagem de sistema (ex.: aviso de que as fotos subiram) e
  /// retorna a resposta do agente.
  Future<String> sendBackgroundMessage({
    required String text,
    required String inspectionId,
    bool isRetificacao = false,
    String? ajustesNecessarios,
    String? contextoVistoriaAnterior,
  }) async {
    final cleanText = text.trim();

    if (cleanText.isEmpty) return '';

    final callable = _functions.httpsCallable(
      'sendmessageargos',
      options: HttpsCallableOptions(timeout: _agentTimeout),
    );

    final result = await callable.call<Map<String, dynamic>>({
      'text': cleanText,
      'inspectionId': inspectionId,
      if (isRetificacao) ...{
        'modo': 'retificacao',
        'ajustesNecessarios': ajustesNecessarios ?? '',
        'contextoVistoriaAnterior': contextoVistoriaAnterior ?? '',
      },
    });

    return result.data['reply']?.toString() ?? '';
  }

  /// Envia um áudio já transcrito/subido e retorna a transcrição + resposta
  /// do agente.
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
      options: HttpsCallableOptions(timeout: _agentTimeout),
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

  /// Checa (e expira, se for o caso) uma vistoria específica na hora.
  Future<bool> checkVistoriaExpiration({required String idvistoria}) async {
    final cleanId = idvistoria.trim();

    if (cleanId.isEmpty) return false;

    final callable = _functions.httpsCallable('checkVistoriaExpiration');

    final result = await callable.call<Map<String, dynamic>>({
      'idvistoria': cleanId,
    });

    return result.data['expired'] == true;
  }
}

/// Resultado de `sendAudioMessage`: transcrições do áudio + resposta do agente.
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

import 'package:cloud_functions/cloud_functions.dart';

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
    final callable = _functions.httpsCallable('sendArgosMessage');

    final result = await callable.call<Map<String, dynamic>>({
      'text': text,
      'inspectionId': inspectionId,
    });

    final data = result.data;

    return data['reply']?.toString() ??
        'Entendi. Pode continuar descrevendo a vistoria.';
  }
}

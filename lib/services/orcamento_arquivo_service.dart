import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Item lido de um orçamento pronto (foto, PDF, planilha ou CSV) pela
/// Cloud Function `extrairOrcamentoArquivo`. A mão de obra vem como o
/// documento traz: horas, valor da hora e/ou valor total em reais; a tabela
/// decide se usa horas x valor da hora da oficina ou o valor em reais.
class OrcamentoArquivoItem {
  final String peca;
  final String tipoIntervencao;
  final int quantidade;
  final double valorPeca;
  final double? horasMaoObra;
  final double? valorHora;
  final double? valorMaoObra;
  final String tipoServico;

  const OrcamentoArquivoItem({
    required this.peca,
    required this.tipoIntervencao,
    required this.quantidade,
    required this.valorPeca,
    required this.horasMaoObra,
    this.valorHora,
    required this.valorMaoObra,
    required this.tipoServico,
  });

  factory OrcamentoArquivoItem.fromMap(Map<dynamic, dynamic> map) {
    double? toDouble(dynamic v) => v is num ? v.toDouble() : null;

    return OrcamentoArquivoItem(
      peca: map['peca']?.toString() ?? '',
      tipoIntervencao: map['tipoIntervencao']?.toString() ?? 'substituicao',
      quantidade: (map['quantidade'] is num)
          ? (map['quantidade'] as num).round().clamp(1, 9999)
          : 1,
      valorPeca: toDouble(map['valorPeca']) ?? 0,
      horasMaoObra: toDouble(map['horasMaoObra']),
      valorHora: toDouble(map['valorHora']),
      valorMaoObra: toDouble(map['valorMaoObra']),
      tipoServico: map['tipoServico']?.toString() ?? 'funilaria',
    );
  }
}

class OrcamentoArquivoResultado {
  final List<OrcamentoArquivoItem> itens;
  final bool legivel;
  final double? totalDocumento;

  /// Desconto, taxa ou outro ponto do documento para o mecânico conferir.
  final String? observacao;

  const OrcamentoArquivoResultado({
    required this.itens,
    required this.legivel,
    required this.totalDocumento,
    this.observacao,
  });
}

/// Sobe o arquivo do orçamento em `vistorias/{id}/orcamento/` e pede para a
/// Cloud Function ler os itens com o Gemini.
class OrcamentoArquivoService {
  OrcamentoArquivoService._();

  static final OrcamentoArquivoService instance = OrcamentoArquivoService._();

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  Future<OrcamentoArquivoResultado> importar({
    required String vistoriaDocId,
    required Uint8List bytes,
    required String nomeArquivo,
    required String mimeType,
  }) async {
    final extensao = nomeArquivo.contains('.')
        ? nomeArquivo.split('.').last.toLowerCase()
        : 'bin';
    final storagePath = 'vistorias/$vistoriaDocId/orcamento/'
        '${DateTime.now().millisecondsSinceEpoch}.$extensao';

    await FirebaseStorage.instance.ref(storagePath).putData(
          bytes,
          SettableMetadata(contentType: mimeType),
        );

    final callable = _functions.httpsCallable(
      'extrairOrcamentoArquivo',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
    );

    final result = await callable.call<Map<String, dynamic>>({
      'idvistoria': vistoriaDocId,
      'storagePath': storagePath,
      'mimeType': mimeType,
      'nomeArquivo': nomeArquivo,
    });

    final data = result.data;
    final itens = (data['itens'] as List? ?? const [])
        .whereType<Map>()
        .map(OrcamentoArquivoItem.fromMap)
        .where((item) => item.peca.trim().isNotEmpty)
        .toList();

    return OrcamentoArquivoResultado(
      itens: itens,
      legivel: data['legivel'] == true,
      totalDocumento: (data['totalDocumento'] as num?)?.toDouble(),
      observacao: data['observacao']?.toString(),
    );
  }
}

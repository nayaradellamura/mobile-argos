import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Preço e horas de referência de uma peça na `tabelaPrecos`.
class PrecoReferencia {
  final double valorPeca;
  final double horasMaoObra;

  const PrecoReferencia({required this.valorPeca, required this.horasMaoObra});
}

/// Consulta a coleção `tabelaPrecos/{categoria}/pecas` para pré-preencher o
/// orçamento no app — mesma tabela que `consultar_preco_referencia` usa no
/// agente ADK (`adk_agents/orcamento_team/tools/precos_tool.py`).
///
/// A tabela de cada categoria é pequena (~30 peças), então é carregada uma
/// vez e o casamento por nome é feito localmente. Qualquer falha (offline,
/// regra do Firestore negando leitura) só deixa o item sem sugestão.
class TabelaPrecosService {
  TabelaPrecosService._();

  static final TabelaPrecosService instance = TabelaPrecosService._();

  static const String _categoriaDefault = 'popular_compacto';

  // Mesmo mapeamento de `_MODELOS_POR_CATEGORIA` no precos_tool.py.
  static const Map<String, List<String>> _modelosPorCategoria = {
    'popular_compacto': [
      'onix', 'hb20', 'gol', 'ka', 'argo', 'mobi', 'polo', 'up!', 'up ',
      'kwid', 'sandero', 'prisma', 'voyage', 'logan', 'celta', 'palio',
    ],
    'medio_suv_compacto': [
      'corolla', 'civic', 'cronos', 'virtus', 't-cross', 'tcross',
      'creta', 'compass', 'jetta', 'cruze', 'duster', 'kicks', 'hr-v',
      'hrv', 'tiggo',
    ],
    'suv_grande_picape': [
      'hilux', 's10', 'ranger', 'sw4', 'trailblazer', 'pajero sport',
      'amarok', 'frontier', 'l200', 'land cruiser', 'grand cherokee',
    ],
  };

  final Map<String, Future<Map<String, PrecoReferencia>>> _cache = {};

  static String categoriaPorModelo(String modeloVeiculo) {
    final texto = modeloVeiculo.trim().toLowerCase();

    for (final entry in _modelosPorCategoria.entries) {
      if (entry.value.any(texto.contains)) return entry.key;
    }

    return _categoriaDefault;
  }

  Future<PrecoReferencia?> buscar({
    required String peca,
    required String modeloVeiculo,
  }) async {
    final chave = peca.trim().toLowerCase();
    if (chave.length < 3) return null;

    try {
      final tabela = await _carregarCategoria(
        categoriaPorModelo(modeloVeiculo),
      );

      final exato = tabela[chave];
      if (exato != null) return exato;

      // Casa "farol" com "farol dianteiro direito" e vice-versa; entre
      // vários candidatos, fica com o nome mais parecido em tamanho.
      String? melhor;
      for (final nome in tabela.keys) {
        if (!nome.contains(chave) && !chave.contains(nome)) continue;
        if (melhor == null ||
            (nome.length - chave.length).abs() <
                (melhor.length - chave.length).abs()) {
          melhor = nome;
        }
      }

      return melhor == null ? null : tabela[melhor];
    } catch (e) {
      debugPrint('Erro ao consultar tabela de preços: $e');
      return null;
    }
  }

  Future<Map<String, PrecoReferencia>> _carregarCategoria(String categoria) {
    return _cache.putIfAbsent(categoria, () async {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('tabelaPrecos')
            .doc(categoria)
            .collection('pecas')
            .get();

        return {
          for (final doc in snapshot.docs)
            doc.id.toLowerCase(): PrecoReferencia(
              valorPeca: (doc.data()['valorPeca'] as num?)?.toDouble() ?? 0,
              horasMaoObra:
                  (doc.data()['horasMaoObra'] as num?)?.toDouble() ?? 0,
            ),
        };
      } catch (e) {
        // Não guarda a falha no cache: a próxima consulta tenta de novo.
        _cache.remove(categoria);
        rethrow;
      }
    });
  }
}

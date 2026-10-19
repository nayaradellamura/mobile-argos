import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../features/orcamento/orcamento_calculo.dart';
import 'session_context_service.dart';

/// Valor da hora de mão de obra configurado pela própria oficina, por tipo
/// de serviço (`kTiposServico`), em `credenciados/{id}.valoresHoraMaoObra`.
class ValoresHoraService {
  ValoresHoraService._();

  static final ValoresHoraService instance = ValoresHoraService._();

  static const String _campo = 'valoresHoraMaoObra';

  Future<DocumentReference<Map<String, dynamic>>?> _credenciadoRef() async {
    final session = await SessionContextService.instance.resolve();
    if (session.credenciadoId.isEmpty) return null;

    return FirebaseFirestore.instance
        .collection('credenciados')
        .doc(session.credenciadoId);
  }

  /// Lê os valores configurados; tipos sem valor (ou com 0) ficam de fora.
  Future<Map<String, double>> carregar() async {
    try {
      final ref = await _credenciadoRef();
      if (ref == null) return {};

      final doc = await ref.get();
      final raw = doc.data()?[_campo];
      if (raw is! Map) return {};

      return {
        for (final entry in raw.entries)
          if (kTiposServico.containsKey(entry.key) &&
              entry.value is num &&
              (entry.value as num) > 0)
            entry.key.toString(): (entry.value as num).toDouble(),
      };
    } catch (e) {
      debugPrint('Erro ao carregar valores de hora da oficina: $e');
      return {};
    }
  }

  /// Grava os valores da oficina. Não espera a confirmação do servidor
  /// (offline o Firestore só confirma quando a conexão volta) — a tela já
  /// usa os valores novos localmente.
  Future<void> salvar(Map<String, double> valores) async {
    final ref = await _credenciadoRef();

    if (ref == null) {
      throw StateError('Usuário sem oficina vinculada.');
    }

    unawaited(
      ref.set({
        _campo: valores,
        'valoresHoraAtualizadoEm': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).catchError((Object e) {
        debugPrint('Erro ao salvar valores de hora da oficina: $e');
      }),
    );
  }
}

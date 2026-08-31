import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../inspections/data/inspection_case.dart';

enum MetricsPeriod { last7Days, last30Days, allTime, custom }

extension MetricsPeriodX on MetricsPeriod {
  String get label {
    switch (this) {
      case MetricsPeriod.last7Days:
        return '7 dias';
      case MetricsPeriod.last30Days:
        return '30 dias';
      case MetricsPeriod.allTime:
        return 'Total';
      case MetricsPeriod.custom:
        return 'Personalizado';
    }
  }
}

/// Desempenho agregado de um mecânico dentro do período selecionado.
///
/// É calculado inteiramente em memória a partir dos sinistros já
/// carregados do credenciado — não depende de nenhuma coleção/campo
/// agregado extra no Firestore.
class MechanicPerformance {
  final String uid;
  final String name;
  final String email;
  final String photoURL;
  final int totalAssigned;
  final int completed;
  final int inProgress;
  final int pending;
  final int aiAnalysis;
  final int revision;
  final int cancelled;

  const MechanicPerformance({
    required this.uid,
    required this.name,
    required this.email,
    required this.photoURL,
    required this.totalAssigned,
    required this.completed,
    required this.inProgress,
    required this.pending,
    required this.aiAnalysis,
    required this.revision,
    required this.cancelled,
  });

  double get completionRate =>
      totalAssigned == 0 ? 0 : completed / totalAssigned;
}

class _RosterEntry {
  final String uid;
  final String name;
  final String email;
  final String photoURL;

  const _RosterEntry({
    required this.uid,
    required this.name,
    required this.email,
    required this.photoURL,
  });
}

class MechanicPerformanceRepository {
  MechanicPerformanceRepository._();

  static final MechanicPerformanceRepository instance =
      MechanicPerformanceRepository._();

  /// Monta o ranking de desempenho de todos os mecânicos que já tiveram
  /// pelo menos um chamado atribuído nesta oficina, com as métricas
  /// recalculadas apenas para o [period] selecionado.
  Future<List<MechanicPerformance>> loadRanking({
    required String credenciadoId,
    required MetricsPeriod period,
    DateTime? customStart,
    DateTime? customEnd,
  }) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('sinistro')
        .where('credenciadoId', isEqualTo: credenciadoId)
        .get();

    final allInspections = snapshot.docs
        .map(InspectionCase.fromFirestore)
        .toList();

    final range = _resolveDateRange(period, customStart, customEnd);

    final periodInspections = range == null
        ? allInspections
        : allInspections.where((inspection) {
            final date = inspection.scheduledDate;
            return !date.isBefore(range.start) && !date.isAfter(range.end);
          }).toList();

    // Roster: um mecânico entra na lista se já teve algum chamado
    // atribuído a ele em qualquer época (não só no período selecionado),
    // para que ele continue aparecendo (com zeros) mesmo em períodos
    // sem atividade. Nome/foto usam o registro mais recente disponível.
    final sortedByRecency = [...allInspections]
      ..sort((a, b) => b.scheduledDate.compareTo(a.scheduledDate));

    final roster = <String, _RosterEntry>{};

    for (final inspection in sortedByRecency) {
      final uid = inspection.assignedToUid.trim();

      if (uid.isEmpty || roster.containsKey(uid)) continue;

      roster[uid] = _RosterEntry(
        uid: uid,
        name: inspection.assignedToName.trim(),
        email: inspection.assignedToEmail.trim(),
        photoURL: inspection.assignedToPhotoURL.trim(),
      );
    }

    final results = roster.values.map((entry) {
      final mine = periodInspections
          .where((inspection) => inspection.assignedToUid.trim() == entry.uid)
          .toList();

      return MechanicPerformance(
        uid: entry.uid,
        name: entry.name.isEmpty ? entry.email : entry.name,
        email: entry.email,
        photoURL: entry.photoURL,
        totalAssigned: mine.length,
        completed: mine.where((i) => i.isCompletedCategory).length,
        inProgress: mine.where((i) => i.isInProgressCategory).length,
        pending: mine.where((i) => i.isPendingCategory).length,
        aiAnalysis: mine.where((i) => i.isAiAnalysisCategory).length,
        revision: mine.where((i) => i.isRevisionCategory).length,
        cancelled: mine.where((i) => i.isCancelledCategory).length,
      );
    }).toList();

    results.sort((a, b) {
      final byCompleted = b.completed.compareTo(a.completed);
      if (byCompleted != 0) return byCompleted;

      return b.completionRate.compareTo(a.completionRate);
    });

    return results;
  }

  DateTimeRange? _resolveDateRange(
    MetricsPeriod period,
    DateTime? customStart,
    DateTime? customEnd,
  ) {
    final now = DateTime.now();
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);

    switch (period) {
      case MetricsPeriod.last7Days:
        return DateTimeRange(
          start: endOfToday.subtract(const Duration(days: 7)),
          end: endOfToday,
        );
      case MetricsPeriod.last30Days:
        return DateTimeRange(
          start: endOfToday.subtract(const Duration(days: 30)),
          end: endOfToday,
        );
      case MetricsPeriod.allTime:
        return null;
      case MetricsPeriod.custom:
        if (customStart == null || customEnd == null) return null;

        return DateTimeRange(
          start: DateTime(customStart.year, customStart.month, customStart.day),
          end: DateTime(
            customEnd.year,
            customEnd.month,
            customEnd.day,
            23,
            59,
            59,
          ),
        );
    }
  }
}

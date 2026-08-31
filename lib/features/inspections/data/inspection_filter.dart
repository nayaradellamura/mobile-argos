import 'package:flutter/material.dart';

import 'inspection_case.dart';

enum InspectionFilter {
  all,
  pending,
  inProgress,
  aiAnalysis,
  revision,
  cancelled,
  completed,
}

extension InspectionFilterX on InspectionFilter {
  String get label {
    switch (this) {
      case InspectionFilter.all:
        return 'Todas';
      case InspectionFilter.pending:
        return 'Pendentes';
      case InspectionFilter.inProgress:
        return 'Andamento';
      case InspectionFilter.aiAnalysis:
        return 'Analise';
      case InspectionFilter.revision:
        return 'Revisão';
      case InspectionFilter.cancelled:
        return 'Canceladas';
      case InspectionFilter.completed:
        return 'Concluídas';
    }
  }

  String get description {
    switch (this) {
      case InspectionFilter.all:
        return 'Todos os sinistros';
      case InspectionFilter.pending:
        return 'Sem check-in';
      case InspectionFilter.inProgress:
        return 'Aguardando vistoria';
      case InspectionFilter.aiAnalysis:
        return 'Analise humana';
      case InspectionFilter.revision:
        return 'Retificação/revisão';
      case InspectionFilter.cancelled:
        return 'Canceladas';
      case InspectionFilter.completed:
        return 'Finalizadas';
    }
  }

  IconData get icon {
    switch (this) {
      case InspectionFilter.all:
        return Icons.dashboard_customize_outlined;
      case InspectionFilter.pending:
        return Icons.schedule;
      case InspectionFilter.inProgress:
        return Icons.build_circle_outlined;
      case InspectionFilter.aiAnalysis:
        return Icons.psychology_alt_outlined;
      case InspectionFilter.revision:
        return Icons.rate_review_outlined;
      case InspectionFilter.cancelled:
        return Icons.cancel_outlined;
      case InspectionFilter.completed:
        return Icons.verified_outlined;
    }
  }

  Color get color {
    switch (this) {
      case InspectionFilter.all:
        return const Color(0xFF0057C0);
      case InspectionFilter.pending:
        return Colors.orange;
      case InspectionFilter.inProgress:
        return const Color(0xFF0057C0);
      case InspectionFilter.aiAnalysis:
        return Colors.purple;
      case InspectionFilter.revision:
        return Colors.deepOrange;
      case InspectionFilter.cancelled:
        return Colors.redAccent;
      case InspectionFilter.completed:
        return Colors.green;
    }
  }

  bool matches(InspectionCase inspection) {
    switch (this) {
      case InspectionFilter.all:
        return true;
      case InspectionFilter.pending:
        return inspection.isPendingCategory;
      case InspectionFilter.inProgress:
        return inspection.isInProgressCategory;
      case InspectionFilter.aiAnalysis:
        return inspection.isAiAnalysisCategory;
      case InspectionFilter.revision:
        return inspection.isRevisionCategory;
      case InspectionFilter.cancelled:
        return inspection.isCancelledCategory;
      case InspectionFilter.completed:
        return inspection.isCompletedCategory;
    }
  }
}

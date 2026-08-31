import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../services/sinistro_presence_service.dart';
import 'inspection_parsing_utils.dart';

enum InspectionStatus {
  pending,
  inProgress,
  submitted,
  approved,
  rejected,
  finalized,
  cancelled,
}

extension InspectionStatusX on InspectionStatus {
  static InspectionStatus fromFirestore(dynamic value) {
    final normalized = normalizeStatusText(value);

    if (normalized.contains('andamento') ||
        normalized.contains('checkin') ||
        normalized.contains('check_in') ||
        normalized.contains('check in') ||
        normalized.contains('in progress') ||
        normalized.contains('in_progress')) {
      return InspectionStatus.inProgress;
    }

    if (normalized.contains('enviada') ||
        normalized.contains('evidencia') ||
        normalized.contains('submitted') ||
        normalized.contains('analise') ||
        normalized.contains('aguardando_ia') ||
        normalized.contains('processando_ia') ||
        normalized.contains('aguardando ia') ||
        normalized.contains('processando ia') ||
        normalized.contains('review')) {
      return InspectionStatus.submitted;
    }

    if (normalized.contains('aprovada') ||
        normalized.contains('aprovado') ||
        normalized.contains('approved')) {
      return InspectionStatus.approved;
    }

    if (normalized.contains('finalizada') ||
        normalized.contains('finalizado') ||
        normalized.contains('finalized')) {
      return InspectionStatus.finalized;
    }

    if (normalized.contains('rejeitada') ||
        normalized.contains('rejeitado') ||
        normalized.contains('negada') ||
        normalized.contains('negado') ||
        normalized.contains('reprovada') ||
        normalized.contains('reprovado') ||
        normalized.contains('rejected')) {
      return InspectionStatus.rejected;
    }

    if (normalized.contains('cancelada') ||
        normalized.contains('cancelado') ||
        normalized.contains('cancelled')) {
      return InspectionStatus.cancelled;
    }

    return InspectionStatus.pending;
  }

  String get label {
    switch (this) {
      case InspectionStatus.pending:
        return 'Pendente';
      case InspectionStatus.inProgress:
        return 'Em andamento';
      case InspectionStatus.submitted:
        return 'Em analise';
      case InspectionStatus.approved:
        return 'Aprovada';
      case InspectionStatus.rejected:
        return 'Rejeitada';
      case InspectionStatus.finalized:
        return 'Finalizada';
      case InspectionStatus.cancelled:
        return 'Cancelada';
    }
  }

  Color get color {
    switch (this) {
      case InspectionStatus.pending:
        return Colors.orange;
      case InspectionStatus.inProgress:
        return const Color(0xFF0057C0);
      case InspectionStatus.submitted:
        return Colors.purple;
      case InspectionStatus.approved:
        return Colors.green;
      case InspectionStatus.rejected:
        return Colors.redAccent;
      case InspectionStatus.finalized:
        return Colors.green;
      case InspectionStatus.cancelled:
        return Colors.grey;
    }
  }
}

enum InspectionPriority { low, medium, high }

extension InspectionPriorityX on InspectionPriority {
  static InspectionPriority fromFirestore(dynamic value) {
    final normalized = normalizeStatusText(value);

    if (normalized.contains('alta') || normalized.contains('high')) {
      return InspectionPriority.high;
    }

    if (normalized.contains('media') ||
        normalized.contains('média') ||
        normalized.contains('medium')) {
      return InspectionPriority.medium;
    }

    return InspectionPriority.low;
  }

  String get label {
    switch (this) {
      case InspectionPriority.low:
        return 'Baixa';
      case InspectionPriority.medium:
        return 'Média';
      case InspectionPriority.high:
        return 'Alta';
    }
  }

  Color get color {
    switch (this) {
      case InspectionPriority.low:
        return Colors.green;
      case InspectionPriority.medium:
        return Colors.orange;
      case InspectionPriority.high:
        return Colors.redAccent;
    }
  }
}

class VehicleInfo {
  final String plate;
  final String model;
  final String brand;
  final String year;
  final String color;
  final String chassis;
  final String renavam;
  final String fuel;

  const VehicleInfo({
    required this.plate,
    required this.model,
    required this.brand,
    required this.year,
    required this.color,
    required this.chassis,
    required this.renavam,
    required this.fuel,
  });

  factory VehicleInfo.fromSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> root,
  ) {
    final brand = stringValue(snapshot['marca']);
    final modelBase = stringValue(
      snapshot['modelo'],
      fallback: stringValue(root['vehicle']),
    );

    final model = _buildVehicleModel(brand, modelBase);

    return VehicleInfo(
      plate: stringValue(
        snapshot['placa'],
        fallback: stringValue(root['plate']),
      ),
      model: model,
      brand: brand,
      year: stringValue(
        snapshot['anoFabricacao'],
        fallback: stringValue(snapshot['ano']),
      ),
      color: stringValue(snapshot['cor']),
      chassis: stringValue(snapshot['chassi']),
      renavam: stringValue(snapshot['renavam']),
      fuel: stringValue(snapshot['combustivel']),
    );
  }
}

class OwnerInfo {
  final String name;
  final String document;
  final String phone;
  final String email;

  const OwnerInfo({
    required this.name,
    required this.document,
    required this.phone,
    required this.email,
  });

  factory OwnerInfo.fromSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> root,
  ) {
    return OwnerInfo(
      name: stringValue(
        snapshot['nomeCompleto'],
        fallback: stringValue(root['owner']),
      ),
      document: stringValue(snapshot['cpfCnpj']),
      phone: stringValue(snapshot['telefone']),
      email: stringValue(snapshot['email']),
    );
  }
}

class WorkshopInfo {
  final String name;
  final String address;
  final String phone;
  final String email;

  const WorkshopInfo({
    required this.name,
    required this.address,
    required this.phone,
    required this.email,
  });

  factory WorkshopInfo.fromSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> root,
  ) {
    final address = _formatWorkshopAddress(snapshot);

    return WorkshopInfo(
      name: stringValue(
        snapshot['name'],
        fallback: stringValue(root['workshop']),
      ),
      address: address,
      phone: stringValue(snapshot['phone']),
      email: stringValue(snapshot['email']),
    );
  }
}

class InspectionCase {
  final String id;
  final String protocol;
  final InspectionStatus status;
  final InspectionPriority priority;
  final String insurer;
  final String claimType;
  final DateTime scheduledDate;
  final DateTime? checkInAt;
  final VehicleInfo vehicle;
  final OwnerInfo owner;
  final WorkshopInfo workshop;
  final String damageDescription;
  final String observations;
  final String assignedToUid;
  final String assignedToName;
  final String assignedToEmail;
  final String assignedToPhotoURL;
  final DateTime? assignedAt;
  final List<SinistroViewer> activeViewers;
  final String vistoriaAtualId;
  final String vistoriaAtualStatus;
  final String vistoriaAtualTipo;
  final String vistoriaAtualOrigemId;
  final String retificacaoAtualId;

  const InspectionCase({
    required this.id,
    required this.protocol,
    required this.status,
    required this.priority,
    required this.insurer,
    required this.claimType,
    required this.scheduledDate,
    this.checkInAt,
    required this.vehicle,
    required this.owner,
    required this.workshop,
    required this.damageDescription,
    required this.observations,
    this.assignedToUid = '',
    this.assignedToName = '',
    this.assignedToEmail = '',
    this.assignedToPhotoURL = '',
    this.assignedAt,
    this.activeViewers = const [],
    this.vistoriaAtualId = '',
    this.vistoriaAtualStatus = '',
    this.vistoriaAtualTipo = '',
    this.vistoriaAtualOrigemId = '',
    this.retificacaoAtualId = '',
  });

  factory InspectionCase.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? <String, dynamic>{};

    final clienteSnapshot = asStringMap(data['clienteSnapshot']);
    final veiculoSnapshot = asStringMap(data['veiculoSnapshot']);
    final credenciadoSnapshot = asStringMap(data['credenciadoSnapshot']);
    final seguradoraSnapshot = asStringMap(data['seguradoraSnapshot']);

    final scheduledDate =
        parseFirestoreDateTime(data['scheduledDate']) ??
        parseFirestoreDateTime(data['entryDate']) ??
        DateTime.now();

    return InspectionCase(
      id: doc.id,
      protocol: stringValue(data['protocol'], fallback: doc.id),
      status: InspectionStatusX.fromFirestore(data['status']),
      priority: InspectionPriorityX.fromFirestore(data['priority']),
      insurer: stringValue(
        seguradoraSnapshot['name'],
        fallback: stringValue(data['insurer']),
      ),
      claimType: stringValue(data['claimType'], fallback: 'Sinistro'),
      scheduledDate: scheduledDate,
      checkInAt: parseFirestoreDateTime(data['checkInAt']),
      vehicle: VehicleInfo.fromSnapshot(veiculoSnapshot, data),
      owner: OwnerInfo.fromSnapshot(clienteSnapshot, data),
      workshop: WorkshopInfo.fromSnapshot(credenciadoSnapshot, data),
      damageDescription: stringValue(data['damageDescription']),
      observations: stringValue(data['observations']),
      assignedToUid: stringValue(data['assignedToUid']),
      assignedToName: stringValue(data['assignedToName']),
      assignedToEmail: stringValue(data['assignedToEmail']),
      assignedToPhotoURL: stringValue(data['assignedToPhotoURL']),
      assignedAt: parseFirestoreDateTime(data['assignedAt']),
      activeViewers: _parseSinistroViewers(data['activeViewers']),
      vistoriaAtualId: stringValue(data['vistoriaAtualId']),
      vistoriaAtualStatus: stringValue(data['vistoriaAtualStatus']),
      vistoriaAtualTipo: stringValue(data['vistoriaAtualTipo']),
      vistoriaAtualOrigemId: stringValue(data['vistoriaAtualOrigemId']),
      retificacaoAtualId: stringValue(data['retificacaoAtualId']),
    );
  }

  bool get hasAssignedUser => assignedToUid.trim().isNotEmpty;

  bool get isAssignedToCurrentUser {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return currentUid.isNotEmpty && assignedToUid.trim() == currentUid;
  }

  bool get isAssignedToAnotherUser {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final assignedUid = assignedToUid.trim();

    return assignedUid.isNotEmpty && assignedUid != currentUid;
  }

  bool get isCompletedCategory {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.approved ||
        status == InspectionStatus.finalized ||
        vistoriaStatus.contains('aprovada') ||
        vistoriaStatus.contains('aprovado') ||
        vistoriaStatus.contains('approved');
  }

  bool get isAiAnalysisCategory {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.submitted ||
        (vistoriaStatus.isNotEmpty &&
            !vistoriaStatus.contains('em_andamento') &&
            !vistoriaStatus.contains('andamento') &&
            !isCompletedCategory &&
            !isRevisionCategory &&
            !isCancelledCategory) ||
        vistoriaStatus.contains('analise') ||
        vistoriaStatus.contains('análise') ||
        vistoriaStatus.contains('finalizada') ||
        vistoriaStatus.contains('finalizado') ||
        vistoriaStatus.contains('finalized') ||
        vistoriaStatus.contains('em_analise_operacional') ||
        vistoriaStatus.contains('review') ||
        vistoriaStatus.contains('submitted');
  }

  bool get isRevisionCategory {
    final tipo = normalizeStatusText(vistoriaAtualTipo);
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);
    final origemId = vistoriaAtualOrigemId.trim();
    final retificacaoId = retificacaoAtualId.trim();

    // Retificação/revisão deve ser identificada pela modelagem nova:
    // - a vistoria atual é RETIFICACAO/REVISAO;
    // - ou a vistoria atual nasceu de uma vistoria original (vistoriaAtualOrigemId);
    // - ou este sinistro/original aponta para uma retificação atual (retificacaoAtualId).
    // Status REJEITADA sozinho não é usado aqui, porque rejeição e retificação
    // são conceitos diferentes no novo fluxo operacional.
    return status == InspectionStatus.rejected ||
        tipo.contains('retificacao') ||
        tipo.contains('retificação') ||
        tipo.contains('revisao') ||
        tipo.contains('revisão') ||
        origemId.isNotEmpty ||
        retificacaoId.isNotEmpty ||
        vistoriaStatus.contains('rejeitada') ||
        vistoriaStatus.contains('rejeitado') ||
        vistoriaStatus.contains('rejected') ||
        vistoriaStatus.contains('retificar') ||
        vistoriaStatus.contains('retificacao') ||
        vistoriaStatus.contains('retificação') ||
        vistoriaStatus.contains('revisao') ||
        vistoriaStatus.contains('revisão');
  }

  bool get isCancelledCategory {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.cancelled ||
        vistoriaStatus.contains('cancelada') ||
        vistoriaStatus.contains('cancelado') ||
        vistoriaStatus.contains('cancelled') ||
        vistoriaStatus.contains('expirada') ||
        vistoriaStatus.contains('expirado') ||
        vistoriaStatus.contains('expired') ||
        vistoriaStatus.contains('abandonada') ||
        vistoriaStatus.contains('abandonado');
  }

  bool get isInProgressCategory {
    return checkInAt != null &&
        !isAiAnalysisCategory &&
        !isRevisionCategory &&
        !isCancelledCategory &&
        !isCompletedCategory;
  }

  bool get isPendingCategory {
    return checkInAt == null &&
        !isAiAnalysisCategory &&
        !isRevisionCategory &&
        !isCancelledCategory &&
        !isCompletedCategory;
  }

  InspectionCase copyWith({
    InspectionStatus? status,
    DateTime? checkInAt,
    String? assignedToUid,
    String? assignedToName,
    String? assignedToEmail,
    String? assignedToPhotoURL,
    DateTime? assignedAt,
    List<SinistroViewer>? activeViewers,
    String? vistoriaAtualId,
    String? vistoriaAtualStatus,
    String? vistoriaAtualTipo,
    String? vistoriaAtualOrigemId,
    String? retificacaoAtualId,
  }) {
    return InspectionCase(
      id: id,
      protocol: protocol,
      status: status ?? this.status,
      priority: priority,
      insurer: insurer,
      claimType: claimType,
      scheduledDate: scheduledDate,
      checkInAt: checkInAt ?? this.checkInAt,
      vehicle: vehicle,
      owner: owner,
      workshop: workshop,
      damageDescription: damageDescription,
      observations: observations,
      assignedToUid: assignedToUid ?? this.assignedToUid,
      assignedToName: assignedToName ?? this.assignedToName,
      assignedToEmail: assignedToEmail ?? this.assignedToEmail,
      assignedToPhotoURL: assignedToPhotoURL ?? this.assignedToPhotoURL,
      assignedAt: assignedAt ?? this.assignedAt,
      activeViewers: activeViewers ?? this.activeViewers,
      vistoriaAtualId: vistoriaAtualId ?? this.vistoriaAtualId,
      vistoriaAtualStatus: vistoriaAtualStatus ?? this.vistoriaAtualStatus,
      vistoriaAtualTipo: vistoriaAtualTipo ?? this.vistoriaAtualTipo,
      vistoriaAtualOrigemId: vistoriaAtualOrigemId ?? this.vistoriaAtualOrigemId,
      retificacaoAtualId: retificacaoAtualId ?? this.retificacaoAtualId,
    );
  }
}

String _buildVehicleModel(String brand, String model) {
  final cleanBrand = brand.trim();
  final cleanModel = model.trim();

  if (cleanBrand.isEmpty) {
    return cleanModel.isEmpty ? 'Veículo não informado' : cleanModel;
  }

  if (cleanModel.isEmpty) {
    return cleanBrand;
  }

  if (cleanModel.toLowerCase().contains(cleanBrand.toLowerCase())) {
    return cleanModel;
  }

  return '$cleanBrand $cleanModel';
}

String _formatWorkshopAddress(Map<String, dynamic> snapshot) {
  final address = stringValue(snapshot['address']);
  final city = stringValue(snapshot['city']);
  final uf = stringValue(snapshot['uf']);

  if (address.isEmpty && city.isEmpty && uf.isEmpty) {
    return '';
  }

  final cityUf = [city, uf].where((item) => item.trim().isNotEmpty).join('/');

  if (address.isEmpty) return cityUf;
  if (cityUf.isEmpty) return address;

  return '$address - $cityUf';
}

List<SinistroViewer> _parseSinistroViewers(dynamic value) {
  if (value is! List) return const [];

  return value
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .map((item) => SinistroViewer.fromMap(item['uid']?.toString() ?? '', item))
      .toList();
}

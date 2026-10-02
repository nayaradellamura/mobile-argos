import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../services/sinistro_presence_service.dart';
import '../../../services/vistoria_chat_session_service.dart';
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

// Ordem de RESOLUÇÃO (não é a ordem de exibição dos chips -- ver
// InspectionFilter, que define a ordem que aparece na tela): do estado
// mais definitivo pro mais preliminar. Usada por InspectionCase.primaryCategory
// pra decidir qual categoria vence quando mais de uma condição bate.
enum InspectionLifecycleCategory {
  completed,
  cancelled,
  revision,
  aiAnalysis,
  inProgress,
  pending,
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
  final String orcamentoAprovadoStatus;
  final String orcamentoAprovadoUrl;
  final double orcamentoAprovadoValorTotal;

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
    this.orcamentoAprovadoStatus = '',
    this.orcamentoAprovadoUrl = '',
    this.orcamentoAprovadoValorTotal = 0,
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

    final orcamentoAprovado = asStringMap(data['orcamentoAprovado']);

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
      orcamentoAprovadoStatus: stringValue(orcamentoAprovado['status']),
      orcamentoAprovadoUrl: stringValue(orcamentoAprovado['url']),
      orcamentoAprovadoValorTotal:
          (orcamentoAprovado['valorTotal'] as num?)?.toDouble() ?? 0,
    );
  }

  bool get hasOrcamentoAprovado => orcamentoAprovadoStatus == 'pronto';

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

  // Única fonte da verdade pra categoria de um sinistro -- antes, cada
  // isXCategory calculava sua própria condição de forma independente, o que
  // deixava sobrepor categorias (ex: isRevisionCategory e isCancelledCategory
  // podiam vir `true` juntas se `status` e `vistoriaAtualStatus`, dois campos
  // escritos por caminhos diferentes, ficassem dessincronizados por um
  // instante) -- o card contava em dois filtros ao mesmo tempo e podia
  // mostrar um selo diferente do filtro em que estava. Agora é uma escada só,
  // do estado mais definitivo pro mais preliminar: a primeira condição que
  // bater vence, ninguém mais é checado (ver conversa de redesign 2026-10-02).
  InspectionLifecycleCategory get primaryCategory {
    if (_isApproved) return InspectionLifecycleCategory.completed;
    if (_isCancelledOnly) return InspectionLifecycleCategory.cancelled;
    if (_isRejectedNow) return InspectionLifecycleCategory.revision;
    if (_isInAnalysis) return InspectionLifecycleCategory.aiAnalysis;
    if (checkInAt != null) return InspectionLifecycleCategory.inProgress;
    return InspectionLifecycleCategory.pending;
  }

  // "finalizada" no STATUS da vistoria é o valor real gravado quando a
  // aprovação acontece — não é um estágio intermediário de análise.
  bool get _isApproved {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.approved ||
        status == InspectionStatus.finalized ||
        vistoriaStatus.contains('aprovada') ||
        vistoriaStatus.contains('aprovado') ||
        vistoriaStatus.contains('approved') ||
        vistoriaStatus.contains('finalizada') ||
        vistoriaStatus.contains('finalizado') ||
        vistoriaStatus.contains('finalized');
  }

  // Só cancelamento de verdade (decisão do analista) -- expirada/abandonada
  // migraram pra "Andamento" (ver _isExpiredOrAbandoned/isInProgressCategory):
  // não são uma decisão de ninguém, são só "essa tentativa parou e o
  // mecânico pode simplesmente começar de novo", o que é conceitualmente
  // muito mais perto de "ainda em aberto" do que de "encerrado".
  bool get _isCancelledOnly {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.cancelled ||
        vistoriaStatus.contains('cancelada') ||
        vistoriaStatus.contains('cancelado') ||
        vistoriaStatus.contains('cancelled');
  }

  // Só rejeitada AGORA -- uma retificação que o mecânico já começou a
  // trabalhar (EM_ANDAMENTO) não conta mais como "em revisão", conta como
  // "em andamento" (é literalmente o mesmo status de qualquer vistoria
  // sendo feita). "Revisão" passa a significar só "precisa agir", não
  // "história passou por uma rejeição algum dia".
  bool get _isRejectedNow {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.rejected ||
        vistoriaStatus.contains('rejeitada') ||
        vistoriaStatus.contains('rejeitado') ||
        vistoriaStatus.contains('rejected');
  }

  // Lista FECHADA de valores que significam análise -- antes tinha um
  // coringa ("qualquer vistoriaAtualStatus não vazio que não contém
  // 'andamento'") que jogava qualquer status não mapeado (typo, valor novo
  // do backend) pra "Análise" por acidente. Agora um status desconhecido cai
  // em Andamento/Pendente (conforme checkInAt), nunca mais finge ser análise
  // sem ser.
  bool get _isInAnalysis {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return status == InspectionStatus.submitted ||
        vistoriaStatus.contains('analise') ||
        vistoriaStatus.contains('análise') ||
        vistoriaStatus.contains('em_analise_operacional') ||
        vistoriaStatus.contains('review') ||
        vistoriaStatus.contains('submitted');
  }

  bool get isCompletedCategory =>
      primaryCategory == InspectionLifecycleCategory.completed;

  bool get isCancelledCategory =>
      primaryCategory == InspectionLifecycleCategory.cancelled;

  bool get isRevisionCategory =>
      primaryCategory == InspectionLifecycleCategory.revision;

  bool get isAiAnalysisCategory =>
      primaryCategory == InspectionLifecycleCategory.aiAnalysis;

  bool get isInProgressCategory =>
      primaryCategory == InspectionLifecycleCategory.inProgress;

  bool get isPendingCategory =>
      primaryCategory == InspectionLifecycleCategory.pending;

  // Badge de status mostrado nos cards/resumo do sinistro. Não pode usar só
  // `status.label` (o status CRU do sinistro): cancelamento/revisão só
  // ficam gravados em vistoriaAtualStatus (denormalizado pela vistoria), o
  // sinistro em si segue "EM_ANDAMENTO" — sem isso o card mostra "Em
  // andamento" pra uma vistoria já cancelada.
  String get displayStatusLabel {
    switch (primaryCategory) {
      case InspectionLifecycleCategory.cancelled:
        return 'Cancelada';
      case InspectionLifecycleCategory.revision:
        return 'Rejeitada';
      case InspectionLifecycleCategory.completed:
        return 'Finalizada';
      case InspectionLifecycleCategory.aiAnalysis:
        return 'Em analise';
      case InspectionLifecycleCategory.inProgress:
        if (_isExpired) return 'Expirada';
        if (_isAbandoned) return 'Abandonada';
        return status.label;
      case InspectionLifecycleCategory.pending:
        return status.label;
    }
  }

  Color get displayStatusColor {
    switch (primaryCategory) {
      case InspectionLifecycleCategory.cancelled:
        return Colors.grey;
      case InspectionLifecycleCategory.revision:
        return Colors.redAccent;
      case InspectionLifecycleCategory.completed:
        return Colors.green;
      case InspectionLifecycleCategory.aiAnalysis:
        return Colors.purple;
      case InspectionLifecycleCategory.inProgress:
        if (_isExpired) return Colors.deepOrange;
        if (_isAbandoned) return Colors.grey;
        return status.color;
      case InspectionLifecycleCategory.pending:
        return status.color;
    }
  }

  bool get _isExpired {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return vistoriaStatus.contains('expirada') ||
        vistoriaStatus.contains('expirado') ||
        vistoriaStatus.contains('expired');
  }

  bool get _isAbandoned {
    final vistoriaStatus = normalizeStatusText(vistoriaAtualStatus);

    return vistoriaStatus.contains('abandonada') ||
        vistoriaStatus.contains('abandonado');
  }

  // Expirou por inatividade (24h úteis) ou foi abandonada -- continua
  // existindo como sinalizador à parte (não é mais uma categoria de filtro
  // própria, ver primaryCategory) porque ainda é útil pra decisão de
  // negócio em outros lugares (ex: VistoriaChatSessionService) e pro selo
  // "Expirada"/"Abandonada" dentro da categoria Andamento.
  bool get isExpiredOrAbandonedCategory => _isExpired || _isAbandoned;

  /// A vistoria atual foi criada/está sendo processada 100% offline (ID
  /// provisório, ver `VistoriaChatSessionService.createVistoriaOffline`) --
  /// ainda não tem o número sequencial real nem terminou de subir pro
  /// Storage. Some sozinho quando a vistoria termina de sincronizar
  /// (reconciliação troca `vistoriaAtualId` pelo ID real).
  bool get isPendingOfflineSync => vistoriaAtualId
      .trim()
      .startsWith(VistoriaChatSessionService.pendingVistoriaIdPrefix);

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
      orcamentoAprovadoStatus: orcamentoAprovadoStatus,
      orcamentoAprovadoUrl: orcamentoAprovadoUrl,
      orcamentoAprovadoValorTotal: orcamentoAprovadoValorTotal,
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

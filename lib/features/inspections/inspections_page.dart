import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class InspectionsPage extends StatefulWidget {
  final VoidCallback onOpenInspection;

  /// Preparação para o fluxo novo do Chat IA por sinistro.
  ///
  /// Se o MainShell ainda usa apenas [onOpenInspection], nada quebra.
  /// Quando o chat for adaptado para receber sinistroId, basta passar:
  /// onOpenInspectionById: (sinistroId) => ...
  final ValueChanged<String>? onOpenInspectionById;

  const InspectionsPage({
    super.key,
    required this.onOpenInspection,
    this.onOpenInspectionById,
  });

  @override
  State<InspectionsPage> createState() => _InspectionsPageState();
}

class _InspectionsPageState extends State<InspectionsPage> {
  late Future<_CredenciadoContext> _credenciadoFuture;

  @override
  void initState() {
    super.initState();
    _credenciadoFuture = _loadCredenciadoContext();
  }

  Future<_CredenciadoContext> _loadCredenciadoContext() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw const _InspectionAccessException(
        title: 'Usuário não autenticado',
        message: 'Faça login novamente para carregar as vistorias.',
      );
    }

    final uid = user.uid;
    final email = user.email?.trim().toLowerCase() ?? '';

    final usersCollection = FirebaseFirestore.instance.collection('users');

    final userByUidSnap = await usersCollection.doc(uid).get();
    final userByUidData = userByUidSnap.data();

    final credenciadoIdByUid =
        userByUidData?['credenciadoId']?.toString().trim() ?? '';

    if (credenciadoIdByUid.isNotEmpty) {
      return _CredenciadoContext(
        uid: uid,
        credenciadoId: credenciadoIdByUid,
        credenciadoName:
            userByUidData?['credenciadoNome']?.toString().trim() ?? '',
      );
    }

    if (email.isNotEmpty) {
      final userByEmailSnap = await usersCollection.doc(email).get();
      final userByEmailData = userByEmailSnap.data();

      final credenciadoIdByEmail =
          userByEmailData?['credenciadoId']?.toString().trim() ?? '';

      if (credenciadoIdByEmail.isNotEmpty) {
        return _CredenciadoContext(
          uid: uid,
          credenciadoId: credenciadoIdByEmail,
          credenciadoName:
              userByEmailData?['credenciadoNome']?.toString().trim() ?? '',
        );
      }
    }

    final credenciadoQuery = await FirebaseFirestore.instance
        .collection('credenciados')
        .where('funcionariosUids', arrayContains: uid)
        .limit(1)
        .get();

    if (credenciadoQuery.docs.isEmpty) {
      throw const _InspectionAccessException(
        title: 'Nenhuma oficina vinculada',
        message:
            'Seu usuário ainda não está vinculado a uma oficina credenciada.',
      );
    }

    final credenciadoDoc = credenciadoQuery.docs.first;
    final credenciadoData = credenciadoDoc.data();

    return _CredenciadoContext(
      uid: uid,
      credenciadoId: credenciadoDoc.id,
      credenciadoName: credenciadoData['name']?.toString().trim() ?? '',
    );
  }

  Stream<List<InspectionCase>> _inspectionStream(String credenciadoId) {
    return FirebaseFirestore.instance
        .collection('sinistro')
        .where('credenciadoId', isEqualTo: credenciadoId)
        .snapshots()
        .map((snapshot) {
          final inspections = snapshot.docs
              .map((doc) => InspectionCase.fromFirestore(doc))
              .toList();

          inspections.sort(
            (a, b) => a.scheduledDate.compareTo(b.scheduledDate),
          );

          return inspections;
        });
  }

  void _openInspectionSummary(InspectionCase inspection) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InspectionSummaryPage(
          inspection: inspection,
          onOpenChat: () {
            widget.onOpenInspectionById?.call(inspection.id);
            if (widget.onOpenInspectionById == null) {
              widget.onOpenInspection();
            }
          },
        ),
      ),
    );
  }

  Widget _buildBodyForInspections(List<InspectionCase> inspections) {
    final pendingCount = inspections
        .where((inspection) => inspection.status == InspectionStatus.pending)
        .length;

    final inProgressCount = inspections
        .where((inspection) => inspection.status == InspectionStatus.inProgress)
        .length;

    final checkedInCount = inspections
        .where((inspection) => inspection.checkInAt != null)
        .length;

    return SafeArea(
      child: Column(
        children: [
          _InspectionsHeader(
            total: inspections.length,
            pending: pendingCount,
            inProgress: inProgressCount,
            checkedIn: checkedInCount,
          ),
          Expanded(
            child: inspections.isEmpty
                ? const _StateMessage(
                    icon: Icons.assignment_outlined,
                    title: 'Nenhuma vistoria atribuída',
                    message:
                        'Não há sinistros atribuídos para esta oficina no momento.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: inspections.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final inspection = inspections[index];

                      return _InspectionCard(
                        inspection: inspection,
                        onTap: () => _openInspectionSummary(inspection),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_CredenciadoContext>(
      future: _credenciadoFuture,
      builder: (context, accessSnapshot) {
        if (accessSnapshot.connectionState == ConnectionState.waiting) {
          return const SafeArea(
            child: Column(
              children: [
                _InspectionsHeader(
                  total: 0,
                  pending: 0,
                  inProgress: 0,
                  checkedIn: 0,
                ),
                Expanded(
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFF0057C0)),
                  ),
                ),
              ],
            ),
          );
        }

        if (accessSnapshot.hasError) {
          final error = accessSnapshot.error;

          if (error is _InspectionAccessException) {
            return SafeArea(
              child: Column(
                children: [
                  const _InspectionsHeader(
                    total: 0,
                    pending: 0,
                    inProgress: 0,
                    checkedIn: 0,
                  ),
                  Expanded(
                    child: _StateMessage(
                      icon: Icons.lock_outline,
                      title: error.title,
                      message: error.message,
                      actionLabel: 'Tentar novamente',
                      onAction: () {
                        setState(() {
                          _credenciadoFuture = _loadCredenciadoContext();
                        });
                      },
                    ),
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: Column(
              children: [
                const _InspectionsHeader(
                  total: 0,
                  pending: 0,
                  inProgress: 0,
                  checkedIn: 0,
                ),
                Expanded(
                  child: _StateMessage(
                    icon: Icons.error_outline,
                    title: 'Erro ao carregar vistorias',
                    message:
                        'Não foi possível identificar a oficina vinculada ao usuário.',
                    actionLabel: 'Tentar novamente',
                    onAction: () {
                      setState(() {
                        _credenciadoFuture = _loadCredenciadoContext();
                      });
                    },
                  ),
                ),
              ],
            ),
          );
        }

        final contextData = accessSnapshot.data;

        if (contextData == null || contextData.credenciadoId.isEmpty) {
          return const SafeArea(
            child: Column(
              children: [
                _InspectionsHeader(
                  total: 0,
                  pending: 0,
                  inProgress: 0,
                  checkedIn: 0,
                ),
                Expanded(
                  child: _StateMessage(
                    icon: Icons.business_outlined,
                    title: 'Oficina não encontrada',
                    message:
                        'Não foi possível encontrar uma oficina vinculada ao seu usuário.',
                  ),
                ),
              ],
            ),
          );
        }

        return StreamBuilder<List<InspectionCase>>(
          stream: _inspectionStream(contextData.credenciadoId),
          builder: (context, inspectionSnapshot) {
            if (inspectionSnapshot.connectionState == ConnectionState.waiting) {
              return const SafeArea(
                child: Column(
                  children: [
                    _InspectionsHeader(
                      total: 0,
                      pending: 0,
                      inProgress: 0,
                      checkedIn: 0,
                    ),
                    Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF0057C0),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            if (inspectionSnapshot.hasError) {
              return SafeArea(
                child: Column(
                  children: [
                    const _InspectionsHeader(
                      total: 0,
                      pending: 0,
                      inProgress: 0,
                      checkedIn: 0,
                    ),
                    Expanded(
                      child: _StateMessage(
                        icon: Icons.error_outline,
                        title: 'Erro ao buscar sinistros',
                        message:
                            'Não foi possível carregar as vistorias atribuídas para esta oficina.',
                        actionLabel: 'Recarregar',
                        onAction: () {
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
              );
            }

            return _buildBodyForInspections(inspectionSnapshot.data ?? []);
          },
        );
      },
    );
  }
}

class InspectionSummaryPage extends StatefulWidget {
  final InspectionCase inspection;
  final VoidCallback onOpenChat;

  const InspectionSummaryPage({
    super.key,
    required this.inspection,
    required this.onOpenChat,
  });

  @override
  State<InspectionSummaryPage> createState() => _InspectionSummaryPageState();
}

class _InspectionSummaryPageState extends State<InspectionSummaryPage> {
  late InspectionCase inspection;
  bool isCheckingIn = false;

  @override
  void initState() {
    super.initState();
    inspection = widget.inspection;
  }

  Future<void> _registerCheckIn() async {
    if (inspection.checkInAt != null || isCheckingIn) return;

    setState(() {
      isCheckingIn = true;
    });

    final now = DateTime.now();
    final nowIso = now.toIso8601String();

    try {
      await FirebaseFirestore.instance
          .collection('sinistro')
          .doc(inspection.id)
          .update({
            'checkInAt': nowIso,
            'status': 'Em andamento',
            'statusVistoria': 'Check-in realizado',
            'statusUpdatedAt': nowIso,
          });

      if (!mounted) return;

      setState(() {
        inspection = inspection.copyWith(
          checkInAt: now,
          status: InspectionStatus.inProgress,
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Check-in realizado com sucesso.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (error) {
      debugPrint('Register check-in error: $error');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível realizar o check-in.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isCheckingIn = false;
        });
      }
    }
  }

  void _goToChat() {
    Navigator.of(context).pop();
    widget.onOpenChat();
  }

  @override
  Widget build(BuildContext context) {
    final hasCheckIn = inspection.checkInAt != null;

    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: SafeArea(
        child: Column(
          children: [
            _SummaryTopBar(
              inspection: inspection,
              onBack: () {
                Navigator.of(context).pop();
              },
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: [
                  _SummaryHeroCard(inspection: inspection),
                  const SizedBox(height: 14),
                  _SectionCard(
                    title: 'Dados do veículo',
                    icon: Icons.directions_car,
                    children: [
                      _InfoRow('Placa', inspection.vehicle.plate),
                      _InfoRow('Marca', inspection.vehicle.brand),
                      _InfoRow('Modelo', inspection.vehicle.model),
                      _InfoRow('Ano', inspection.vehicle.year),
                      _InfoRow('Cor', inspection.vehicle.color),
                      _InfoRow('Chassi', inspection.vehicle.chassis),
                      _InfoRow('Renavam', inspection.vehicle.renavam),
                      _InfoRow('Combustível', inspection.vehicle.fuel),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    title: 'Dados do sinistro',
                    icon: Icons.car_crash,
                    children: [
                      _InfoRow('Protocolo', inspection.protocol),
                      _InfoRow('Seguradora', inspection.insurer),
                      _InfoRow('Tipo', inspection.claimType),
                      _InfoRow(
                        'Prioridade',
                        inspection.priority.label,
                        valueColor: inspection.priority.color,
                      ),
                      _InfoRow('Status', inspection.status.label),
                      _InfoRow(
                        'Agendamento',
                        _formatDateTime(inspection.scheduledDate),
                      ),
                      _InfoRow(
                        'Check-in',
                        hasCheckIn
                            ? _formatDateTime(inspection.checkInAt!)
                            : 'Ainda não realizado',
                        valueColor: hasCheckIn ? Colors.green : Colors.orange,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    title: 'Cliente',
                    icon: Icons.person,
                    children: [
                      _InfoRow('Nome', inspection.owner.name),
                      _InfoRow('Documento', inspection.owner.document),
                      _InfoRow('Telefone', inspection.owner.phone),
                      _InfoRow('E-mail', inspection.owner.email),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    title: 'Oficina credenciada',
                    icon: Icons.build,
                    children: [
                      _InfoRow('Oficina', inspection.workshop.name),
                      _InfoRow('Endereço', inspection.workshop.address),
                      _InfoRow('Telefone', inspection.workshop.phone),
                      if (inspection.workshop.email.isNotEmpty)
                        _InfoRow('E-mail', inspection.workshop.email),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _TextSectionCard(
                    title: 'Descrição inicial do dano',
                    icon: Icons.description,
                    text: inspection.damageDescription,
                  ),
                  const SizedBox(height: 14),
                  _TextSectionCard(
                    title: 'Orientações para a vistoria',
                    icon: Icons.checklist,
                    text: inspection.observations,
                  ),
                  const SizedBox(height: 14),
                  const _ChecklistCard(),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: hasCheckIn || isCheckingIn
                          ? null
                          : _registerCheckIn,
                      icon: isCheckingIn
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              hasCheckIn
                                  ? Icons.check_circle
                                  : Icons.login_rounded,
                            ),
                      label: Text(
                        isCheckingIn
                            ? 'Realizando check-in...'
                            : hasCheckIn
                            ? 'Check-in realizado às ${_formatTime(inspection.checkInAt!)}'
                            : 'Realizar check-in do veículo',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: hasCheckIn
                            ? Colors.green
                            : const Color(0xFF0057C0),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: hasCheckIn
                            ? Colors.green
                            : const Color(0xFF0057C0),
                        disabledForegroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 54,
                    child: OutlinedButton.icon(
                      onPressed: _goToChat,
                      icon: const Icon(Icons.smart_toy),
                      label: const Text('Iniciar coleta no Chat IA'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF0057C0),
                        backgroundColor: const Color(0xFFE5F6FF),
                        side: BorderSide(color: Colors.black.withOpacity(.05)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InspectionsHeader extends StatelessWidget {
  final int total;
  final int pending;
  final int inProgress;
  final int checkedIn;

  const _InspectionsHeader({
    required this.total,
    required this.pending,
    required this.inProgress,
    required this.checkedIn,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.85),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vistorias',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF0057C0),
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Painel de ocorrências atribuídas',
                      style: TextStyle(
                        color: Color(0xFF414755),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5F6FF),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '$total casos',
                  style: const TextStyle(
                    color: Color(0xFF0057C0),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _HeaderMiniCard(
                  label: 'Pendentes',
                  value: '$pending',
                  icon: Icons.schedule,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HeaderMiniCard(
                  label: 'Andamento',
                  value: '$inProgress',
                  icon: Icons.build_circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HeaderMiniCard(
                  label: 'Check-in',
                  value: '$checkedIn',
                  icon: Icons.login_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _HeaderMiniCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 78,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF7FD),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF0057C0)),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0057C0),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            softWrap: true,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.05,
              color: Color(0xFF414755),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectionCard extends StatelessWidget {
  final InspectionCase inspection;
  final VoidCallback onTap;

  const _InspectionCard({required this.inspection, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasCheckIn = inspection.checkInAt != null;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.black.withOpacity(.05)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.03),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5F6FF),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.directions_car,
                      color: Color(0xFF0057C0),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          inspection.vehicle.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1F2937),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${inspection.vehicle.plate} • ${inspection.claimType}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF414755),
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF0057C0)),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _StatusChip(
                    label: inspection.status.label,
                    color: inspection.status.color,
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(
                    label: inspection.priority.label,
                    color: inspection.priority.color,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.business,
                    size: 15,
                    color: Color(0xFF414755),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      inspection.insurer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF414755),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    hasCheckIn ? Icons.check_circle : Icons.schedule,
                    size: 15,
                    color: hasCheckIn ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasCheckIn
                        ? 'Check-in ${_formatTime(inspection.checkInAt!)}'
                        : _formatTime(inspection.scheduledDate),
                    style: TextStyle(
                      color: hasCheckIn ? Colors.green : Colors.orange,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryTopBar extends StatelessWidget {
  final InspectionCase inspection;
  final VoidCallback onBack;

  const _SummaryTopBar({required this.inspection, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.90),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            color: const Color(0xFF0057C0),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Sumário do Sinistro',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 21,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0057C0),
              ),
            ),
          ),
          _StatusChip(
            label: inspection.status.label,
            color: inspection.status.color,
          ),
        ],
      ),
    );
  }
}

class _SummaryHeroCard extends StatelessWidget {
  final InspectionCase inspection;

  const _SummaryHeroCard({required this.inspection});

  @override
  Widget build(BuildContext context) {
    final hasCheckIn = inspection.checkInAt != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0057C0), Color(0xFF0474FB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0057C0).withOpacity(.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.18),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.directions_car, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inspection.vehicle.model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${inspection.vehicle.plate} • ${inspection.vehicle.color}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(.82),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniHeroTag(label: 'Prot.', value: inspection.protocol),
                    _MiniHeroTag(
                      label: 'Check-in',
                      value: hasCheckIn
                          ? _formatTime(inspection.checkInAt!)
                          : 'Pendente',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniHeroTag extends StatelessWidget {
  final String label;
  final String value;

  const _MiniHeroTag({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(
                color: Colors.white.withOpacity(.72),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Column(
        children: [
          _SectionTitle(title: title, icon: icon),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _TextSectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String text;

  const _TextSectionCard({
    required this.title,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(title: title, icon: icon),
          const SizedBox(height: 10),
          Text(
            text.isEmpty ? 'Não informado.' : text,
            style: const TextStyle(
              color: Color(0xFF414755),
              height: 1.4,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistCard extends StatelessWidget {
  const _ChecklistCard();

  @override
  Widget build(BuildContext context) {
    final items = [
      'Conferir placa e chassi',
      'Registrar hodômetro',
      'Fotografar frente, traseira e laterais',
      'Fotografar dano em detalhe',
      'Gravar relato técnico',
      'Enviar evidências para análise',
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(
            title: 'Checklist sugerido',
            icon: Icons.checklist,
          ),
          const SizedBox(height: 10),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: Color(0xFF0057C0),
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item,
                      style: const TextStyle(
                        color: Color(0xFF414755),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionTitle({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF0057C0), size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: GoogleFonts.spaceGrotesk(
              color: const Color(0xFF0057C0),
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    final safeValue = value.trim().isEmpty ? 'Não informado' : value.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 102,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              safeValue,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valueColor ?? const Color(0xFF1F2937),
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StateMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: const Color(0xFF0057C0)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 21,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0057C0),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF414755),
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh),
                label: Text(actionLabel!),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0057C0),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
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
  });

  factory InspectionCase.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();

    final clienteSnapshot = _asStringMap(data['clienteSnapshot']);
    final veiculoSnapshot = _asStringMap(data['veiculoSnapshot']);
    final credenciadoSnapshot = _asStringMap(data['credenciadoSnapshot']);
    final seguradoraSnapshot = _asStringMap(data['seguradoraSnapshot']);

    final scheduledDate =
        _parseDateTime(data['scheduledDate']) ??
        _parseDateTime(data['entryDate']) ??
        DateTime.now();

    return InspectionCase(
      id: doc.id,
      protocol: _stringValue(data['protocol'], fallback: doc.id),
      status: InspectionStatusX.fromFirestore(data['status']),
      priority: InspectionPriorityX.fromFirestore(data['priority']),
      insurer: _stringValue(
        seguradoraSnapshot['name'],
        fallback: _stringValue(data['insurer']),
      ),
      claimType: _stringValue(data['claimType'], fallback: 'Sinistro'),
      scheduledDate: scheduledDate,
      checkInAt: _parseDateTime(data['checkInAt']),
      vehicle: VehicleInfo.fromSnapshot(veiculoSnapshot, data),
      owner: OwnerInfo.fromSnapshot(clienteSnapshot, data),
      workshop: WorkshopInfo.fromSnapshot(credenciadoSnapshot, data),
      damageDescription: _stringValue(data['damageDescription']),
      observations: _stringValue(data['observations']),
    );
  }

  InspectionCase copyWith({InspectionStatus? status, DateTime? checkInAt}) {
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
    );
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
    final brand = _stringValue(snapshot['marca']);
    final modelBase = _stringValue(
      snapshot['modelo'],
      fallback: _stringValue(root['vehicle']),
    );

    final model = _buildVehicleModel(brand, modelBase);

    return VehicleInfo(
      plate: _stringValue(
        snapshot['placa'],
        fallback: _stringValue(root['plate']),
      ),
      model: model,
      brand: brand,
      year: _stringValue(
        snapshot['anoFabricacao'],
        fallback: _stringValue(snapshot['ano']),
      ),
      color: _stringValue(snapshot['cor']),
      chassis: _stringValue(snapshot['chassi']),
      renavam: _stringValue(snapshot['renavam']),
      fuel: _stringValue(snapshot['combustivel']),
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
      name: _stringValue(
        snapshot['nomeCompleto'],
        fallback: _stringValue(root['owner']),
      ),
      document: _stringValue(snapshot['cpfCnpj']),
      phone: _stringValue(snapshot['telefone']),
      email: _stringValue(snapshot['email']),
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
      name: _stringValue(
        snapshot['name'],
        fallback: _stringValue(root['workshop']),
      ),
      address: address,
      phone: _stringValue(snapshot['phone']),
      email: _stringValue(snapshot['email']),
    );
  }
}

class _CredenciadoContext {
  final String uid;
  final String credenciadoId;
  final String credenciadoName;

  const _CredenciadoContext({
    required this.uid,
    required this.credenciadoId,
    required this.credenciadoName,
  });
}

class _InspectionAccessException implements Exception {
  final String title;
  final String message;

  const _InspectionAccessException({
    required this.title,
    required this.message,
  });
}

enum InspectionStatus {
  pending,
  inProgress,
  submitted,
  approved,
  rejected,
  cancelled,
}

extension InspectionStatusX on InspectionStatus {
  static InspectionStatus fromFirestore(dynamic value) {
    final normalized = _normalizeStatus(value);

    if (normalized.contains('andamento') ||
        normalized.contains('checkin') ||
        normalized.contains('check_in') ||
        normalized.contains('in_progress')) {
      return InspectionStatus.inProgress;
    }

    if (normalized.contains('enviada') ||
        normalized.contains('submitted') ||
        normalized.contains('analise') ||
        normalized.contains('review')) {
      return InspectionStatus.submitted;
    }

    if (normalized.contains('aprovada') ||
        normalized.contains('aprovado') ||
        normalized.contains('approved')) {
      return InspectionStatus.approved;
    }

    if (normalized.contains('rejeitada') ||
        normalized.contains('rejeitado') ||
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
        return 'Enviada';
      case InspectionStatus.approved:
        return 'Aprovada';
      case InspectionStatus.rejected:
        return 'Rejeitada';
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
      case InspectionStatus.cancelled:
        return Colors.grey;
    }
  }
}

enum InspectionPriority { low, medium, high }

extension InspectionPriorityX on InspectionPriority {
  static InspectionPriority fromFirestore(dynamic value) {
    final normalized = _normalizeStatus(value);

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

Map<String, dynamic> _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }

  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  return <String, dynamic>{};
}

String _stringValue(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;

  final text = value.toString().trim();

  if (text.isEmpty) return fallback;

  return text;
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;

  if (value is Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  final text = value.toString().trim();

  if (text.isEmpty || text.toLowerCase() == 'null') {
    return null;
  }

  return DateTime.tryParse(text);
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
  final address = _stringValue(snapshot['address']);
  final city = _stringValue(snapshot['city']);
  final uf = _stringValue(snapshot['uf']);

  if (address.isEmpty && city.isEmpty && uf.isEmpty) {
    return '';
  }

  final cityUf = [city, uf].where((item) => item.trim().isNotEmpty).join('/');

  if (address.isEmpty) return cityUf;
  if (cityUf.isEmpty) return address;

  return '$address - $cityUf';
}

String _normalizeStatus(dynamic value) {
  return _stringValue(value)
      .toLowerCase()
      .replaceAll('ã', 'a')
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('â', 'a')
      .replaceAll('é', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ô', 'o')
      .replaceAll('õ', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c')
      .trim();
}

String _formatDateTime(DateTime dateTime) {
  final day = dateTime.day.toString().padLeft(2, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final year = dateTime.year.toString();
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');

  return '$day/$month/$year às $hour:$minute';
}

String _formatTime(DateTime dateTime) {
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');

  return '$hour:$minute';
}

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class InspectionsPage extends StatefulWidget {
  final VoidCallback onOpenInspection;

  const InspectionsPage({super.key, required this.onOpenInspection});

  @override
  State<InspectionsPage> createState() => _InspectionsPageState();
}

class _InspectionsPageState extends State<InspectionsPage> {
  final List<InspectionCase> inspections = [
    InspectionCase(
      id: 'INS-001',
      protocol: 'ARG-2026-0001',
      status: InspectionStatus.pending,
      priority: InspectionPriority.high,
      insurer: 'FHO Seguros',
      claimType: 'Colisão dianteira',
      scheduledDate: DateTime(2026, 3, 24, 9, 30),
      vehicle: const VehicleInfo(
        plate: 'ABC-1234',
        model: 'Toyota Corolla XEI',
        brand: 'Toyota',
        year: '2021/2022',
        color: 'Prata',
        chassis: '9BRBLWHE9N0123456',
        renavam: '01234567890',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Carlos Henrique Silva',
        document: '***.456.789-**',
        phone: '(19) 99999-1234',
      ),
      workshop: const WorkshopInfo(
        name: 'Centro Automotivo Delta',
        address: 'Av. Dona Renata, 1200 - Araras/SP',
        responsibleMechanic: 'Lucas Fernandes',
      ),
      damageDescription:
          'Veículo encaminhado para vistoria após colisão frontal. Há indícios de avaria em para-choque, capô, grade frontal e conjunto óptico dianteiro.',
      observations:
          'Necessário registrar imagens externas, identificação do veículo, hodômetro e possíveis danos estruturais aparentes.',
    ),
    InspectionCase(
      id: 'INS-002',
      protocol: 'ARG-2026-0002',
      status: InspectionStatus.pending,
      priority: InspectionPriority.medium,
      insurer: 'Seguradora Atlas',
      claimType: 'Dano lateral',
      scheduledDate: DateTime(2026, 3, 24, 14, 0),
      vehicle: const VehicleInfo(
        plate: 'DEF-5678',
        model: 'Honda Civic Touring',
        brand: 'Honda',
        year: '2020/2020',
        color: 'Preto',
        chassis: '93HFC1670LZ123456',
        renavam: '98765432100',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Mariana Costa Almeida',
        document: '***.222.333-**',
        phone: '(19) 98888-4567',
      ),
      workshop: const WorkshopInfo(
        name: 'Oficina Prime Motors',
        address: 'Rua das Palmeiras, 845 - Limeira/SP',
        responsibleMechanic: 'André Oliveira',
      ),
      damageDescription:
          'Vistoria solicitada para análise de avarias na lateral direita, com possível comprometimento de porta dianteira e retrovisor.',
      observations:
          'Registrar fotos em ângulo aberto e detalhado. Conferir alinhamento das portas e presença de danos internos.',
    ),
    InspectionCase(
      id: 'INS-003',
      protocol: 'ARG-2026-0003',
      status: InspectionStatus.inProgress,
      priority: InspectionPriority.low,
      insurer: 'Protege Auto',
      claimType: 'Dano traseiro',
      scheduledDate: DateTime(2026, 3, 25, 10, 15),
      checkInAt: DateTime(2026, 3, 25, 10, 4),
      vehicle: const VehicleInfo(
        plate: 'GHI-9012',
        model: 'Chevrolet Onix LTZ',
        brand: 'Chevrolet',
        year: '2022/2023',
        color: 'Branco',
        chassis: '9BGEB69H0PG123456',
        renavam: '11223344556',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Rafael Moreira Santos',
        document: '***.789.111-**',
        phone: '(19) 97777-8910',
      ),
      workshop: const WorkshopInfo(
        name: 'Auto Center Horizonte',
        address: 'Av. Independência, 430 - Rio Claro/SP',
        responsibleMechanic: 'Bruno Martins',
      ),
      damageDescription:
          'Sinistro com impacto traseiro. Possível avaria em tampa do porta-malas, para-choque traseiro e sensores de estacionamento.',
      observations:
          'Veículo já realizou check-in. Coleta de evidências pendente.',
    ),
    InspectionCase(
      id: 'INS-004',
      protocol: 'ARG-2026-0004',
      status: InspectionStatus.pending,
      priority: InspectionPriority.high,
      insurer: 'UniCar Seguros',
      claimType: 'Perda de alinhamento',
      scheduledDate: DateTime(2026, 3, 25, 13, 40),
      vehicle: const VehicleInfo(
        plate: 'JKL-3456',
        model: 'Volkswagen T-Cross Comfortline',
        brand: 'Volkswagen',
        year: '2023/2023',
        color: 'Cinza',
        chassis: '9BWAG45U8PP098765',
        renavam: '22334455667',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Juliana Prado',
        document: '***.114.552-**',
        phone: '(19) 99661-7788',
      ),
      workshop: const WorkshopInfo(
        name: 'Mecânica São Cristóvão',
        address: 'Rua 13 de Maio, 221 - Piracicaba/SP',
        responsibleMechanic: 'Eduardo Rocha',
      ),
      damageDescription:
          'Veículo com relato de impacto em roda dianteira esquerda, acompanhado de desalinhamento e ruídos em suspensão.',
      observations:
          'Verificar rodas, suspensão, terminal de direção e possível comprometimento estrutural leve.',
    ),
    InspectionCase(
      id: 'INS-005',
      protocol: 'ARG-2026-0005',
      status: InspectionStatus.pending,
      priority: InspectionPriority.medium,
      insurer: 'Max Proteção',
      claimType: 'Avaria em para-choque',
      scheduledDate: DateTime(2026, 3, 26, 8, 50),
      vehicle: const VehicleInfo(
        plate: 'MNO-7890',
        model: 'Hyundai HB20 Platinum',
        brand: 'Hyundai',
        year: '2021/2021',
        color: 'Azul',
        chassis: '9BHCP51BBMP765432',
        renavam: '33445566778',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Fernanda Lopes',
        document: '***.987.654-**',
        phone: '(19) 99111-2244',
      ),
      workshop: const WorkshopInfo(
        name: 'Garage Fast Repair',
        address: 'Rua Campos Sales, 98 - Campinas/SP',
        responsibleMechanic: 'Felipe Gomes',
      ),
      damageDescription:
          'Avaria aparente no para-choque dianteiro com desprendimento parcial e riscos generalizados.',
      observations:
          'Fotografar fixações, folgas entre peças e região inferior do conjunto frontal.',
    ),
    InspectionCase(
      id: 'INS-006',
      protocol: 'ARG-2026-0006',
      status: InspectionStatus.pending,
      priority: InspectionPriority.low,
      insurer: 'Liberty Proteção',
      claimType: 'Danos em porta e retrovisor',
      scheduledDate: DateTime(2026, 3, 26, 15, 20),
      vehicle: const VehicleInfo(
        plate: 'PQR-2468',
        model: 'Fiat Pulse Audace',
        brand: 'Fiat',
        year: '2024/2024',
        color: 'Vermelho',
        chassis: '9BD12345TRX456789',
        renavam: '44556677889',
        fuel: 'Flex',
      ),
      owner: const OwnerInfo(
        name: 'Thiago Nascimento',
        document: '***.741.258-**',
        phone: '(19) 99441-5500',
      ),
      workshop: const WorkshopInfo(
        name: 'Oficina Nova Linha',
        address: 'Av. Brasil, 1550 - Americana/SP',
        responsibleMechanic: 'Renato Souza',
      ),
      damageDescription:
          'Danos leves em porta dianteira esquerda e retrovisor, sem relato de comprometimento estrutural.',
      observations:
          'Registrar detalhes da carenagem do retrovisor, vincos e pontos de pintura afetados.',
    ),
  ];

  Future<void> _openInspectionSummary(int index) async {
    final updatedInspection = await Navigator.of(context).push<InspectionCase>(
      MaterialPageRoute(
        builder: (_) => InspectionSummaryPage(
          inspection: inspections[index],
          onOpenChat: widget.onOpenInspection,
        ),
      ),
    );

    if (updatedInspection == null) return;

    setState(() {
      inspections[index] = updatedInspection;
    });
  }

  @override
  Widget build(BuildContext context) {
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
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: inspections.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final inspection = inspections[index];

                return _InspectionCard(
                  inspection: inspection,
                  onTap: () => _openInspectionSummary(index),
                );
              },
            ),
          ),
        ],
      ),
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

  @override
  void initState() {
    super.initState();
    inspection = widget.inspection;
  }

  void _registerCheckIn() {
    if (inspection.checkInAt != null) return;

    setState(() {
      inspection = inspection.copyWith(
        checkInAt: DateTime.now(),
        status: InspectionStatus.inProgress,
      );
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Check-in realizado com sucesso.'),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _goToChat() {
    Navigator.of(context).pop(inspection);
    widget.onOpenChat();
  }

  @override
  Widget build(BuildContext context) {
    final hasCheckIn = inspection.checkInAt != null;

    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(inspection);
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3FBFF),
        body: SafeArea(
          child: Column(
            children: [
              _SummaryTopBar(
                inspection: inspection,
                onBack: () {
                  Navigator.of(context).pop(inspection);
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
                      ],
                    ),

                    const SizedBox(height: 14),

                    _SectionCard(
                      title: 'Oficina credenciada',
                      icon: Icons.build,
                      children: [
                        _InfoRow('Oficina', inspection.workshop.name),
                        _InfoRow('Endereço', inspection.workshop.address),
                        _InfoRow(
                          'Responsável',
                          inspection.workshop.responsibleMechanic,
                        ),
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
                        onPressed: hasCheckIn ? null : _registerCheckIn,
                        icon: Icon(
                          hasCheckIn ? Icons.check_circle : Icons.login_rounded,
                        ),
                        label: Text(
                          hasCheckIn
                              ? 'Check-in realizado às ${_formatTime(inspection.checkInAt!)}'
                              : 'Realizar check-in do veículo',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: hasCheckIn
                              ? Colors.green
                              : const Color(0xFF0057C0),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.green,
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
                          side: BorderSide(
                            color: Colors.black.withOpacity(.05),
                          ),
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
            text,
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
              value,
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
}

class OwnerInfo {
  final String name;
  final String document;
  final String phone;

  const OwnerInfo({
    required this.name,
    required this.document,
    required this.phone,
  });
}

class WorkshopInfo {
  final String name;
  final String address;
  final String responsibleMechanic;

  const WorkshopInfo({
    required this.name,
    required this.address,
    required this.responsibleMechanic,
  });
}

enum InspectionStatus { pending, inProgress, submitted, approved }

extension InspectionStatusExtension on InspectionStatus {
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
    }
  }
}

enum InspectionPriority { low, medium, high }

extension InspectionPriorityExtension on InspectionPriority {
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

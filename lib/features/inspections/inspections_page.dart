import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class InspectionsPage extends StatelessWidget {
  final VoidCallback onOpenInspection;

  const InspectionsPage({super.key, required this.onOpenInspection});

  @override
  Widget build(BuildContext context) {
    final inspections = [
      _InspectionItem(
        car: 'Toyota Hilux',
        plate: 'ABC-1234',
        status: 'Em andamento',
        time: 'Iniciada às 09:30',
        icon: Icons.access_time,
        active: true,
      ),
      _InspectionItem(
        car: 'Volkswagen Amarok',
        plate: 'KJH-8829',
        status: 'Aguardando',
        time: 'Agendada para 14:00',
        icon: Icons.history,
        active: false,
      ),
      _InspectionItem(
        car: 'Ford Ranger',
        plate: 'PLM-4512',
        status: 'Em andamento',
        time: 'Checklist 85% concluído',
        icon: Icons.description,
        active: true,
      ),
      _InspectionItem(
        car: 'Mitsubishi L200',
        plate: 'XYZ-9090',
        status: 'Pausada',
        time: 'Aguardando peças',
        icon: Icons.warning_amber_rounded,
        active: false,
        alert: true,
      ),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(title: 'Argos'),
            const SizedBox(height: 32),
            Text(
              'Minhas vistorias',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 34,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '4 vistorias ativas hoje',
              style: TextStyle(
                color: Color(0xFF414755),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 28),
            ...inspections.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _InspectionCard(item: item, onTap: onOpenInspection),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.add),
                label: const Text('Nova Vistoria'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0057C0),
                  backgroundColor: const Color(0xFFE5F6FF),
                  side: BorderSide(color: Colors.black.withOpacity(.05)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InspectionItem {
  final String car;
  final String plate;
  final String status;
  final String time;
  final IconData icon;
  final bool active;
  final bool alert;

  const _InspectionItem({
    required this.car,
    required this.plate,
    required this.status,
    required this.time,
    required this.icon,
    required this.active,
    this.alert = false,
  });
}

class _InspectionCard extends StatelessWidget {
  final _InspectionItem item;
  final VoidCallback onTap;

  const _InspectionCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final statusColor = item.active
        ? const Color(0xFF0057C0)
        : Colors.grey.shade300;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.black.withOpacity(.04)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.04),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
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
                        item.car.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFF0057C0),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.plate,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    item.status.toUpperCase(),
                    style: TextStyle(
                      color: item.active ? Colors.white : Colors.black54,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Icon(
                  item.icon,
                  size: 18,
                  color: item.alert ? Colors.redAccent : Colors.black38,
                ),
                const SizedBox(width: 8),
                Text(
                  item.time,
                  style: TextStyle(
                    color: item.alert ? Colors.redAccent : Colors.black45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;

  const _Header({required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.menu, color: Color(0xFF0057C0)),
        const SizedBox(width: 14),
        Text(
          title,
          style: GoogleFonts.spaceGrotesk(
            color: const Color(0xFF0057C0),
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

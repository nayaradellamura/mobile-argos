import 'package:flutter/material.dart';

class ArgosBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const ArgosBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      _ArgosNavItem(icon: Icons.assignment_turned_in, label: 'Vistorias'),
      _ArgosNavItem(icon: Icons.smart_toy, label: 'Chat IA'),
      _ArgosNavItem(icon: Icons.camera_alt, label: 'Câmera'),
      _ArgosNavItem(icon: Icons.person, label: 'Perfil'),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.08),
            blurRadius: 28,
            offset: const Offset(0, -8),
          ),
        ],
        border: Border(top: BorderSide(color: Colors.black.withOpacity(.05))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(items.length, (index) {
          final item = items[index];
          final isActive = currentIndex == index;

          return GestureDetector(
            onTap: () => onTap(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              padding: EdgeInsets.symmetric(
                horizontal: isActive ? 18 : 10,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFFE5F6FF) : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.icon,
                    color: isActive
                        ? const Color(0xFF0057C0)
                        : const Color(0xFF414755).withOpacity(.45),
                    size: 24,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.2,
                      color: isActive
                          ? const Color(0xFF0057C0)
                          : const Color(0xFF414755).withOpacity(.45),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ArgosNavItem {
  final IconData icon;
  final String label;

  const _ArgosNavItem({required this.icon, required this.label});
}

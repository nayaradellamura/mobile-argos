import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../features/inspections/inspections_page.dart';
import '../features/ai_chat/ai_chat_page.dart';
import '../features/profile/profile_page.dart';

class MainShell extends StatefulWidget {
  final User user;

  const MainShell({super.key, required this.user});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int selectedIndex = 0;

  late final List<Widget> pages = [
    InspectionsPage(
      onOpenInspection: () {
        setState(() {
          selectedIndex = 1;
        });
      },
    ),
    const AiChatPage(),
    ProfilePage(user: widget.user),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: _ArgosBottomNav(
        currentIndex: selectedIndex,
        onTap: (index) {
          setState(() {
            selectedIndex = index;
          });
        },
      ),
    );
  }
}

class _ArgosBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _ArgosBottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = [
      _NavItem(icon: Icons.assignment_turned_in, label: 'Vistorias'),
      _NavItem(icon: Icons.smart_toy, label: 'Chat IA'),
      _NavItem(icon: Icons.person, label: 'Perfil'),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: Colors.black.withOpacity(.05))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.08),
            blurRadius: 28,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (index) {
            final item = items[index];
            final isActive = currentIndex == index;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: EdgeInsets.symmetric(
                  horizontal: isActive ? 20 : 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFFE5F6FF)
                      : Colors.transparent,
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
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem({required this.icon, required this.label});
}

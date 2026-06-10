import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../features/inspections/inspections_page.dart';
import '../features/ai_chat/ai_chat_page.dart';
import '../features/profile/profile_page.dart';
import '../services/argos_push_notification_service.dart';

class MainShell extends StatefulWidget {
  final User user;

  /// Recebido do StartupGate para evitar segunda SplashPage/loading.
  final bool? initialProfileCompletionRequired;

  const MainShell({
    super.key,
    required this.user,
    this.initialProfileCompletionRequired,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int selectedIndex = 0;
  VoidCallback? _notificationOpenListener;

  bool isLoadingProfile = true;
  bool profileCompletionRequired = false;

  /// Guarda o sinistro selecionado quando o usuário abre o Chat IA
  /// a partir do botão dentro do sumário da vistoria.
  String? selectedSinistroIdForChat;
  String? notificationSinistroIdToOpen;

  String get _emailKey => (widget.user.email ?? '').trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _notificationOpenListener = _handleNotificationSinistroOpened;
    ArgosPushNotificationService.instance.openedSinistroId.addListener(
      _notificationOpenListener!,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleNotificationSinistroOpened();
    });

    final initialProfileCompletionRequired =
        widget.initialProfileCompletionRequired;

    if (initialProfileCompletionRequired != null) {
      profileCompletionRequired = initialProfileCompletionRequired;
      selectedIndex = initialProfileCompletionRequired ? 2 : 0;
      isLoadingProfile = false;
      return;
    }

    _loadProfileCompletionStatus();
  }

  @override
  void dispose() {
    final listener = _notificationOpenListener;

    if (listener != null) {
      ArgosPushNotificationService.instance.openedSinistroId
          .removeListener(listener);
    }

    super.dispose();
  }

  Future<void> _loadProfileCompletionStatus() async {
    final email = _emailKey;

    if (email.isEmpty) {
      if (!mounted) return;

      setState(() {
        isLoadingProfile = false;
        profileCompletionRequired = true;
        selectedIndex = 2;
      });

      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(email)
          .get();

      final data = doc.data();
      final isComplete = data?['cadastroCompleto'] == true;

      if (!mounted) return;

      setState(() {
        profileCompletionRequired = !isComplete;
        selectedIndex = isComplete ? 0 : 2;
        isLoadingProfile = false;
      });
    } catch (e) {
      debugPrint('Profile completion check error: $e');

      if (!mounted) return;

      setState(() {
        profileCompletionRequired = true;
        selectedIndex = 2;
        isLoadingProfile = false;
      });
    }
  }

  void _handleProfileCompleted() {
    setState(() {
      profileCompletionRequired = false;
      selectedIndex = 0;
    });
  }

  void _handleNotificationSinistroOpened() {
    final sinistroId =
        ArgosPushNotificationService.instance.openedSinistroId.value?.trim() ??
            '';

    if (sinistroId.isEmpty || !mounted) return;

    ArgosPushNotificationService.instance.clearOpenedSinistroId();

    if (profileCompletionRequired) {
      setState(() => selectedIndex = 2);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Finalize seu cadastro para abrir a vistoria.'),
          backgroundColor: Color(0xFF0057C0),
        ),
      );
      return;
    }

    setState(() {
      selectedIndex = 0;
      selectedSinistroIdForChat = null;
      notificationSinistroIdToOpen = sinistroId;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Notificação recebida para o sinistro $sinistroId.'),
        backgroundColor: const Color(0xFF0057C0),
      ),
    );
  }

  void _handleNavTap(int index) {
    if (profileCompletionRequired && index != 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Finalize seu cadastro para continuar.'),
          backgroundColor: Color(0xFF0057C0),
        ),
      );

      setState(() {
        selectedIndex = 2;
      });

      return;
    }

    setState(() {
      selectedIndex = index;

      /// Se o usuário tocar manualmente no Chat IA pela barra inferior,
      /// abre o chat sem sinistro selecionado, mostrando a lista de placas.
      if (index == 1) {
        selectedSinistroIdForChat = null;
      }
    });
  }

  void _openGenericChat() {
    if (profileCompletionRequired) {
      _handleNavTap(1);
      return;
    }

    setState(() {
      selectedSinistroIdForChat = null;
      selectedIndex = 1;
    });
  }

  void _openChatForSinistro(String sinistroId) {
    if (profileCompletionRequired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Finalize seu cadastro para continuar.'),
          backgroundColor: Color(0xFF0057C0),
        ),
      );

      setState(() {
        selectedIndex = 2;
      });

      return;
    }

    setState(() {
      selectedSinistroIdForChat = sinistroId;
      selectedIndex = 1;
    });
  }

  List<Widget> get pages {
    return [
      InspectionsPage(
        onOpenInspection: _openGenericChat,
        onOpenInspectionById: _openChatForSinistro,
        notificationSinistroIdToOpen: notificationSinistroIdToOpen,
      ),

      /// O ValueKey força o Flutter a reconstruir o chat quando outro
      /// sinistro for selecionado.
      AiChatPage(
        key: ValueKey(selectedSinistroIdForChat ?? 'chat_sem_sinistro'),
        sinistroId: selectedSinistroIdForChat,
      ),

      ProfilePage(
        user: widget.user,
        requireCompletion: profileCompletionRequired,
        onProfileCompleted: _handleProfileCompleted,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingProfile) {
      // Fallback para uso fora do StartupGate. No fluxo normal, o StartupGate
      // já entrega initialProfileCompletionRequired e este bloco não aparece.
      return const SizedBox.expand();
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: _ArgosBottomNav(
        currentIndex: selectedIndex,
        completionRequired: profileCompletionRequired,
        onTap: _handleNavTap,
      ),
    );
  }
}

class _ArgosBottomNav extends StatelessWidget {
  final int currentIndex;
  final bool completionRequired;
  final ValueChanged<int> onTap;

  const _ArgosBottomNav({
    required this.currentIndex,
    required this.completionRequired,
    required this.onTap,
  });

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
            final isLocked = completionRequired && index != 2;

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
                child: Opacity(
                  opacity: isLocked ? .35 : 1,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isLocked ? Icons.lock_outline : item.icon,
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

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';

import '../features/inspections/inspections_page.dart';
import '../features/ai_chat/ai_chat_page.dart';
import '../features/profile/profile_page.dart';
import '../services/argos_push_notification_service.dart';
import '../services/session_context_service.dart';

/// Shell principal do app: navegação por abas (Vistorias, Chat IA, Perfil).
class MainShell extends StatefulWidget {
  final User user;

  // Recebido do StartupGate pra pular a checagem de perfil duplicada.
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

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _accountStatusSubscription;
  bool _accountBlockedDialogShown = false;

  // Sinistro selecionado quando o Chat IA é aberto a partir do sumário da vistoria.
  String? selectedSinistroIdForChat;
  String? notificationSinistroIdToOpen;

  // true quando o chat foi aberto pelo botão "Iniciar Retificação".
  bool selectedRetificacaoForChat = false;

  // Força reconstrução do AiChatPage mesmo reabrindo o mesmo sinistroId.
  int _chatRequestNonce = 0;

  // Notifica o AiChatPage de qual aba está selecionada, sem invalidar o cache de `pages`.
  final ValueNotifier<int> _selectedIndexNotifier = ValueNotifier<int>(0);

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

    _watchAccountStatus();

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

    _accountStatusSubscription?.cancel();
    _selectedIndexNotifier.dispose();

    super.dispose();
  }

  /// Escuta em tempo real o status do usuário e mostra o bloqueio se a conta sair de "ativo".
  void _watchAccountStatus() {
    final email = _emailKey;

    if (email.isEmpty) return;

    _accountStatusSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(email)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted || _accountBlockedDialogShown) return;

        final status = snapshot.data()?['status']?.toString() ?? '';

        if (status.isNotEmpty && status != 'ativo') {
          _showAccountBlockedDialog(status);
        }
      },
      onError: (error) {
        debugPrint('Account status watch error: $error');
      },
    );
  }

  /// Mostra o diálogo de conta bloqueada/pendente e desloga ao confirmar.
  Future<void> _showAccountBlockedDialog(String status) async {
    _accountBlockedDialogShown = true;
    _accountStatusSubscription?.cancel();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: _AccountBlockedDialog(
            status: status,
            onAcknowledge: () {
              Navigator.of(dialogContext).pop();
              SessionContextService.instance.logout();
            },
          ),
        );
      },
    );
  }

  /// Busca no Firestore se o cadastro do usuário está completo e ajusta a aba inicial.
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

  /// Libera a navegação normal assim que o cadastro é concluído.
  void _handleProfileCompleted() {
    setState(() {
      profileCompletionRequired = false;
      selectedIndex = 0;
    });
  }

  /// Abre a aba de vistorias no sinistro indicado por uma notificação recebida.
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
        content: const Text('Nova atualização em uma vistoria. Abrindo...'),
        backgroundColor: const Color(0xFF0057C0),
      ),
    );
  }

  /// Troca de aba pelo tap na barra inferior, bloqueando se o cadastro estiver pendente.
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

      if (index == 1) {
        selectedSinistroIdForChat = null;
      }
    });
  }

  /// Abre o Chat IA sem nenhum sinistro pré-selecionado.
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

  /// Abre o Chat IA já com o sinistro selecionado, no modo normal de vistoria.
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
      selectedRetificacaoForChat = false;
      selectedIndex = 1;
      _chatRequestNonce++;
    });
  }

  /// Abre o Chat IA já com o sinistro selecionado, direto no modo retificação.
  void _openRetificacaoForSinistro(String sinistroId) {
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
      selectedRetificacaoForChat = true;
      selectedIndex = 1;
      _chatRequestNonce++;
    });
  }

  List<Widget>? _cachedPages;
  String? _cachedPagesSinistroKey;
  String? _cachedPagesNotificationSinistroId;
  bool? _cachedPagesProfileCompletionRequired;
  bool? _cachedPagesRetificacao;
  int? _cachedChatRequestNonce;

  /// Monta (e cacheia) as 3 páginas do IndexedStack, só recriando quando algo relevante muda.
  List<Widget> get pages {
    final needsRebuild = _cachedPages == null ||
        _cachedPagesSinistroKey != selectedSinistroIdForChat ||
        _cachedPagesNotificationSinistroId != notificationSinistroIdToOpen ||
        _cachedPagesProfileCompletionRequired != profileCompletionRequired ||
        _cachedPagesRetificacao != selectedRetificacaoForChat ||
        _cachedChatRequestNonce != _chatRequestNonce;

    if (!needsRebuild) return _cachedPages!;

    _cachedPagesSinistroKey = selectedSinistroIdForChat;
    _cachedPagesNotificationSinistroId = notificationSinistroIdToOpen;
    _cachedPagesProfileCompletionRequired = profileCompletionRequired;
    _cachedPagesRetificacao = selectedRetificacaoForChat;
    _cachedChatRequestNonce = _chatRequestNonce;

    _cachedPages = [
      InspectionsPage(
        onOpenInspection: _openGenericChat,
        onOpenInspectionById: _openChatForSinistro,
        onStartRetificacaoById: _openRetificacaoForSinistro,
        notificationSinistroIdToOpen: notificationSinistroIdToOpen,
      ),

      AiChatPage(
        key: ValueKey(
          '${selectedSinistroIdForChat ?? 'chat_sem_sinistro'}_${selectedRetificacaoForChat ? 'retificacao' : 'normal'}_$_chatRequestNonce',
        ),
        sinistroId: selectedSinistroIdForChat,
        startRetificacao: selectedRetificacaoForChat,
        selectedTabIndexListenable: _selectedIndexNotifier,
        onGoToInspections: () => setState(() => selectedIndex = 0),
      ),

      ProfilePage(
        user: widget.user,
        requireCompletion: profileCompletionRequired,
        onProfileCompleted: _handleProfileCompleted,
      ),
    ];

    return _cachedPages!;
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingProfile) {
      return const Scaffold(
        backgroundColor: Color(0xFFF3FBFF),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    _selectedIndexNotifier.value = selectedIndex;

    // Com o teclado aberto a barra de navegação ficava em cima dele e
    // sobrava pouco espaço para a conversa no chat.
    final tecladoAberto = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: tecladoAberto
          ? null
          : _ArgosBottomNav(
              currentIndex: selectedIndex,
              completionRequired: profileCompletionRequired,
              onTap: _handleNavTap,
            ),
    );
  }
}

/// Diálogo cheio mostrando que a conta está pendente de aprovação ou bloqueada.
class _AccountBlockedDialog extends StatelessWidget {
  final String status;
  final VoidCallback onAcknowledge;

  const _AccountBlockedDialog({
    required this.status,
    required this.onAcknowledge,
  });

  bool get _isPending => status == 'pendente';

  Color get _accentColor =>
      _isPending ? const Color(0xFFE8A400) : Colors.redAccent;

  IconData get _icon =>
      _isPending ? Icons.hourglass_top_rounded : Icons.lock_outline_rounded;

  String get _title => _isPending ? 'Acesso pendente' : 'Acesso bloqueado';

  String get _message => _isPending
      ? 'Seu acesso está pendente de aprovação pelo administrador.'
      : 'Seu acesso foi bloqueado pelo administrador.';

  String get _tip => _isPending
      ? 'Você será notificado assim que sua liberação for aprovada. Até lá, sua sessão será encerrada.'
      : 'Fale com o administrador da sua oficina ou com o suporte Argos para reativar seu acesso.';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.18),
              blurRadius: 40,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(.12),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: _accentColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _accentColor.withOpacity(.35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(_icon, color: Colors.white, size: 28),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF414755),
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAFC),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.black.withOpacity(.04)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.tips_and_updates_outlined,
                    color: _accentColor,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _tip,
                      textAlign: TextAlign.left,
                      style: const TextStyle(
                        color: Color(0xFF414755),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: onAcknowledge,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0057C0),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  'Entendi, sair da conta',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Barra de navegação inferior com os 3 ícones de aba (Vistorias, Argos IA, Perfil).
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
      _NavItem(icon: Icons.smart_toy, label: 'Argos IA'),
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

/// Par ícone + rótulo de um item da barra de navegação inferior.
class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem({required this.icon, required this.label});
}

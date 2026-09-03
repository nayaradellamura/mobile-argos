import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'data/mechanic_performance.dart';

class MetricsPage extends StatefulWidget {
  final String credenciadoId;

  const MetricsPage({super.key, required this.credenciadoId});

  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> {
  MetricsPeriod _period = MetricsPeriod.last30Days;
  DateTimeRange? _customRange;
  bool _showOnlyMine = false;
  late Future<List<MechanicPerformance>> _rankingFuture;

  // Incrementado a cada novo carregamento, para que uma atualização em
  // segundo plano de um pedido antigo (ex.: período trocado antes dela
  // voltar) seja ignorada em vez de sobrescrever a tela com dado errado.
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _rankingFuture = _load();
  }

  Future<List<MechanicPerformance>> _load() {
    final token = ++_loadToken;

    return MechanicPerformanceRepository.instance.loadRanking(
      credenciadoId: widget.credenciadoId,
      period: _period,
      customStart: _customRange?.start,
      customEnd: _customRange?.end,
      onBackgroundRefresh: (refreshed) {
        if (!mounted || token != _loadToken) return;

        setState(() {
          _rankingFuture = Future.value(refreshed);
        });
      },
    );
  }

  void _reload() {
    setState(() {
      _rankingFuture = _load();
    });
  }

  Future<void> _selectPeriod(MetricsPeriod period) async {
    if (period == MetricsPeriod.custom) {
      final now = DateTime.now();

      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 2),
        lastDate: now,
        initialDateRange: _customRange ??
            DateTimeRange(
              start: now.subtract(const Duration(days: 30)),
              end: now,
            ),
        builder: (context, child) {
          return Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.light(
                primary: Color(0xFF0057C0),
              ),
            ),
            child: child!,
          );
        },
      );

      if (picked == null) return;

      setState(() {
        _period = MetricsPeriod.custom;
        _customRange = picked;
      });

      _reload();
      return;
    }

    if (_period == period) return;

    setState(() {
      _period = period;
    });

    _reload();
  }

  String get _periodSubtitle {
    if (_period != MetricsPeriod.custom || _customRange == null) {
      return _period.label;
    }

    final start = _customRange!.start;
    final end = _customRange!.end;

    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${twoDigits(start.day)}/${twoDigits(start.month)} a '
        '${twoDigits(end.day)}/${twoDigits(end.month)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3FBFF),
      body: SafeArea(
        child: Column(
          children: [
            _MetricsTopBar(subtitle: _periodSubtitle),
            _PeriodSelector(
              selected: _period,
              onSelect: _selectPeriod,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _ViewModeToggle(
                showOnlyMine: _showOnlyMine,
                onChanged: (value) {
                  setState(() {
                    _showOnlyMine = value;
                  });
                },
              ),
            ),
            Expanded(
              child: FutureBuilder<List<MechanicPerformance>>(
                future: _rankingFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const _MetricsSkeleton();
                  }

                  if (snapshot.hasError) {
                    return _MetricsStateMessage(
                      icon: Icons.error_outline,
                      title: 'Erro ao carregar o ranking',
                      message: 'Não foi possível carregar o desempenho da equipe.',
                      actionLabel: 'Tentar novamente',
                      onAction: _reload,
                    );
                  }

                  final ranking = snapshot.data ?? const [];

                  if (ranking.isEmpty) {
                    return const _MetricsStateMessage(
                      icon: Icons.groups_outlined,
                      title: 'Nenhum mecânico com chamados',
                      message:
                          'Ainda não há sinistros atribuídos a mecânicos nesta oficina.',
                    );
                  }

                  final currentUid = FirebaseAuth.instance.currentUser?.uid;

                  final maxCompleted = ranking
                      .map((p) => p.completed)
                      .fold<int>(0, (a, b) => a > b ? a : b);

                  var visualIndex = 0;
                  final items = <Widget>[];

                  if (_showOnlyMine) {
                    MechanicPerformance? mine;
                    var myPosition = 0;

                    for (var i = 0; i < ranking.length; i++) {
                      if (ranking[i].uid == currentUid) {
                        mine = ranking[i];
                        myPosition = i + 1;
                        break;
                      }
                    }

                    if (mine == null) {
                      items.add(
                        const _MetricsStateMessage(
                          icon: Icons.person_search_outlined,
                          title: 'Nenhum chamado seu no período',
                          message:
                              'Você ainda não tem sinistros atribuídos nesse período. Troque o filtro de período ou volte para "Equipe".',
                        ),
                      );
                    } else {
                      items.addAll([
                        _StaggeredEntrance(
                          index: visualIndex++,
                          child: _TeamOverviewSection(
                            ranking: [mine],
                            title: 'Seu desempenho',
                          ),
                        ),
                        const SizedBox(height: 16),
                        _StaggeredEntrance(
                          index: visualIndex++,
                          child: Text(
                            'Você está em #$myPosition de ${ranking.length} na equipe',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFF414755),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _StaggeredEntrance(
                          index: visualIndex++,
                          child: _RankingCard(
                            position: myPosition,
                            performance: mine,
                            isCurrentUser: true,
                            maxCompleted: maxCompleted,
                          ),
                        ),
                      ]);
                    }
                  } else {
                    final podiumCount = ranking.length >= 3 ? 3 : ranking.length;
                    final podium = ranking.take(podiumCount).toList();
                    final rest = ranking.skip(podiumCount).toList();

                    items.addAll([
                      _StaggeredEntrance(
                        index: visualIndex++,
                        child: _TeamOverviewSection(ranking: ranking),
                      ),
                      const SizedBox(height: 16),
                      if (podium.isNotEmpty) ...[
                        _StaggeredEntrance(
                          index: visualIndex++,
                          child: _PodiumSection(
                            top: podium,
                            currentUid: currentUid,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      for (var i = 0; i < rest.length; i++) ...[
                        _StaggeredEntrance(
                          index: visualIndex++,
                          child: _RankingCard(
                            position: podiumCount + i + 1,
                            performance: rest[i],
                            isCurrentUser: rest[i].uid == currentUid,
                            maxCompleted: maxCompleted,
                          ),
                        ),
                        if (i != rest.length - 1) const SizedBox(height: 12),
                      ],
                    ]);
                  }

                  return RefreshIndicator(
                    color: const Color(0xFF0057C0),
                    onRefresh: () async {
                      setState(() {
                        _rankingFuture = _load();
                      });
                      await _rankingFuture;
                    },
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                      children: items,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Faz o filho entrar com fade + leve deslize de baixo pra cima, com um
/// atraso proporcional a [index] — dá o efeito de itens "chegando" um
/// atrás do outro em vez de estourarem todos de uma vez.
class _StaggeredEntrance extends StatefulWidget {
  final int index;
  final Widget child;

  const _StaggeredEntrance({required this.index, required this.child});

  @override
  State<_StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<_StaggeredEntrance> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();

    final delay = Duration(milliseconds: 70 * widget.index.clamp(0, 8));

    Future.delayed(delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      offset: _visible ? Offset.zero : const Offset(0, .06),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOut,
        opacity: _visible ? 1 : 0,
        child: widget.child,
      ),
    );
  }
}

/// Pódio com os 3 primeiros colocados: 2º à esquerda, 1º no centro (maior,
/// anel dourado), 3º à direita — clássico visual de leaderboard.
class _PodiumSection extends StatelessWidget {
  final List<MechanicPerformance> top;
  final String? currentUid;

  const _PodiumSection({required this.top, required this.currentUid});

  @override
  Widget build(BuildContext context) {
    final first = top.isNotEmpty ? top[0] : null;
    final second = top.length > 1 ? top[1] : null;
    final third = top.length > 2 ? top[2] : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 26, 12, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFEAF2FF), Color(0xFFF7FBFF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF0057C0).withOpacity(.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (second != null)
            _PodiumSpot(
              performance: second,
              position: 2,
              isCurrentUser: second.uid == currentUid,
              animationDelayMs: 140,
            )
          else
            const SizedBox(width: 76),
          if (first != null)
            _PodiumSpot(
              performance: first,
              position: 1,
              isCurrentUser: first.uid == currentUid,
              animationDelayMs: 0,
            )
          else
            const SizedBox(width: 92),
          if (third != null)
            _PodiumSpot(
              performance: third,
              position: 3,
              isCurrentUser: third.uid == currentUid,
              animationDelayMs: 260,
            )
          else
            const SizedBox(width: 76),
        ],
      ),
    );
  }
}

class _PodiumSpot extends StatefulWidget {
  final MechanicPerformance performance;
  final int position;
  final bool isCurrentUser;
  final int animationDelayMs;

  const _PodiumSpot({
    required this.performance,
    required this.position,
    required this.isCurrentUser,
    required this.animationDelayMs,
  });

  @override
  State<_PodiumSpot> createState() => _PodiumSpotState();
}

class _PodiumSpotState extends State<_PodiumSpot> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();

    Future.delayed(Duration(milliseconds: widget.animationDelayMs), () {
      if (mounted) setState(() => _popped = true);
    });
  }

  Color get _color {
    switch (widget.position) {
      case 1:
        return const Color(0xFFC9A227);
      case 2:
        return const Color(0xFF9AA5B1);
      default:
        return const Color(0xFFB8763E);
    }
  }

  IconData get _medalIcon =>
      widget.position == 1 ? Icons.emoji_events : Icons.military_tech;

  @override
  Widget build(BuildContext context) {
    final isFirst = widget.position == 1;
    final avatarSize = isFirst ? 78.0 : 60.0;
    final photoURL = widget.performance.photoURL.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          duration: const Duration(milliseconds: 520),
          curve: Curves.elasticOut,
          scale: _popped ? 1 : .4,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 240),
            opacity: _popped ? 1 : 0,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  width: avatarSize + 8,
                  height: avatarSize + 8,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _color,
                    boxShadow: [
                      BoxShadow(
                        color: _color.withOpacity(.4),
                        blurRadius: 20,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: CircleAvatar(
                      radius: avatarSize / 2,
                      backgroundColor: const Color(0xFFE5F6FF),
                      backgroundImage:
                          photoURL.isEmpty ? null : NetworkImage(photoURL),
                      child: photoURL.isEmpty
                          ? Icon(
                              Icons.person,
                              color: const Color(0xFF0057C0),
                              size: avatarSize * .45,
                            )
                          : null,
                    ),
                  ),
                ),
                Positioned(
                  bottom: -4,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: _color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Icon(
                      _medalIcon,
                      color: Colors.white,
                      size: isFirst ? 16 : 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: isFirst ? 96 : 78,
          child: Text(
            widget.performance.name.isEmpty
                ? 'Sem nome'
                : widget.performance.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.spaceGrotesk(
              fontSize: isFirst ? 13 : 11.5,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1F2937),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '${widget.performance.completed} concluídos',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: isFirst ? 11 : 10,
            fontWeight: FontWeight.w800,
            color: _color,
          ),
        ),
        if (widget.isCurrentUser) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF0057C0),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'Você',
              style: TextStyle(
                color: Colors.white,
                fontSize: 8.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricsSkeleton extends StatelessWidget {
  const _MetricsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFFE5EEF5),
      highlightColor: Colors.white,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: const [
          _MetricsOverviewSkeleton(),
          SizedBox(height: 16),
          _MetricsRankingCardSkeleton(),
          SizedBox(height: 12),
          _MetricsRankingCardSkeleton(),
          SizedBox(height: 12),
          _MetricsRankingCardSkeleton(),
        ],
      ),
    );
  }
}

class _MetricsOverviewSkeleton extends StatelessWidget {
  const _MetricsOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SkeletonBox(width: 170, height: 16),
          const SizedBox(height: 14),
          const Row(
            children: [
              Expanded(child: _SkeletonBox(width: double.infinity, height: 56)),
              SizedBox(width: 10),
              Expanded(child: _SkeletonBox(width: double.infinity, height: 56)),
              SizedBox(width: 10),
              Expanded(child: _SkeletonBox(width: double.infinity, height: 56)),
            ],
          ),
          const SizedBox(height: 20),
          for (var i = 0; i < 6; i++) ...[
            Row(
              children: [
                const _SkeletonBox(
                  width: 92,
                  height: 12,
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SkeletonBox(
                    width: double.infinity,
                    height: 18,
                    borderRadius: const BorderRadius.all(Radius.circular(999)),
                  ),
                ),
              ],
            ),
            if (i != 5) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _MetricsRankingCardSkeleton extends StatelessWidget {
  const _MetricsRankingCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SkeletonBox(width: 30, height: 30),
              const SizedBox(width: 10),
              const _SkeletonBox(width: 48, height: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SkeletonBox(width: 140, height: 15),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _SkeletonBox(
                            width: double.infinity,
                            height: 20,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _SkeletonBox(
                            width: double.infinity,
                            height: 20,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: const [
                  _SkeletonBox(width: 40, height: 18),
                  SizedBox(height: 6),
                  _SkeletonBox(width: 48, height: 10),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SkeletonBox(
            width: double.infinity,
            height: 8,
            borderRadius: BorderRadius.circular(999),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const _SkeletonBox({
    required this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width == double.infinity ? null : width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: borderRadius ?? BorderRadius.circular(999),
      ),
    );
  }
}

class _MetricsTopBar extends StatelessWidget {
  final String subtitle;

  const _MetricsTopBar({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.03),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Material(
            color: const Color(0xFFE5F6FF),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.keyboard_arrow_left_rounded,
                  color: Color(0xFF0057C0),
                  size: 30,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0057C0), Color(0xFF0474FB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0057C0).withOpacity(.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.emoji_events_outlined,
              color: Colors.white,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ranking da equipe',
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF1F2937),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Desempenho no período: $subtitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  final MetricsPeriod selected;
  final ValueChanged<MetricsPeriod> onSelect;

  const _PeriodSelector({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: MetricsPeriod.values.map((period) {
          final isSelected = selected == period;

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: isSelected ? const Color(0xFF0057C0) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () => onSelect(period),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? Colors.transparent
                            : Colors.black.withOpacity(.06),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        period == MetricsPeriod.custom
                            ? 'Personalizar'
                            : period.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF414755),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  final bool showOnlyMine;
  final ValueChanged<bool> onChanged;

  const _ViewModeToggle({required this.showOnlyMine, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFE5F6FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ViewModeSegment(
              label: 'Equipe',
              icon: Icons.groups_outlined,
              isSelected: !showOnlyMine,
              onTap: () => onChanged(false),
            ),
          ),
          Expanded(
            child: _ViewModeSegment(
              label: 'Meu desempenho',
              icon: Icons.person,
              isSelected: showOnlyMine,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewModeSegment extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ViewModeSegment({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? const Color(0xFF0057C0) : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected ? Colors.white : const Color(0xFF0057C0),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF0057C0),
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resumo visual da equipe: KPIs + gráfico de barras por status.
///
/// As cores usadas aqui (Pendentes/Em andamento/Em análise/Revisão/
/// Canceladas/Concluídas) NÃO são as mesmas cores de status usadas em
/// outras telas do app (chips/ícones isolados). Elas foram escolhidas e
/// validadas especificamente para aparecer lado a lado num gráfico —
/// a checagem de daltonismo mostrou que o conjunto antigo (laranja/
/// laranja-escuro/vermelho/verde) tem pares quase indistinguíveis para
/// quem tem deuteranopia/protanopia quando exibidos juntos.
class _TeamOverviewSection extends StatelessWidget {
  final List<MechanicPerformance> ranking;
  final String title;

  const _TeamOverviewSection({
    required this.ranking,
    this.title = 'Visão geral da equipe',
  });

  int _sum(int Function(MechanicPerformance) selector) {
    return ranking.fold(0, (total, performance) => total + selector(performance));
  }

  @override
  Widget build(BuildContext context) {
    final totalAssigned = _sum((p) => p.totalAssigned);
    final completed = _sum((p) => p.completed);
    final inProgress = _sum((p) => p.inProgress);
    final pending = _sum((p) => p.pending);
    final aiAnalysis = _sum((p) => p.aiAnalysis);
    final revision = _sum((p) => p.revision);
    final cancelled = _sum((p) => p.cancelled);

    final overallRate =
        totalAssigned == 0 ? 0 : (completed / totalAssigned * 100).round();

    final categories = <_StatusBarData>[
      _StatusBarData(
        label: 'Pendentes',
        icon: Icons.schedule,
        color: const Color(0xFFEB6834),
        value: pending,
      ),
      _StatusBarData(
        label: 'Em andamento',
        icon: Icons.build_circle_outlined,
        color: const Color(0xFF2A78D6),
        value: inProgress,
      ),
      _StatusBarData(
        label: 'Em análise (IA)',
        icon: Icons.psychology_alt_outlined,
        color: const Color(0xFF4A3AA7),
        value: aiAnalysis,
      ),
      _StatusBarData(
        label: 'Revisão',
        icon: Icons.rate_review_outlined,
        color: const Color(0xFFEDA100),
        value: revision,
      ),
      _StatusBarData(
        label: 'Canceladas',
        icon: Icons.cancel_outlined,
        color: const Color(0xFFE34948),
        value: cancelled,
      ),
      _StatusBarData(
        label: 'Concluídas',
        icon: Icons.check_circle_outline,
        color: const Color(0xFF008300),
        value: completed,
      ),
    ];

    final maxValue =
        categories.map((c) => c.value).fold<int>(0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1F2937),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _TeamStatTile(label: 'Atribuídas', value: '$totalAssigned'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _TeamStatTile(label: 'Concluídas', value: '$completed'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _TeamStatTile(label: 'Taxa média', value: '$overallRate%'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (final category in categories) ...[
            _StatusBarRow(data: category, max: maxValue),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _TeamStatTile extends StatelessWidget {
  final String label;
  final String value;

  const _TeamStatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3FBFF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0057C0),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBarData {
  final String label;
  final IconData icon;
  final Color color;
  final int value;

  const _StatusBarData({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
  });
}

class _StatusBarRow extends StatefulWidget {
  final _StatusBarData data;
  final int max;

  const _StatusBarRow({required this.data, required this.max});

  @override
  State<_StatusBarRow> createState() => _StatusBarRowState();
}

class _StatusBarRowState extends State<_StatusBarRow> {
  bool _revealed = false;

  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _revealed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final max = widget.max;
    final fraction = max <= 0 ? 0.0 : (data.value / max).clamp(0.0, 1.0);

    return Semantics(
      label: '${data.label}: ${data.value}',
      child: Row(
        children: [
          Icon(data.icon, size: 15, color: data.color),
          const SizedBox(width: 6),
          SizedBox(
            width: 92,
            child: Text(
              data.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF414755),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final barWidth = data.value == 0 || !_revealed
                    ? 0.0
                    : (constraints.maxWidth * fraction).clamp(
                        18.0,
                        constraints.maxWidth,
                      );

                return Stack(
                  children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3FBFF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      height: 18,
                      width: barWidth,
                      decoration: BoxDecoration(
                        color: data.color,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Text(
              '${data.value}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF1F2937),
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  final int position;
  final MechanicPerformance performance;
  final bool isCurrentUser;
  final int maxCompleted;

  const _RankingCard({
    required this.position,
    required this.performance,
    required this.isCurrentUser,
    required this.maxCompleted,
  });

  Color get _positionColor {
    switch (position) {
      case 1:
        return const Color(0xFFC9A227);
      case 2:
        return const Color(0xFF9AA5B1);
      case 3:
        return const Color(0xFFB8763E);
      default:
        return const Color(0xFF0057C0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoURL = performance.photoURL.trim();
    final percent = (performance.completionRate * 100).round();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isCurrentUser
              ? const Color(0xFF0057C0).withOpacity(.45)
              : Colors.black.withOpacity(.05),
          width: isCurrentUser ? 1.6 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.03),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _positionColor.withOpacity(position <= 3 ? .16 : .10),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$position',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                color: _positionColor,
              ),
            ),
          ),
          const SizedBox(width: 10),
          CircleAvatar(
            radius: 24,
            backgroundColor: const Color(0xFFE5F6FF),
            backgroundImage: photoURL.isEmpty ? null : NetworkImage(photoURL),
            child: photoURL.isEmpty
                ? const Icon(Icons.person, color: Color(0xFF0057C0))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        performance.name.isEmpty
                            ? 'Mecânico sem nome'
                            : performance.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1F2937),
                        ),
                      ),
                    ),
                    if (isCurrentUser) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0057C0),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Você',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _StatChip(
                      icon: Icons.check_circle_outline,
                      label: '${performance.completed} concluídos',
                      color: Colors.green,
                    ),
                    _StatChip(
                      icon: Icons.build_circle_outlined,
                      label: '${performance.inProgress} andamento',
                      color: const Color(0xFF0057C0),
                    ),
                    if (performance.revision > 0)
                      _StatChip(
                        icon: Icons.rate_review_outlined,
                        label: '${performance.revision} revisão',
                        color: Colors.deepOrange,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$percent%',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0057C0),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${performance.totalAssigned} total',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
          ),
          const SizedBox(height: 10),
          _MagnitudeBar(
            value: performance.completed,
            max: maxCompleted,
          ),
        ],
      ),
    );
  }
}

/// Barra de magnitude (mesma cor em todas as linhas): compara o número de
/// concluídos deste mecânico com o do melhor colocado. Não é usada para
/// distinguir identidade — por isso é sempre a mesma cor (azul da marca),
/// diferente do gráfico de status da equipe, que usa cores por categoria.
class _MagnitudeBar extends StatefulWidget {
  final int value;
  final int max;

  const _MagnitudeBar({required this.value, required this.max});

  @override
  State<_MagnitudeBar> createState() => _MagnitudeBarState();
}

class _MagnitudeBarState extends State<_MagnitudeBar> {
  bool _revealed = false;

  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _revealed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final max = widget.max;
    final fraction = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);

    return Semantics(
      label: '$value de $max concluídos, o melhor da equipe no período',
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Container(
                height: 8,
                width: constraints.maxWidth,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5F6FF),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                height: 8,
                width: _revealed ? constraints.maxWidth * fraction : 0,
                decoration: BoxDecoration(
                  color: const Color(0xFF0057C0),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MetricsStateMessage({
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
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFE5F6FF),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: const Color(0xFF0057C0), size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0057C0),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

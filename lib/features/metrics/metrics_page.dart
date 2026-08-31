import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  late Future<List<MechanicPerformance>> _rankingFuture;

  @override
  void initState() {
    super.initState();
    _rankingFuture = _load();
  }

  Future<List<MechanicPerformance>> _load() {
    return MechanicPerformanceRepository.instance.loadRanking(
      credenciadoId: widget.credenciadoId,
      period: _period,
      customStart: _customRange?.start,
      customEnd: _customRange?.end,
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
            Expanded(
              child: FutureBuilder<List<MechanicPerformance>>(
                future: _rankingFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF0057C0),
                      ),
                    );
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

                  return RefreshIndicator(
                    color: const Color(0xFF0057C0),
                    onRefresh: () async {
                      setState(() {
                        _rankingFuture = _load();
                      });
                      await _rankingFuture;
                    },
                    child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    itemCount: ranking.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _TeamOverviewSection(ranking: ranking),
                        );
                      }

                      final performance = ranking[index - 1];

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RankingCard(
                          position: index,
                          performance: performance,
                          isCurrentUser: performance.uid == currentUid,
                          maxCompleted: maxCompleted,
                        ),
                      );
                    },
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

  const _TeamOverviewSection({required this.ranking});

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
            'Visão geral da equipe',
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

class _StatusBarRow extends StatelessWidget {
  final _StatusBarData data;
  final int max;

  const _StatusBarRow({required this.data, required this.max});

  @override
  Widget build(BuildContext context) {
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
                final barWidth = data.value == 0
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
                      duration: const Duration(milliseconds: 320),
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
class _MagnitudeBar extends StatelessWidget {
  final int value;
  final int max;

  const _MagnitudeBar({required this.value, required this.max});

  @override
  Widget build(BuildContext context) {
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
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                height: 8,
                width: constraints.maxWidth * fraction,
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

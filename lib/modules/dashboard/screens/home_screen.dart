import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../dashboard_metrics.dart';

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String longDate(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year}';

String greetingFor(DateTime now) => now.hour < 12
    ? 'Good morning'
    : now.hour < 17
        ? 'Good afternoon'
        : 'Good evening';

/// Where everyone lands after signing in: what they can start, what needs
/// them, and (for the owner and the board) how the hospital is doing today.
class DashboardHomeScreen extends StatelessWidget {
  const DashboardHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final s = context.session;
    final now = DateTime.now();
    final seesNumbers = context.can(DashboardPerms.view);
    final cards = app.registry.dashboardCards.where((c) => c.permission == null || context.can(c.permission!)).toList();
    // The control tower brings its own "Open findings" card; don't show it twice.
    final towerCard = cards.any((c) => c.id == 'tower.open_findings');
    final showFindings = context.can(CorePerms.towerView) && !towerCard;

    return PageScaffold(
      title: '${greetingFor(now)}, ${s?.displayName ?? 'there'}',
      subtitle: '${longDate(now)} · ${app.settings.hospitalName}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Columns(main: _QuickActions(), side: _NeedsAttention(), sideFlex: 2, mainFlex: 3),
          if (seesNumbers) ...[
            Gap.v24,
            _KpiSection(showFindings: showFindings),
          ] else if (context.can(DashboardPerms.patientsView)) ...[
            Gap.v24,
            const _TodayStrip(),
          ],
          if (cards.isNotEmpty) ...[
            Gap.v24,
            const SubHeading('From your modules'),
            _CardGrid(cards: cards),
          ],
        ],
      ),
    );
  }
}

/// Two columns on wide screens, stacked on narrow ones.
class _Columns extends StatelessWidget {
  const _Columns({required this.main, required this.side, this.mainFlex = 1, this.sideFlex = 1});
  final Widget main;
  final Widget side;
  final int mainFlex;
  final int sideFlex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 880) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, Gap.v16, side]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(flex: mainFlex, child: main), Gap.h16, Expanded(flex: sideFlex, child: side)],
      );
    });
  }
}

/// Lays tiles out in equal-height rows.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.children, this.minWidth = 220, this.maxColumns = 4, this.minColumns = 1});
  final List<Widget> children;
  final double minWidth;
  final int maxColumns;
  final int minColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minWidth).floor().clamp(minColumns, maxColumns);
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += cols) {
        final chunk = children.sublist(i, (i + cols).clamp(0, children.length));
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) Gap.h16,
                Expanded(child: j < chunk.length ? chunk[j] : const SizedBox.shrink()),
              ],
            ],
          ),
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[if (i > 0) Gap.v16, r],
        ],
      );
    });
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final actions = app.registry.quickActions.where((a) => a.permission == null || context.can(a.permission!)).take(8).toList();
    if (actions.isEmpty) {
      return const SectionCard(
        title: 'Start something',
        child: Text('Nothing to start from here yet. Use the menu to find your screens.'),
      );
    }
    return TourAnchor(
      id: 'dashboard.quick_actions',
      child: _TileGrid(
        minWidth: 200,
        maxColumns: 2,
        minColumns: 1,
        children: [for (final a in actions) _ActionButton(action: a)],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});
  final QuickAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => action.run(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.lg),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
                child: Icon(action.icon, color: cs.onPrimaryContainer),
              ),
              Gap.h12,
              Expanded(child: Text(action.label, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis)),
              Icon(Icons.chevron_right, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _Attention {
  const _Attention(this.notes, this.unread, this.approvals);
  final List<Rec> notes;
  final int unread;
  final int approvals;
}

class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention();

  static IconData _icon(String kind) => switch (kind) {
        'finding' => Icons.radar,
        'approval' => Icons.how_to_reg_outlined,
        'proposal' => Icons.lightbulb_outline,
        'briefing' => Icons.wb_sunny_outlined,
        _ => Icons.notifications_none,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final s = context.session;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final approver = context.can(CorePerms.approvalsDecide);
    if (s == null) return const SizedBox.shrink();
    return SectionCard(
      title: 'Needs your attention',
      child: LiveBuilder<_Attention>(
        watch: const {Col.notifications, Col.approvals},
        deps: [s.userId, approver],
        load: (db) async {
          final unread = Query(Col.notifications).eq('user_id', s.userId).eq('read', false);
          return _Attention(
            await db.query(unread.sort('created_at', desc: true).take(5)),
            await db.count(unread),
            approver ? await db.count(const Query(Col.approvals).eq('status', 'pending')) : 0,
          );
        },
        builder: (context, d) {
          final rows = <Widget>[];
          if (d.approvals > 0) {
            rows.add(_AttentionRow(
              icon: Icons.how_to_reg_outlined,
              tone: Tone.board,
              title: '${plural(d.approvals, 'request')} waiting for approval',
              subtitle: 'Discounts, refunds and other exceptions',
              onTap: () => app.nav.open('tower.approvals'),
            ));
          }
          for (final n in d.notes) {
            rows.add(_AttentionRow(
              icon: _icon(n.str('kind')),
              tone: toneForSeverity(n.strOrNull('severity')),
              title: n.str('title'),
              subtitle: [n.str('body'), formatRelative(n.createdAt)].where((x) => x.isNotEmpty).join(' · '),
              onTap: () async {
                await app.db.update(Col.notifications, n.id, {'read': true});
                final route = n.strOrNull('route_id');
                if (route != null) app.nav.open(route, n.map('route_args'));
              },
            ));
          }
          if (rows.isEmpty) {
            return Row(children: [
              Icon(Icons.task_alt, color: ToneColors.of(context, Tone.success).foreground),
              Gap.h12,
              Expanded(
                child: Text('All caught up. Nothing needs you right now.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ),
            ]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const Divider(height: 1), r],
              if (d.unread > d.notes.length) ...[
                Gap.v8,
                Text('and ${d.unread - d.notes.length} more in the bell above',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.icon, required this.tone, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final Tone tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, tone);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.sm)),
              child: Icon(icon, size: 18, color: c.foreground),
            ),
            Gap.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A number with a label that may wrap to two lines. Tap to see the records.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.caption,
    this.tone = Tone.info,
  });
  final String label;
  final String value;
  final String? caption;
  final IconData icon;
  final Tone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = ToneColors.of(context, tone);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.sm)),
                    child: Icon(icon, size: 18, color: c.foreground),
                  ),
                  Gap.h8,
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(label,
                          style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: cs.outline),
                ],
              ),
              const Spacer(),
              Gap.v12,
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              if (caption != null) ...[
                Gap.v4,
                Text(caption!,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _drill(BuildContext context, Map<String, Object?> args) => context.app.nav.open('dashboard.drilldown', args);

class _KpiSection extends StatelessWidget {
  const _KpiSection({required this.showFindings});
  final bool showFindings;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return LiveBuilder<DashboardKpis>(
      watch: const {Col.patients, Col.encounters, Col.charges, Col.findings},
      deps: [showFindings],
      loading: const SizedBox(height: 320),
      load: (db) => DashboardMetrics.load(db, findings: showFindings),
      builder: (context, k) {
        final sev = k.openFindings;
        final tiles = <Widget>[
          MetricTile(
            label: 'Registered today',
            value: formatNumber(k.patientsToday),
            caption: 'New patients',
            icon: Icons.person_add_alt_1_outlined,
            onTap: () => _drill(context, {'metric': Metrics.patientsToday}),
          ),
          MetricTile(
            label: 'OPD visits today',
            value: formatNumber(k.opdToday),
            caption: 'Outpatient consultations',
            icon: Icons.medical_services_outlined,
            onTap: () => _drill(context, {'metric': Metrics.opdToday}),
          ),
          MetricTile(
            label: 'Inpatients now',
            value: formatNumber(k.inpatientsNow),
            caption: 'Admitted, not yet discharged',
            icon: Icons.bed_outlined,
            onTap: () => _drill(context, {'metric': Metrics.inpatients}),
          ),
          MetricTile(
            label: 'Services delivered today',
            value: formatMoneyShort(k.revenueTodayPaise),
            caption: '${plural(k.chargesToday, 'charge')}, cancelled ones left out',
            icon: Icons.currency_rupee,
            tone: Tone.success,
            onTap: () => _drill(context, {'metric': Metrics.charges, 'day': dayKey(DateTime.now())}),
          ),
          if (showFindings)
            MetricTile(
              label: 'Open findings',
              value: formatNumber(k.openFindingsTotal),
              caption: [
                for (final s in ['critical', 'high', 'medium'])
                  if ((sev[s] ?? 0) > 0) '${sev[s]} $s',
              ].join(' · ').ifEmpty('Nothing waiting for the board'),
              icon: Icons.radar,
              tone: (sev['critical'] ?? 0) + (sev['high'] ?? 0) > 0 ? Tone.danger : Tone.warning,
              onTap: () => context.app.nav.open('tower.findings'),
            ),
        ];
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SubHeading('Today at the hospital'),
            TourAnchor(
              id: 'dashboard.kpis',
              child: _TileGrid(
                minWidth: compact ? 150 : 210,
                minColumns: compact ? 2 : 1,
                maxColumns: tiles.length > 4 ? 5 : 4,
                children: tiles,
              ),
            ),
            Gap.v16,
            _Columns(
              mainFlex: 3,
              sideFlex: 2,
              main: SectionCard(
                title: 'Services delivered, last 14 days',
                subtitle: 'By the day the service was given',
                trailing: TextButton(
                  onPressed: () => _drill(context, {'metric': Metrics.charges, 'days': DashboardMetrics.trendDays}),
                  child: const Text('See charges'),
                ),
                child: LayoutBuilder(builder: (context, c) {
                  final roomy = c.maxWidth / k.trend.length >= 44;
                  return BarChart(
                    values: [for (final t in k.trend) t.$2],
                    labels: [for (final t in k.trend) roomy ? formatDateShort(t.$1) : '${t.$1.day}'],
                    format: (v) => formatMoneyShort(v.toInt()),
                    height: 160,
                  );
                }),
              ),
              side: SectionCard(
                title: 'Today\'s mix',
                subtitle: 'Services delivered today, by kind',
                trailing: TextButton(
                  onPressed: () => _drill(context, {'metric': Metrics.charges, 'day': dayKey(DateTime.now())}),
                  child: const Text('Details'),
                ),
                child: k.mix.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                        child: Text('No services recorded yet today.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                      )
                    : _MixList(
                        mix: k.mix,
                        onTap: (cat) =>
                            _drill(context, {'metric': Metrics.charges, 'day': dayKey(DateTime.now()), 'category': cat}),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Like ShareBars, but each row opens that category's charges.
class _MixList extends StatelessWidget {
  const _MixList({required this.mix, required this.onTap});
  final List<(String, int)> mix;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final total = mix.fold<int>(0, (a, b) => a + b.$2);
    final maxV = mix.fold<int>(0, (a, b) => b.$2 > a ? b.$2 : a);
    final shown = mix.length > 6 ? [...mix.take(5), ('other', mix.skip(5).fold<int>(0, (a, b) => a + b.$2))] : mix;
    return Column(
      children: [
        for (final (cat, v) in shown)
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => onTap(cat),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(DashboardMetrics.categoryLabel(cat),
                          style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                    ),
                    Text(formatMoneyShort(v), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    SizedBox(
                      width: 48,
                      child: Text(total == 0 ? '' : '${(v * 100 / total).round()}%',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                  ]),
                  Gap.v4,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : v / maxV,
                      minHeight: 8,
                      backgroundColor: cs.surfaceContainerHigh,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// For front-desk staff: today's patient numbers, no money.
class _TodayStrip extends StatelessWidget {
  const _TodayStrip();

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(int, int, int)>(
      watch: const {Col.patients, Col.encounters},
      loading: const SizedBox(height: 140),
      load: (db) async => (
        await db.count(DashboardMetrics.patientsRegistered(DateTime.now())),
        await db.count(DashboardMetrics.opdVisits(DateTime.now())),
        await db.count(DashboardMetrics.inpatients()),
      ),
      builder: (context, d) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SubHeading('Today'),
          _TileGrid(
            minWidth: 200,
            maxColumns: 3,
            minColumns: context.isCompact ? 2 : 1,
            children: [
              MetricTile(
                label: 'Registered today',
                value: formatNumber(d.$1),
                caption: 'New patients',
                icon: Icons.person_add_alt_1_outlined,
                onTap: () => _drill(context, {'metric': Metrics.patientsToday}),
              ),
              MetricTile(
                label: 'OPD visits today',
                value: formatNumber(d.$2),
                caption: 'Outpatient consultations',
                icon: Icons.medical_services_outlined,
                onTap: () => _drill(context, {'metric': Metrics.opdToday}),
              ),
              MetricTile(
                label: 'Inpatients now',
                value: formatNumber(d.$3),
                caption: 'Admitted, not yet discharged',
                icon: Icons.bed_outlined,
                onTap: () => _drill(context, {'metric': Metrics.inpatients}),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Cards other modules contribute. Each is drawn in a panel with its title;
/// wide cards take two columns when there is room.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.cards});
  final List<DashboardCard> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const spacing = Gap.lg;
      final cols = (c.maxWidth / 320).floor().clamp(1, 3);
      final w = (c.maxWidth - (cols - 1) * spacing) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final card in cards)
            SizedBox(
              width: card.size == CardSize.wide && cols > 1 ? w * 2 + spacing : w,
              child: SectionCard(title: card.title, child: Builder(builder: card.builder)),
            ),
        ],
      );
    });
  }
}

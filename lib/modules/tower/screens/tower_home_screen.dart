import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../briefing.dart';
import '../tower_data.dart';
import '../widgets/tower_widgets.dart';
import 'decision_flows.dart';

/// The board's one screen: the numbers, everything waiting for a decision
/// (each with its one-tap action), trends and the latest briefing.
class TowerHomeScreen extends StatelessWidget {
  const TowerHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Control tower',
      subtitle: 'What the agents found, and what is waiting for the board',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _KpiRow(),
          Gap.v16,
          TwoColumns(
            main: const _NeedsDecision(),
            side: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const [_LatestBriefing(), Gap.v16, _FindingsPerDay(), Gap.v16, _OpenBreakdown()],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow();

  @override
  Widget build(BuildContext context) {
    final nav = context.app.nav;
    final canApprove = context.can(CorePerms.approvalsDecide);
    return LiveBuilder<TowerKpis>(
      watch: const {Col.findings, Col.approvals, Col.proposals},
      loading: const SizedBox(height: 120),
      load: TowerKpis.load,
      builder: (context, k) => ResponsiveGrid(
        minWidth: 170,
        maxColumns: 5,
        children: [
          KpiTile(
            label: 'Critical / high',
            value: formatNumber(k.openUrgent),
            caption: k.openUrgent == 0 ? 'Nothing urgent' : 'Open. Decide these first',
            icon: Icons.priority_high,
            tone: k.openUrgent > 0 ? Tone.danger : Tone.success,
            onTap: () => nav.open('tower.findings'),
          ),
          KpiTile(
            label: 'Open findings',
            value: formatNumber(k.openTotal),
            caption: 'Waiting for a decision',
            icon: Icons.flag_outlined,
            tone: Tone.warning,
            onTap: () => nav.open('tower.findings'),
          ),
          KpiTile(
            label: 'Amount at risk',
            value: formatMoneyShort(k.atRiskPaise),
            caption: 'Open, confirmed or assigned',
            icon: Icons.currency_rupee,
            tone: Tone.board,
            onTap: () => nav.open('tower.findings'),
          ),
          KpiTile(
            label: 'Approvals waiting',
            value: formatNumber(k.approvalsWaiting),
            caption: 'Discounts, refunds and more',
            icon: Icons.how_to_reg_outlined,
            tone: Tone.info,
            onTap: canApprove ? () => nav.open('tower.approvals') : null,
          ),
          KpiTile(
            label: 'Suggestions',
            value: formatNumber(k.suggestionsWaiting),
            caption: 'Agent proposals to approve',
            icon: Icons.lightbulb_outline,
            tone: Tone.agent,
            onTap: canApprove ? () => nav.open('tower.proposals') : null,
          ),
        ],
      ),
    );
  }
}

enum _Kind { finding, approval, proposal }

class _Item {
  const _Item(this.kind, this.rec, this.rank);
  final _Kind kind;
  final Rec rec;
  final int rank;
}

class _Decisions {
  const _Decisions(this.items, this.findings, this.approvals, this.proposals);
  final List<_Item> items;
  final int findings;
  final int approvals;
  final int proposals;
}

class _NeedsDecision extends StatelessWidget {
  const _NeedsDecision();

  static const _shown = 8;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canApprove = context.can(CorePerms.approvalsDecide);
    return SectionCard(
      title: 'Needs your decision',
      subtitle: 'Urgent findings, requests and suggestions, oldest requests first',
      child: LiveBuilder<_Decisions>(
        watch: const {Col.findings, Col.approvals, Col.proposals},
        load: (db) async {
          final findings = await db.query(const Query(Col.findings)
              .eq('status', FindingStatus.open)
              .isIn('severity', ['critical', 'high'])
              .sort('last_seen_at', desc: true)
              .take(30));
          final approvals = canApprove
              ? await db.query(const Query(Col.approvals).eq('status', 'pending').sort('created_at').take(30))
              : const <Rec>[];
          final proposals = (await db.query(const Query(Col.proposals).eq('status', 'pending').sort('created_at').take(30)))
              .where((p) => TowerDecisions.canDecideProposal(app, p))
              .toList();
          final items = [
            for (final f in sortForTriage(findings)) _Item(_Kind.finding, f, f.str('severity') == 'critical' ? 0 : 2),
            for (final a in approvals) _Item(_Kind.approval, a, 1),
            for (final p in proposals) _Item(_Kind.proposal, p, 3),
          ];
          // Stable sort keeps each group's own order.
          final sorted = [
            for (var r = 0; r <= 3; r++) ...items.where((i) => i.rank == r),
          ];
          return _Decisions(sorted, findings.length, approvals.length, proposals.length);
        },
        builder: (context, d) {
          if (d.items.isEmpty) {
            return const EmptyState(
              icon: Icons.task_alt,
              title: 'Nothing needs your decision',
              message: 'The agents keep watching. Urgent problems and new requests appear here.',
            );
          }
          final nav = app.nav;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, item) in d.items.take(_shown).indexed) ...[
                if (i > 0) const Divider(height: 1),
                _DecisionTile(item: item),
              ],
              Gap.v8,
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  if (d.findings > 0)
                    TextButton(onPressed: () => nav.open('tower.findings'), child: Text('All findings (${d.findings} urgent)')),
                  if (d.approvals > 0)
                    TextButton(onPressed: () => nav.open('tower.approvals'), child: Text('All approvals (${d.approvals})')),
                  if (d.proposals > 0)
                    TextButton(onPressed: () => nav.open('tower.proposals'), child: Text('All suggestions (${d.proposals})')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DecisionTile extends StatelessWidget {
  const _DecisionTile({required this.item});
  final _Item item;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final r = item.rec;
    final compact = context.isCompact;
    final names = agentNames(app);

    late final IconData icon;
    late final Tone tone;
    late final Widget chip;
    late final String meta;
    String? blocked;
    Widget? action;
    late final VoidCallback open;

    switch (item.kind) {
      case _Kind.finding:
        icon = Icons.flag_outlined;
        tone = toneForSeverity(r.str('severity'));
        chip = SeverityChip(r.str('severity'));
        final amount = r.intOrNull('amount_at_risk_paise') ?? 0;
        meta = [
          agentLabel(names, r.str('agent_id')),
          if (amount > 0) '${formatMoneyShort(amount)} at risk',
          formatRelative(r.date('last_seen_at') ?? r.createdAt),
        ].join(' · ');
        open = () => app.nav.open('tower.findings', {'id': r.id});
        if (context.can(CorePerms.towerDecide)) {
          action = OutlinedButton.icon(
            onPressed: () => DecisionFlows.confirm(context, r),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Confirm'),
          );
        }
      case _Kind.approval:
        icon = Icons.how_to_reg_outlined;
        tone = Tone.board;
        chip = StatusChip(approvalTypeLabel(r.str('type')), tone: Tone.board);
        meta = [
          formatMoney(r.integer('amount_paise')),
          'asked by ${r.str('requested_by_name', 'staff')}',
          formatRelative(r.createdAt),
          if (r.integer('required_approvals', 1) > 1) approvalProgress(r),
        ].join(' · ');
        open = () => app.nav.open('tower.approvals', {'id': r.id});
        blocked = TowerDecisions.whyCannotApprove(app, r);
        action = OutlinedButton.icon(
          onPressed: blocked == null ? () => DecisionFlows.approve(context, r, askNote: false) : null,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Approve'),
        );
      case _Kind.proposal:
        icon = Icons.lightbulb_outline;
        tone = Tone.agent;
        chip = const StatusChip('Suggestion', tone: Tone.agent);
        meta = ['From ${agentLabel(names, r.str('agent_id'))}', formatRelative(r.createdAt)].join(' · ');
        open = () => app.nav.open('tower.proposals');
        action = OutlinedButton.icon(
          onPressed: () => DecisionFlows.approveProposal(context, r),
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Approve'),
        );
    }

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r.str('title'), style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        Gap.v4,
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            chip,
            Text(meta, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
        if (blocked != null) ...[Gap.v4, InlineNote(blocked)],
      ],
    );

    return InkWell(
      onTap: open,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ToneIcon(icon, tone: tone),
                Gap.h12,
                Expanded(child: text),
                if (!compact && action != null) ...[Gap.h12, action],
              ],
            ),
            if (compact && action != null) ...[
              Gap.v8,
              Align(alignment: Alignment.centerRight, child: action),
            ],
          ],
        ),
      ),
    );
  }
}

class _LatestBriefing extends StatelessWidget {
  const _LatestBriefing();

  @override
  Widget build(BuildContext context) {
    final nav = context.app.nav;
    final theme = Theme.of(context);
    return LiveBuilder<Rec?>(
      watch: const {briefingsCol},
      load: Briefings.latest,
      builder: (context, b) {
        final s = b?.map('summary') ?? const <String, Object?>{};
        return SectionCard(
          title: 'Morning briefing',
          subtitle: b == null ? 'Prepared every morning' : formatDateTime(b.date('sent_at')),
          trailing: TextButton(onPressed: () => nav.open('tower.briefing'), child: const Text('Open')),
          child: b == null
              ? Text('No briefing yet. The first one is prepared at ${context.app.settings.briefingHour}:00.',
                  style: theme.textTheme.bodyMedium)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const ToneIcon(Icons.wb_sunny_outlined, tone: Tone.board, size: 32),
                      Gap.h12,
                      Expanded(
                        child: Text(
                          dayKey(DateTime.now()) == b.str('briefing_date') ? 'Today' : formatDate(b.date('sent_at')),
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ]),
                    Gap.v8,
                    Text(s['headline'] as String? ?? '', style: theme.textTheme.bodyMedium),
                  ],
                ),
        );
      },
    );
  }
}

class _FindingsPerDay extends StatelessWidget {
  const _FindingsPerDay();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Findings per day',
      subtitle: 'Last 14 days, by the day the problem was first seen',
      child: LiveBuilder<List<(DateTime, int)>>(
        watch: const {Col.findings},
        loading: const SizedBox(height: 210),
        load: (db) => findingsPerDay(db),
        builder: (context, days) => LayoutBuilder(
          builder: (context, c) => BarChart(
            values: [for (final d in days) d.$2],
            labels: dayLabels([for (final d in days) d.$1], c.maxWidth),
            format: (v) => plural(v.toInt(), 'finding'),
            height: 140,
          ),
        ),
      ),
    );
  }
}

class _OpenBreakdown extends StatefulWidget {
  const _OpenBreakdown();

  @override
  State<_OpenBreakdown> createState() => _OpenBreakdownState();
}

class _OpenBreakdownState extends State<_OpenBreakdown> {
  bool _byAgent = true;

  @override
  Widget build(BuildContext context) {
    final names = agentNames(context.app);
    return SectionCard(
      title: 'Open findings',
      trailing: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: true, label: Text('Agent')),
          ButtonSegment(value: false, label: Text('Category')),
        ],
        selected: {_byAgent},
        onSelectionChanged: (s) => setState(() => _byAgent = s.first),
      ),
      child: LiveBuilder<List<(String, num)>>(
        watch: const {Col.findings},
        deps: [_byAgent],
        load: (db) async {
          final rows = await db.aggregate(AggQuery.of(
            const Query(Col.findings).eq('status', FindingStatus.open),
            groupBy: _byAgent ? 'agent_id' : 'category',
          ));
          final items = [
            for (final r in rows)
              (
                _byAgent
                    ? agentLabel(names, '${r.key}')
                    : (r.key == null ? 'Uncategorised' : sentenceCase('${r.key}')),
                r.count,
              ),
          ]..sort((a, b) => b.$2.compareTo(a.$2));
          if (items.length <= 6) return items;
          final other = items.skip(5).fold<num>(0, (a, b) => a + b.$2);
          return [...items.take(5), ('Other', other)];
        },
        builder: (context, items) => items.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.md),
                child: Text('No open findings.', style: Theme.of(context).textTheme.bodyMedium),
              )
            : ShareBars(items: items, format: (v) => formatNumber(v)),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'tower_data.dart';
import 'widgets/tower_widgets.dart';

/// Dashboard card: open findings by severity. The dashboard draws the card
/// frame and title; this is the content.
class OpenFindingsCard extends StatelessWidget {
  const OpenFindingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.app.nav;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LiveBuilder<(Map<String, int>, int)>(
      watch: const {Col.findings},
      loading: const SizedBox(height: 140),
      load: (db) async {
        final rows = await db.aggregate(
            AggQuery.of(const Query(Col.findings).eq('status', FindingStatus.open), groupBy: 'severity'));
        final atRisk =
            (await db.sum(const Query(Col.findings).isIn('status', FindingStatus.unfixed), 'amount_at_risk_paise')).toInt();
        return ({for (final r in rows) '${r.key}': r.count}, atRisk);
      },
      builder: (context, data) {
        final (counts, atRisk) = data;
        final total = counts.values.fold<int>(0, (a, b) => a + b);
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => nav.open('tower.findings'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatNumber(total), style: theme.textTheme.headlineSmall),
                  Gap.h8,
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        atRisk > 0 ? 'open · ${formatMoneyShort(atRisk)} at risk' : 'open',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: cs.outline),
                ],
              ),
              Gap.v12,
              for (final s in Severity.values.reversed.where((s) => s != Severity.info || (counts['info'] ?? 0) > 0))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(width: 84, child: Align(alignment: Alignment.centerLeft, child: SeverityChip(s.name))),
                    Gap.h8,
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: total == 0 ? 0 : (counts[s.name] ?? 0) / total,
                          minHeight: 8,
                          color: ToneColors.of(context, toneForSeverity(s.name)).foreground,
                          backgroundColor: cs.surfaceContainerHigh,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text('${counts[s.name] ?? 0}', textAlign: TextAlign.right, style: theme.textTheme.titleSmall),
                    ),
                  ]),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Dashboard card: requests and agent suggestions waiting for the board.
class WaitingApprovalCard extends StatelessWidget {
  const WaitingApprovalCard({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.app.nav;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LiveBuilder<(List<Rec>, int, int, int)>(
      watch: const {Col.approvals, Col.proposals},
      loading: const SizedBox(height: 140),
      load: (db) async {
        const q = Query(Col.approvals);
        final pending = q.eq('status', 'pending');
        return (
          await db.query(pending.sort('created_at').take(3)),
          await db.count(pending),
          (await db.sum(pending, 'amount_paise')).toInt(),
          await db.count(const Query(Col.proposals).eq('status', 'pending')),
        );
      },
      builder: (context, data) {
        final (first, count, amount, suggestions) = data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => nav.open('tower.approvals'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(formatNumber(count), style: theme.textTheme.headlineSmall),
                  Gap.h8,
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        count == 0 ? 'requests waiting' : '${count == 1 ? 'request' : 'requests'} · ${formatMoneyShort(amount)}',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: cs.outline),
                ],
              ),
            ),
            Gap.v8,
            if (first.isEmpty)
              Text('Nothing waiting for approval.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
            else
              for (final a in first)
                InkWell(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  onTap: () => nav.open('tower.approvals', {'id': a.id}),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(
                        child: TwoLine(a.str('title'),
                            '${approvalTypeLabel(a.str('type'))} · ${a.str('requested_by_name')} · ${approvalProgress(a)}'),
                      ),
                      Gap.h8,
                      MoneyText(a.integer('amount_paise'), style: theme.textTheme.labelLarge),
                    ]),
                  ),
                ),
            if (suggestions > 0) ...[
              const Divider(height: Gap.lg),
              LinkRow(
                icon: Icons.lightbulb_outline,
                label: '${plural(suggestions, 'agent suggestion')} to review',
                onTap: () => nav.open('tower.proposals'),
              ),
            ],
          ],
        );
      },
    );
  }
}

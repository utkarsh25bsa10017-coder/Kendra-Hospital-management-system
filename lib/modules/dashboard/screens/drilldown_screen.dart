import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../dashboard_metrics.dart';

/// The records behind a home-screen number, with a total row: the metric
/// and its underlying transactions side by side.
class DrilldownScreen extends StatelessWidget {
  const DrilldownScreen({super.key, required this.args});
  final Map<String, Object?> args;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final metric = (args['metric'] as String?) ?? Metrics.revenueToday;
    final allowed = Metrics.isFinancial(metric)
        ? context.can(DashboardPerms.view)
        : context.can(DashboardPerms.view) || context.can(DashboardPerms.patientsView);
    if (!allowed) {
      return const PageScaffold(
        title: 'Details',
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'You do not have access to these numbers',
          message: 'Ask the hospital owner or administrator if you need them.',
        ),
      );
    }
    String moduleName(String id) {
      if (id.isEmpty) return '—';
      return app.registry.module(id)?.name ??
          switch (id) {
            'opd' || 'ipd' => id.toUpperCase(),
            _ => '${id[0].toUpperCase()}${id.substring(1).replaceAll('_', ' ')}',
          };
    }

    return LiveBuilder<Drilldown>(
      watch: const {Col.charges, Col.encounters, Col.patients},
      deps: [args.toString()],
      load: (db) => DashboardMetrics.drilldown(db, args, moduleName: moduleName),
      builder: (context, d) => PageScaffold(
        title: d.title,
        subtitle: d.subtitle,
        body: _Body(drill: d),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.drill});
  final Drilldown drill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final d = drill;
    final app = context.app;
    final money = d.totalPaise != null;
    final totalValue = money ? formatMoney(d.totalPaise) : formatNumber(d.count);

    void open(DrillRow r) {
      if (r.patientId != null) app.nav.open('patients.profile', {'id': r.patientId});
    }

    if (d.rows.isEmpty) {
      return EmptyState(
        icon: Icons.inbox_outlined,
        title: 'Nothing to show',
        message: 'There are no ${d.noun}s for this yet.',
      );
    }

    final summary = Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Wrap(
          spacing: Gap.xxl,
          runSpacing: Gap.md,
          children: [
            _Figure(label: money ? 'Total' : 'Count', value: totalValue),
            if (money) _Figure(label: 'Charges', value: formatNumber(d.count)),
            if (money && d.count > 0) _Figure(label: 'Average', value: formatMoney(d.totalPaise! ~/ d.count)),
          ],
        ),
      ),
    );

    Widget cell(DrillColumn c, String v) {
      final parts = v.split('\n');
      if (parts.length > 1) return TwoLine(parts.first, parts.skip(1).join(' '));
      return Text(v,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: c.numeric ? TextAlign.right : TextAlign.left,
          style: c.numeric ? const TextStyle(fontFeatures: [FontFeature.tabularFigures()]) : null);
    }

    final list = DataList<DrillRow>(
      items: d.rows,
      onTap: open,
      title: (r) => r.title,
      subtitle: (r) => r.subtitle,
      trailing: (r) => r.amountPaise == null ? const SizedBox.shrink() : MoneyText(r.amountPaise, style: theme.textTheme.titleSmall),
      columns: [
        for (final (i, c) in d.columns.indexed)
          ListColumn<DrillRow>(c.label, (r) => cell(c, i < r.cells.length ? r.cells[i] : ''), flex: c.flex, numeric: c.numeric),
      ],
    );

    // The total, lined up under the last column on wide screens.
    final total = context.isCompact
        ? Card(
            color: cs.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
              child: Row(children: [
                Expanded(child: Text('Total · ${plural(d.count, d.noun)}', style: theme.textTheme.titleSmall)),
                Text(totalValue, style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ),
          )
        : Card(
            color: cs.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.titleSmall,
                child: Row(children: [
                  Expanded(
                    flex: d.columns.take(d.columns.length - 1).fold<int>(0, (a, c) => a + c.flex),
                    child: Text('Total · ${plural(d.count, d.noun)}'),
                  ),
                  Expanded(
                    flex: d.columns.last.flex,
                    child: Padding(
                      padding: const EdgeInsets.only(right: Gap.md),
                      child: Text(
                        money || d.columns.last.numeric ? totalValue : '',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary,
        Gap.v16,
        list,
        Gap.v8,
        total,
        if (d.truncated) ...[
          Gap.v8,
          Text('Showing the first ${d.rows.length}. The total covers all ${plural(d.count, d.noun)}.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Gap.v4,
        Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}

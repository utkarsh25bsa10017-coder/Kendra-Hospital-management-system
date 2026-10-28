import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';
import 'lab_widgets.dart';

class _Trend {
  _Trend(this.key, this.name, this.unit, this.points, this.param);
  final String key;
  final String name;
  final String unit;
  final List<(DateTime, Map<String, Object?>)> points;
  final LabParam? param;
  Map<String, Object?> get latest => points.last.$2;
}

class _TabData {
  _TabData(this.items, this.trends);
  final List<LabItem> items;
  final List<_Trend> trends;
}

/// "Lab reports" on the patient profile: every order with its result, and
/// small trends for values measured more than once.
class PatientLabTab extends StatelessWidget {
  const PatientLabTab({super.key, required this.patient});
  final Rec patient;

  Future<_TabData> _load(ReadDb db) async {
    final orders = await db.query(LabService.labOrders().eq('patient_id', patient.id).sort('ordered_at', desc: true).take(100));
    final tests = await LabService.testsByCode(db);
    final items = await LabService.loadItems(db, orders, tests: tests);
    final verified = await db.query(Query(LabCol.results)
        .eq('patient_id', patient.id)
        .eq('status', ResultStatus.verified)
        .sort('verified_at')
        .take(200));
    final byKey = <String, List<(DateTime, Map<String, Object?>)>>{};
    final paramOf = <String, LabParam>{};
    for (final r in verified) {
      final at = r.date('entered_at') ?? r.createdAt;
      for (final p in paramsOf(tests[r.str('test_code')])) {
        paramOf.putIfAbsent(p.key, () => p);
      }
      for (final v in r.maps('values')) {
        if (v['numeric'] == null) continue;
        byKey.putIfAbsent('${v['key']}', () => []).add((at, v));
      }
    }
    final trends = [
      for (final e in byKey.entries)
        if (e.value.length >= 2)
          _Trend(e.key, '${e.value.last.$2['name']}', '${e.value.last.$2['unit'] ?? ''}', e.value, paramOf[e.key]),
    ]..sort((a, b) {
        final fa = LabFlag.isAbnormal(a.latest['flag'] as String?) ? 0 : 1;
        final fb = LabFlag.isAbnormal(b.latest['flag'] as String?) ? 0 : 1;
        if (fa != fb) return fa - fb;
        return b.points.length - a.points.length;
      });
    return _TabData(items, trends.take(6).toList());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canOrder = context.can(LabPerms.order);
    return LiveBuilder<_TabData>(
      watch: const {Col.serviceOrders, LabCol.results},
      deps: [patient.id],
      load: _load,
      builder: (context, d) {
        if (d.items.isEmpty) {
          return EmptyState(
            icon: Icons.biotech_outlined,
            title: 'No lab tests yet',
            message: 'Tests ordered for ${patient.str('first_name')} and their reports appear here.',
            action: canOrder
                ? FilledButton.icon(
                    onPressed: () => app.nav.open('lab.new_order', {'patientId': patient.id}),
                    icon: const Icon(Icons.add),
                    label: const Text('Order lab test'))
                : null,
          );
        }
        final unacked = d.items.where((i) =>
            i.status == Vals.verified && (i.result?.flag('critical') ?? false) && i.result?.date('acknowledged_at') == null);
        final pending = d.items.where((i) => i.status != Vals.verified && i.status != Vals.cancelled).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final i in unacked) ...[
              LabBanner(
                tone: Tone.danger,
                icon: Icons.warning_amber_rounded,
                title: 'Critical result: ${criticalText(i.result!.maps('values'), i.params)}',
                message: '${i.testName} · verified ${formatRelative(i.order.date('verified_at'))}. Not yet acknowledged by a doctor.',
                action: OutlinedButton(onPressed: () => app.nav.open('lab.order', {'id': i.id}), child: const Text('Open')),
              ),
              Gap.v16,
            ],
            if (d.trends.isNotEmpty) ...[
              SectionCard(
                title: 'Trends',
                subtitle: 'Verified values measured more than once',
                child: ResponsiveGrid(
                  minWidth: 230,
                  maxColumns: 3,
                  spacing: Gap.md,
                  children: [for (final t in d.trends) _TrendTile(trend: t)],
                ),
              ),
              Gap.v16,
            ],
            Row(children: [
              Expanded(
                child: Text(
                  '${plural(d.items.length, 'test')}${pending > 0 ? ' · $pending in progress' : ''}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ]),
            Gap.v8,
            DataList<LabItem>(
              items: d.items,
              onTap: (i) => app.nav.open('lab.order', {'id': i.id, 'report': i.status == Vals.verified}),
              title: (i) => i.testName,
              subtitle: (i) => [
                formatDate(i.orderedAt),
                if (i.order.str('result_summary').isNotEmpty) i.order.str('result_summary'),
              ].join(' · '),
              trailing: (i) => OrderStatusChip(i.status, resultStatus: i.result?.str('status')),
              columns: [
                ListColumn('Ordered', (i) => TwoLine(formatDate(i.orderedAt), formatTime(i.orderedAt)), width: 120),
                ListColumn('Test', (i) => TwoLine(i.testName, i.doctorName), flex: 4),
                ListColumn('Status', (i) => OrderStatusChip(i.status, resultStatus: i.result?.str('status')), width: 170),
                ListColumn('Result', (i) => SummaryText(i.order), flex: 4),
                if (context.isExpanded)
                  ListColumn('Verified by', (i) => Text(i.result?.str('verified_by_name') ?? '—', overflow: TextOverflow.ellipsis),
                      flex: 2),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _TrendTile extends StatelessWidget {
  const _TrendTile({required this.trend});
  final _Trend trend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pts = trend.points.length > 6 ? trend.points.sublist(trend.points.length - 6) : trend.points;
    final p = trend.param;
    final flag = trend.latest['flag'] as String? ?? '';
    final tone = LabFlag.tone(flag);
    final color = flag.isEmpty ? theme.colorScheme.primary : ToneColors.of(context, tone).foreground;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(p?.label ?? trend.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
            FlagBadge(flag),
          ]),
          Text(
            [
              if (p != null && p.refLabel().isNotEmpty) 'Ref ${p.refLabel()}',
              if (trend.unit.isNotEmpty) trend.unit,
            ].join(' '),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          BarChart(
            values: [for (final (_, v) in pts) (v['numeric'] as num?) ?? 0],
            labels: [for (final (d, _) in pts) formatDateShort(d)],
            format: (v) => p?.format(v) ?? formatNumber(v),
            height: 56,
            color: color,
          ),
        ],
      ),
    );
  }
}

import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';

/// Checks that the stock books add up: each batch's quantity equals the sum
/// of its movements, nothing is below zero, and every dispense was charged.
class StockIntegrityAgent extends HmsAgent {
  @override
  String get id => 'pharmacy.stock_integrity';
  @override
  String get name => 'Stock integrity';
  @override
  String get description =>
      'Flags batches whose quantity does not match their movements, negative stock, and medicines handed out without a charge.';
  @override
  Set<String> get watches => const {PCol.batches, PCol.movements, PCol.dispenses, Col.charges};
  @override
  Duration get interval => const Duration(hours: 3);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final db = ctx.db;
    final batches = await db.query(const Query(PCol.batches).take(50000).withArchived());
    final sums = {
      for (final r in await db.aggregate(const AggQuery(PCol.movements, groupBy: 'batch_id', sums: ['qty'])))
        r.key: r.sum('qty').toInt(),
    };
    final products = await db.byIds(PCol.products, batches.map((b) => b.str('product_id')));
    final findings = <FindingDraft>[];

    for (final b in batches) {
      final p = products[b.str('product_id')];
      final name = p?.str('name') ?? 'Medicine';
      final onHand = b.integer('qty_on_hand');
      final moved = sums[b.id] ?? 0;
      final cost = b.integer('cost_paise');
      final evidence = [
        Evidence('$name · batch ${b.str('batch_no')}',
            collection: PCol.batches, id: b.id, routeId: 'pharmacy.product', routeArgs: {'id': b.str('product_id')}),
      ];
      if (onHand != moved) {
        final diff = onHand - moved;
        findings.add(FindingDraft(
          key: 'mismatch:${b.id}',
          subjectKey: 'batch:${b.id}',
          title: 'Stock record mismatch: $name',
          summary: 'Batch ${b.str('batch_no')} shows $onHand on hand but its movements add up to $moved '
              '(${diff > 0 ? '$diff more' : '${-diff} fewer'} than recorded). Count the shelf and post an '
              'adjustment with the reason; stock must only change through movements.',
          severity: Severity.high,
          category: 'stock',
          amountAtRiskPaise: diff.abs() * cost,
          evidence: evidence,
        ));
      }
      if (onHand < 0) {
        findings.add(FindingDraft(
          key: 'negative:${b.id}',
          subjectKey: 'batch:${b.id}',
          title: 'Negative stock: $name',
          summary: 'Batch ${b.str('batch_no')} is at $onHand. More was handed out than was received; '
              'check recent dispenses and receipts for this batch.',
          severity: Severity.high,
          category: 'stock',
          amountAtRiskPaise: -onHand * cost,
          evidence: evidence,
        ));
      }
    }

    // Leakage: medicines handed out with nothing for billing to collect.
    final since = ctx.startOfToday.subtract(const Duration(days: 90));
    final dispenses = await db.query(Query(PCol.dispenses)
        .isIn('kind', [DispenseKind.prescription, DispenseKind.counter])
        .gte('dispensed_at', since)
        .sort('dispensed_at', desc: true)
        .take(10000));
    if (dispenses.isNotEmpty) {
      final charged = <String>{};
      for (final c in await db.query(Query(Col.charges)
          .eq('source_collection', PCol.dispenses)
          .gte('created_at', since.subtract(const Duration(days: 1)))
          .take(100000)
          .withArchived())) {
        final sid = c.str('source_id');
        final i = sid.indexOf(':');
        charged.add(i < 0 ? sid : sid.substring(0, i));
      }
      final patients = await db.byIds(Col.patients, dispenses.map((d) => d.strOrNull('patient_id')));
      for (final d in dispenses) {
        if (charged.contains(d.id) || d.integer('total_paise') <= 0) continue;
        final pt = patients[d.str('patient_id')];
        findings.add(FindingDraft(
          key: 'nocharge:${d.id}',
          subjectKey: 'dispense:${d.id}',
          title: 'Medicines dispensed without a charge',
          summary: '${d.str('number')}${pt == null ? '' : ' for ${pt.str('full_name')}'} '
              '(${formatMoney(d.integer('total_paise'))}, ${formatDate(d.date('dispensed_at'))}) has no charge for '
              'billing to collect. Check whether the charge was removed or never posted.',
          severity: Severity.medium,
          category: 'revenue leakage',
          amountAtRiskPaise: d.integer('total_paise'),
          patientId: d.strOrNull('patient_id'),
          evidence: [
            Evidence('Dispense ${d.str('number')}',
                collection: PCol.dispenses, id: d.id, routeId: 'pharmacy.dispense_summary', routeArgs: {'id': d.id}),
            if (pt != null)
              Evidence(pt.str('full_name'), collection: Col.patients, id: pt.id, routeId: 'patients.profile', routeArgs: {'id': pt.id}),
          ],
        ));
      }
    }
    return AgentReport(findings: findings);
  }
}

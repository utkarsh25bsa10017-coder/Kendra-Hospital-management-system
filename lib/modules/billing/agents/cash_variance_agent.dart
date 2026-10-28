import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';

/// Cash drawers that did not match what the cashier took in.
class CashVarianceAgent extends HmsAgent {
  @override
  String get id => 'billing.cash_variance';
  @override
  String get name => 'Cash variance';
  @override
  String get description => 'Flags day closings where the cash counted did not match the cash taken.';
  @override
  Set<String> get watches => const {BillCol.closings};
  @override
  Duration get interval => const Duration(hours: 6);

  static const mediumPaise = 10000; // ₹100
  static const highPaise = 200000; // ₹2,000

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final rows = await ctx.db.query(Query(BillCol.closings)
        .gte('closed_at', ctx.now.subtract(const Duration(days: 30)))
        .sort('closed_at')
        .take(3000));
    // A cashier may close the same day twice; the latest count stands.
    final latest = <String, Rec>{};
    for (final r in rows) {
      latest['${r.str('user_id')}|${r.str('closing_date')}'] = r;
    }
    final findings = <FindingDraft>[];
    for (final r in latest.values) {
      final v = r.integer('variance_paise');
      if (v.abs() <= mediumPaise) continue;
      final day = DateTime.tryParse(r.str('closing_date'));
      final note = r.str('notes');
      findings.add(FindingDraft(
        key: 'closing:${r.id}',
        title: 'Cash ${v < 0 ? 'short' : 'over'} by ${formatMoney(v.abs())} at ${r.str('user_name')}\'s counter',
        summary: 'On ${day == null ? r.str('closing_date') : formatDate(day)}, ${r.str('user_name')} counted '
            '${formatMoney(r.integer('counted_cash_paise'))} against ${formatMoney(r.integer('expected_cash_paise'))} '
            'expected.${note.isEmpty ? ' No reason was given.' : ' Their note: "$note".'}',
        severity: v.abs() > highPaise ? Severity.high : Severity.medium,
        category: 'cash',
        amountAtRiskPaise: v.abs(),
        evidence: [Evidence('Collections', collection: BillCol.closings, id: r.id, routeId: 'billing.collections')],
        data: {'user_id': r.str('user_id'), 'variance_paise': v, 'closing_date': r.str('closing_date')},
      ));
    }
    return AgentReport(findings: findings);
  }
}

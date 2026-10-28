import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';

/// Discounts per staff member against their own normal, plus discounts
/// given in the middle of the night. Discounts within someone's limit need
/// no approval, so patterns are the only thing that shows misuse.
class DiscountPatternsAgent extends HmsAgent {
  @override
  String get id => 'billing.discount_patterns';
  @override
  String get name => 'Discount patterns';
  @override
  String get description => 'Spots staff giving far more discounts than they normally do, and discounts '
      'given late at night.';
  @override
  Set<String> get watches => const {BillCol.invoices};
  @override
  Duration get interval => const Duration(hours: 6);

  /// Weekly totals below this are never "unusual".
  static const minWeekPaise = 100000;

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final now = ctx.now;
    final bills = await ctx.db.query(Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .isIn('status', [InvoiceStatus.finalised, InvoiceStatus.cancelled])
        .gt('discount_paise', 0)
        .gte('discount_at', now.subtract(const Duration(days: 7 * 14)))
        .sort('discount_at')
        .take(10000));
    final byUser = <String, List<Rec>>{};
    for (final b in bills) {
      final u = b.strOrNull('discount_by');
      if (u != null) byUser.putIfAbsent(u, () => []).add(b);
    }

    final findings = <FindingDraft>[];
    final weekAgo = now.subtract(const Duration(days: 7));
    for (final e in byUser.entries) {
      final userId = e.key;
      final list = e.value;
      final name = list.last.str('discount_by_name', 'A staff member');
      final recent = list.where((b) => !b.date('discount_at')!.isBefore(weekAgo)).toList();
      final recentSum = recent.fold<int>(0, (a, b) => a + b.integer('discount_paise'));

      // Their own normal: 13 weeks before the last one.
      final weeks = List<int>.filled(13, 0);
      for (final b in list) {
        final age = now.difference(b.date('discount_at')!).inDays;
        final w = age ~/ 7 - 1;
        if (w >= 0 && w < weeks.length) weeks[w] += b.integer('discount_paise');
      }
      final z = Stats.zScore(recentSum, weeks);
      if (recentSum >= minWeekPaise && z > 2.5) {
        final usual = Stats.mean(weeks).round();
        final top = [...recent]..sort((a, b) => b.integer('discount_paise').compareTo(a.integer('discount_paise')));
        findings.add(FindingDraft(
          key: 'user:$userId',
          subjectKey: 'user:$userId',
          title: 'Unusual discounts by $name',
          summary: '${formatMoney(recentSum)} in discounts on ${plural(recent.length, 'bill')} in the last 7 days, '
              'against a usual ${formatMoney(usual)} a week over the last 90 days.',
          severity: Severity.medium,
          category: 'discounts',
          amountAtRiskPaise: recentSum - usual,
          evidence: [for (final b in top.take(4)) _bill(b)],
          data: {'user_id': userId, 'recent_paise': recentSum, 'usual_week_paise': usual, 'z': z},
        ));
      }

      final night = list.where((b) {
        final at = b.date('discount_at')!;
        return now.difference(at).inDays < 30 && (at.hour >= 22 || at.hour < 6);
      }).toList();
      if (night.isNotEmpty) {
        final total = night.fold<int>(0, (a, b) => a + b.integer('discount_paise'));
        findings.add(FindingDraft(
          key: 'night:$userId',
          subjectKey: 'user:$userId',
          title: 'Late-night discounts by $name',
          summary: '${plural(night.length, 'discount')} worth ${formatMoney(total)} given between 10 PM and 6 AM in '
              'the last 30 days, the latest on ${formatDateTime(night.last.date('discount_at'))}.',
          severity: Severity.low,
          category: 'discounts',
          amountAtRiskPaise: total,
          evidence: [for (final b in night.reversed.take(4)) _bill(b)],
          data: {'user_id': userId, 'count': night.length},
        ));
      }
    }
    return AgentReport(findings: findings);
  }

  static Evidence _bill(Rec b) => Evidence(
      '${b.str('number')} · ${b.str('patient_name')} · ${formatMoney(b.integer('discount_paise'))} off',
      collection: BillCol.invoices,
      id: b.id,
      routeId: 'billing.invoice',
      routeArgs: {'id': b.id});
}

import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';

/// One daily summary of bills that are still unpaid after a week.
class UnpaidBillsAgent extends HmsAgent {
  @override
  String get id => 'billing.unpaid';
  @override
  String get name => 'Unpaid bills';
  @override
  String get description => 'Summarises final bills that still have money due more than a week later.';
  @override
  Set<String> get watches => const {BillCol.invoices};
  @override
  Duration get interval => const Duration(hours: 6);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final now = ctx.now;
    final bills = await ctx.db.query(Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .eq('status', InvoiceStatus.finalised)
        .gt('balance_paise', 0)
        .lt('finalised_at', now.subtract(const Duration(days: 7)))
        .sort('finalised_at')
        .take(2000));
    if (bills.isEmpty) return const AgentReport();
    final total = bills.fold<int>(0, (a, b) => a + b.integer('balance_paise'));
    final oldest = bills.first;
    final days = now.difference(oldest.date('finalised_at')!).inDays;
    final biggest = [...bills]..sort((a, b) => b.integer('balance_paise').compareTo(a.integer('balance_paise')));
    final key = dayKey(now).replaceAll('-', '');
    return AgentReport(findings: [
      FindingDraft(
        key: 'unpaid:$key',
        title: '${plural(bills.length, 'bill')} unpaid for more than a week',
        summary: '${formatMoney(total)} is still due. The oldest is ${oldest.str('number')} for '
            '${oldest.str('patient_name')}, $days days ago (${formatMoney(oldest.integer('balance_paise'))}).',
        severity: Severity.low,
        category: 'collections',
        amountAtRiskPaise: total,
        evidence: [
          for (final b in biggest.take(5))
            Evidence('${b.str('number')} · ${b.str('patient_name')} · ${formatMoney(b.integer('balance_paise'))} due',
                collection: BillCol.invoices, id: b.id, routeId: 'billing.invoice', routeArgs: {'id': b.id}),
        ],
        data: {'count': bills.length, 'total_paise': total},
      ),
    ]);
  }
}

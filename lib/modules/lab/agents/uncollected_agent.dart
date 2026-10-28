import 'package:kendra_hms/core/core.dart';

import '../lab_service.dart';

/// Tests a doctor ordered more than a day ago whose sample was never taken.
/// Either the patient left without it, or the order should be cancelled.
class UncollectedAgent extends HmsAgent {
  @override
  String get id => 'lab.uncollected';
  @override
  String get name => 'Uncollected lab orders';
  @override
  String get description => 'Lists lab orders still waiting for a sample a day after they were placed.';
  @override
  Set<String> get watches => const {Col.serviceOrders};
  @override
  Duration get interval => const Duration(hours: 1);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final cutoff = ctx.now.subtract(const Duration(hours: 24));
    final orders = await ctx.db.query(LabService.labOrders()
        .eq('status', Vals.ordered)
        .lt('ordered_at', cutoff)
        .sort('ordered_at', desc: true)
        .take(500));
    if (orders.isEmpty) return const AgentReport();
    final patients = await ctx.db.byIds(Col.patients, orders.map((o) => o.strOrNull('patient_id')));
    final doctors = await ctx.db.byIds(Col.users, orders.map((o) => o.strOrNull('ordered_by')));
    return AgentReport(findings: [
      for (final o in orders)
        FindingDraft(
          key: 'order:${o.id}',
          title: 'Ordered but sample never collected: ${o.str('name')}',
          summary: '${patients[o.str('patient_id')]?.str('full_name') ?? 'A patient'} · ordered by '
              '${doctors[o.str('ordered_by')]?.str('display_name') ?? 'staff'} on ${formatDateTime(o.date('ordered_at'))}. '
              'Call the patient back for the sample, or cancel the order.',
          severity: Severity.low,
          category: 'lab workflow',
          patientId: o.strOrNull('patient_id'),
          evidence: [
            Evidence(o.str('name'), collection: Col.serviceOrders, id: o.id, routeId: 'lab.order', routeArgs: {'id': o.id}),
          ],
        ),
    ]);
  }
}

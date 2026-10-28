import 'package:kendra_hms/core/core.dart';

import '../lab_service.dart';

/// Results entered more than four hours ago that no pathologist has signed.
class UnverifiedAgent extends HmsAgent {
  @override
  String get id => 'lab.unverified';
  @override
  String get name => 'Unverified lab reports';
  @override
  String get description => 'Lists lab results that have waited more than 4 hours for a pathologist to verify them.';
  @override
  Set<String> get watches => const {Col.serviceOrders};
  @override
  Duration get interval => const Duration(minutes: 30);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final cutoff = ctx.now.subtract(const Duration(hours: 4));
    final orders = await ctx.db.query(LabService.labOrders()
        .eq('status', Vals.resulted)
        .lt('resulted_at', cutoff)
        .sort('resulted_at')
        .take(500));
    if (orders.isEmpty) return const AgentReport();
    final patients = await ctx.db.byIds(Col.patients, orders.map((o) => o.strOrNull('patient_id')));
    return AgentReport(findings: [
      for (final o in orders)
        FindingDraft(
          key: 'order:${o.id}',
          title: 'Waiting for verification: ${o.str('name')}',
          summary: '${patients[o.str('patient_id')]?.str('full_name') ?? 'A patient'} · results entered '
              '${formatDuration(ctx.now.difference(o.date('resulted_at')!))} ago'
              '${o.str('result_summary').isEmpty ? '' : ' (${o.str('result_summary')})'}. '
              'The doctor cannot act on an unverified report.',
          severity: Severity.low,
          category: 'lab workflow',
          patientId: o.strOrNull('patient_id'),
          evidence: [
            Evidence('${o.str('name')} · ${o.str('sample_id')}',
                collection: Col.serviceOrders, id: o.id, routeId: 'lab.order', routeArgs: {'id': o.id}),
          ],
        ),
    ]);
  }
}

import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

/// Orders that are taking longer than the test's turnaround time. STAT
/// orders get one hour.
class TurnaroundAgent extends HmsAgent {
  @override
  String get id => 'lab.turnaround';
  @override
  String get name => 'Lab turnaround';
  @override
  String get description =>
      'Flags lab orders that are past their turnaround time, and STAT orders not reported within an hour.';
  @override
  Set<String> get watches => const {Col.serviceOrders};
  @override
  Duration get interval => const Duration(minutes: 15);

  static String stage(String status) => switch (status) {
        Vals.ordered => 'the sample has not been collected',
        Vals.collected => 'results have not been entered',
        _ => 'the report is waiting for verification',
      };

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final since = ctx.now.subtract(const Duration(days: 7));
    final orders = await ctx.db.query(LabService.labOrders()
        .isIn('status', [Vals.ordered, Vals.collected, Vals.resulted])
        .gte('ordered_at', since)
        .sort('ordered_at')
        .take(1000));
    if (orders.isEmpty) return const AgentReport();
    final tests = await LabService.testsByCode(ctx.db);
    final patients = await ctx.db.byIds(Col.patients, orders.map((o) => o.strOrNull('patient_id')));

    final findings = <FindingDraft>[];
    for (final o in orders) {
      final orderedAt = o.date('ordered_at');
      if (orderedAt == null) continue;
      final status = o.str('status');
      final elapsed = ctx.now.difference(orderedAt);
      final tat = tests[o.str('service_code')]?.intOrNull('tat_minutes') ?? defaultTatMinutes;
      final stat = o.str('priority') == Priority.stat;
      final who = patients[o.str('patient_id')]?.str('full_name') ?? 'a patient';
      Severity? severity;
      String title = '';
      if (stat && elapsed.inMinutes > 60) {
        severity = Severity.high;
        title = 'STAT ${o.str('name')} for $who not reported after ${formatDuration(elapsed)}';
      } else if (elapsed.inMinutes > tat) {
        // Never-collected orders older than a day are the uncollected agent's job.
        if (status == Vals.ordered && elapsed.inHours >= 24) continue;
        severity = Severity.medium;
        title = '${o.str('name')} for $who is past its ${formatDuration(Duration(minutes: tat))} turnaround';
      }
      if (severity == null) continue;
      findings.add(FindingDraft(
        key: 'order:${o.id}',
        title: title,
        summary: 'Ordered ${formatDateTime(orderedAt)} (${formatDuration(elapsed)} ago) and ${stage(status)}.',
        severity: severity,
        category: 'turnaround',
        patientId: o.strOrNull('patient_id'),
        evidence: [
          Evidence('${o.str('name')}${o.strOrNull('sample_id') == null ? '' : ' · ${o.str('sample_id')}'}',
              collection: Col.serviceOrders, id: o.id, routeId: 'lab.order', routeArgs: {'id': o.id}),
        ],
        data: {'status': status, 'elapsed_minutes': elapsed.inMinutes, 'target_minutes': stat ? 60 : tat},
      ));
    }
    return AgentReport(findings: findings);
  }
}

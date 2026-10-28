import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

/// Verified results with critical values that no doctor has acknowledged.
/// A critical potassium nobody has seen can kill; this must never wait for
/// the morning briefing.
class CriticalResultsAgent extends HmsAgent {
  @override
  String get id => 'lab.critical_results';
  @override
  String get name => 'Unacknowledged critical results';
  @override
  String get description =>
      'Raises an alert when a verified lab report has a critical value and no doctor has acknowledged it.';
  @override
  Set<String> get watches => const {LabCol.results};
  @override
  Duration get interval => const Duration(minutes: 10);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final since = ctx.now.subtract(const Duration(hours: 48));
    final rows = await ctx.db.query(Query(LabCol.results)
        .eq('critical', true)
        .eq('status', ResultStatus.verified)
        .gte('verified_at', since)
        .sort('verified_at', desc: true)
        .take(300));
    final open = rows.where((r) => r.date('acknowledged_at') == null).toList();
    if (open.isEmpty) return const AgentReport();
    final orders = await ctx.db.byIds(Col.serviceOrders, open.map((r) => r.strOrNull('order_id')));
    final patients = await ctx.db.byIds(Col.patients, open.map((r) => r.strOrNull('patient_id')));
    final tests = await LabService.testsByCode(ctx.db);
    final doctors = await ctx.db.byIds(Col.users, orders.values.map((o) => o.strOrNull('ordered_by')));

    final findings = <FindingDraft>[];
    for (final r in open) {
      final order = orders[r.str('order_id')];
      final patient = patients[r.str('patient_id')];
      final params = paramsOf(tests[r.str('test_code')]);
      final crit = criticalText(r.maps('values'), params);
      final who = patient?.str('full_name') ?? 'a patient';
      final doctor = doctors[order?.str('ordered_by')]?.str('display_name');
      final waited = ctx.now.difference(r.date('verified_at')!);
      findings.add(FindingDraft(
        key: 'result:${r.id}',
        subjectKey: 'order:${r.str('order_id')}',
        title: 'Critical result: $crit for $who',
        summary: '${order?.str('name') ?? 'Lab report'} was verified by ${r.str('verified_by_name', 'the pathologist')} '
            '${formatDuration(waited)} ago and no doctor has acknowledged it. '
            '${doctor == null ? 'Inform the treating doctor now.' : 'Call $doctor now.'}',
        severity: Severity.critical,
        category: 'patient safety',
        patientId: patient?.id,
        evidence: [
          Evidence('${order?.str('name') ?? 'Lab report'} · ${order?.str('sample_id') ?? ''}',
              collection: Col.serviceOrders, id: r.str('order_id'), routeId: 'lab.order', routeArgs: {'id': r.str('order_id')}),
          if (patient != null)
            Evidence('$who · ${patient.str('uhid')}',
                collection: Col.patients, id: patient.id, routeId: 'patients.profile', routeArgs: {'id': patient.id}),
        ],
        data: {'values': crit, 'test_code': r.str('test_code')},
      ));
    }
    return AgentReport(findings: findings);
  }
}

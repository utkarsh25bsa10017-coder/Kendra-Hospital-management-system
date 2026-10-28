import 'package:kendra_hms/core/core.dart';

import '../ipd_schema.dart';

/// Discharges signed off by the doctor but not completed after four hours.
/// The patient waits, the bed stays blocked and the family gets angry.
class DischargeDelayAgent extends HmsAgent {
  static const limit = Duration(hours: 4);

  @override
  String get id => 'ipd.discharge_delay';
  @override
  String get name => 'Discharge delays';
  @override
  String get description => 'Flags discharges that were signed off by the doctor more than 4 hours ago and are still not done.';
  @override
  Set<String> get watches => const {IpdCol.admissions};
  @override
  Duration get interval => const Duration(minutes: 30);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final pending = await ctx.db.query(Query(IpdCol.admissions).eq('status', IpdVals.dischargePending).take(1000));
    final patients = await ctx.db.byIds(Col.patients, pending.map((a) => a.strOrNull('patient_id')));
    final beds = await ctx.db.byIds(IpdCol.beds, pending.map((a) => a.strOrNull('bed_id')));
    final findings = <FindingDraft>[];
    for (final a in pending) {
      final since = a.date('discharge_requested_at') ?? a.updatedAt;
      final waited = ctx.now.difference(since);
      if (waited < limit) continue;
      final p = patients[a.str('patient_id')];
      final name = p?.str('full_name') ?? 'Patient';
      final bed = beds[a.str('bed_id')]?.str('label') ?? 'the bed';
      findings.add(FindingDraft(
        key: 'admission:${a.id}',
        title: 'Discharge waiting ${formatDuration(waited)}: $name',
        summary: 'The doctor signed off the discharge at ${formatTime(since)} and $bed is still blocked. '
            'Check what is holding it up (bill, medicines to return, papers) and complete the discharge.',
        severity: Severity.medium,
        category: 'bed management',
        patientId: p?.id,
        evidence: [
          Evidence('Admission ${a.str('number')}', collection: IpdCol.admissions, id: a.id, routeId: 'ipd.admission', routeArgs: {'id': a.id, 'tab': 'discharge'}),
        ],
      ));
    }
    return AgentReport(findings: findings);
  }
}

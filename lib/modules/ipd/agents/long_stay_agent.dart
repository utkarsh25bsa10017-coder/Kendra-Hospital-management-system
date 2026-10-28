import 'package:kendra_hms/core/core.dart';

import '../bed_days.dart';
import '../ipd_schema.dart';

/// Patients still in hospital after their expected discharge date, or for
/// more than [maxDays] days. Long stays are sometimes right, but they block
/// beds and often mean a plan that nobody updated.
class LongStayAgent extends HmsAgent {
  static const maxDays = 10;

  @override
  String get id => 'ipd.long_stay';
  @override
  String get name => 'Long stays';
  @override
  String get description => 'Points out inpatients past their expected discharge date or in hospital for more than 10 days.';
  @override
  Set<String> get watches => const {IpdCol.admissions};
  @override
  Duration get interval => const Duration(hours: 6);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final now = ctx.now;
    final today = ctx.startOfToday;
    final current = await ctx.db.query(Query(IpdCol.admissions).eq('status', IpdVals.admitted).take(2000));
    final patients = await ctx.db.byIds(Col.patients, current.map((a) => a.strOrNull('patient_id')));
    final wards = await ctx.db.byIds(IpdCol.wards, current.map((a) => a.strOrNull('ward_id')));
    final findings = <FindingDraft>[];
    for (final a in current) {
      final admitted = a.date('admitted_at');
      if (admitted == null) continue;
      final day = BedDays.dayNumber(admitted, now);
      final expected = a.date('expected_discharge');
      final overdue = expected != null && today.isAfter(startOfDay(expected));
      if (!overdue && day <= maxDays) continue;
      final p = patients[a.str('patient_id')];
      final name = p?.str('full_name') ?? 'Patient';
      final ward = wards[a.str('ward_id')]?.str('name') ?? 'the ward';
      final why = overdue
          ? 'expected discharge was ${formatDate(expected)}'
          : 'in hospital for more than $maxDays days';
      findings.add(FindingDraft(
        key: 'admission:${a.id}',
        title: 'Long stay: $name (day $day)',
        summary: '$name is on day $day in $ward; $why. Review the plan with the treating doctor '
            'or update the expected discharge date.',
        severity: Severity.low,
        category: 'bed management',
        patientId: p?.id,
        evidence: [
          Evidence('Admission ${a.str('number')}', collection: IpdCol.admissions, id: a.id, routeId: 'ipd.admission', routeArgs: {'id': a.id}),
        ],
      ));
    }
    return AgentReport(findings: findings);
  }
}

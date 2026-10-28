import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_schema.dart';

/// Vitals recorded in the last 24 hours that are dangerous: SpO2 below 90,
/// systolic 180+ or 90 and below, diastolic 120+, pulse over 130 or under
/// 45, temperature 39.5 °C or more.
class CriticalVitalsAgent extends HmsAgent {
  @override
  String get id => 'opd.critical_vitals';
  @override
  String get name => 'Critical vitals';
  @override
  String get description =>
      'Alerts when vitals recorded in OPD are dangerously abnormal, so a doctor sees the patient at once.';
  @override
  Set<String> get watches => const {OpdCol.consultations};
  @override
  Duration get interval => const Duration(minutes: 30);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final since = ctx.now.subtract(const Duration(hours: 24));
    final rows = await ctx.db.query(
        Query(OpdCol.consultations).gte('vitals_at', since).sort('vitals_at', desc: true).take(1000));
    final flagged = [
      for (final c in rows)
        if (Vitals.critical(c.map('vitals')).isNotEmpty) c,
    ];
    if (flagged.isEmpty) return const AgentReport();
    final patients = await ctx.db.byIds(Col.patients, flagged.map((c) => c.strOrNull('patient_id')));

    return AgentReport(findings: [
      for (final c in flagged)
        () {
          final v = c.map('vitals');
          final patient = patients[c.str('patient_id')];
          final name = patient?.str('full_name') ?? 'Patient';
          final by = c.strOrNull('vitals_by_name');
          final signed = c.str('status') == ConsultStatus.signed;
          return FindingDraft(
            key: 'vitals:${c.id}',
            title: 'Critical vitals: $name',
            summary: '${Vitals.critical(v).join(', ')} recorded ${formatDateTime(c.date('vitals_at'))}'
                '${by == null ? '' : ' by $by'}. Make sure a doctor has seen ${patient?.str('uhid') ?? 'the patient'} now.',
            severity: Severity.high,
            category: 'clinical',
            subjectKey: 'patient:${c.str('patient_id')}',
            patientId: c.strOrNull('patient_id'),
            evidence: [
              signed
                  ? Evidence('Consultation note · $name',
                      collection: OpdCol.consultations, id: c.id, routeId: 'opd.consultation', routeArgs: {'id': c.id})
                  : Evidence('Open the consultation · $name',
                      collection: OpdCol.consultations,
                      id: c.id,
                      routeId: 'opd.consult',
                      routeArgs: {'encounterId': c.str('encounter_id')}),
            ],
            data: {'vitals': v},
          );
        }(),
    ]);
  }
}

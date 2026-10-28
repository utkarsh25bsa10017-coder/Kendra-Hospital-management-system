import 'package:kendra_hms/core/core.dart';

import '../opd_schema.dart';
import '../opd_service.dart';

/// Consultations left as drafts for more than 12 hours. Until a note is
/// finished, its prescription, tests and consultation charge are not sent.
class UnsignedNotesAgent extends HmsAgent {
  @override
  String get id => 'opd.unsigned_notes';
  @override
  String get name => 'Unsigned notes';
  @override
  String get description =>
      'Flags consultations still in draft after 12 hours, so medicines, tests and the bill are not held up.';
  @override
  Set<String> get watches => const {OpdCol.consultations};
  @override
  Duration get interval => const Duration(hours: 1);

  static const maxAge = Duration(hours: 12);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final cutoff = ctx.now.subtract(maxAge);
    final drafts = [
      ...await ctx.db.query(Query(OpdCol.consultations)
          .eq('status', ConsultStatus.draft)
          .lt('started_at', cutoff)
          .sort('started_at')
          .take(500)),
      ...await ctx.db.query(Query(OpdCol.consultations)
          .eq('status', ConsultStatus.draft)
          .isNull('started_at')
          .lt('created_at', cutoff)
          .take(200)),
    ];
    if (drafts.isEmpty) return const AgentReport();
    final encounters = await ctx.db.byIds(Col.encounters, drafts.map((c) => c.strOrNull('encounter_id')));
    final patients = await ctx.db.byIds(Col.patients, drafts.map((c) => c.strOrNull('patient_id')));
    final doctors = await ctx.db.byIds(Col.users, drafts.map((c) => c.strOrNull('doctor_id')));

    final findings = <FindingDraft>[];
    for (final c in drafts) {
      final enc = encounters[c.str('encounter_id')];
      // A patient who left without being seen has nothing to sign.
      if (enc == null || enc.str('queue_status') == Vals.left || enc.str('status') == Vals.cancelled) continue;
      final patient = patients[c.str('patient_id')]?.str('full_name') ?? 'a patient';
      final doctorId = c.str('doctor_id');
      final doctor = doctorLabel(doctors[doctorId]?.str('display_name') ?? '');
      final started = c.date('started_at') ?? c.createdAt;
      findings.add(FindingDraft(
        key: 'consult:${c.id}',
        title: 'Unsigned note: $patient',
        summary: '$doctor opened this consultation on ${formatDateTime(started)} and has not finished it. '
            'Until it is finished, the prescription, tests and consultation charge are not sent.',
        severity: Severity.low,
        category: 'clinical',
        subjectKey: 'doctor:$doctorId',
        patientId: c.strOrNull('patient_id'),
        evidence: [
          Evidence('Open the consultation · $patient',
              collection: OpdCol.consultations,
              id: c.id,
              routeId: 'opd.consult',
              routeArgs: {'encounterId': c.str('encounter_id')}),
        ],
        data: {'doctor_id': doctorId, 'started_at': started.toIso8601String()},
      ));
    }
    return AgentReport(findings: findings);
  }
}

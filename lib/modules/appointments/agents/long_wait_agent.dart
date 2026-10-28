import 'package:kendra_hms/core/core.dart';

/// Watches the waiting room. A patient who has been checked in for a long
/// time without being called is usually forgotten, or the doctor is running
/// late and nobody told them.
class LongWaitAgent extends HmsAgent {
  static const mediumAfter = Duration(minutes: 45);
  static const highAfter = Duration(minutes: 90);

  @override
  String get id => 'appointments.long_wait';
  @override
  String get name => 'Long waits';
  @override
  String get description =>
      'Flags checked-in patients who have waited more than 45 minutes to see the doctor (90 minutes is urgent).';
  @override
  Set<String> get watches => const {Col.encounters};
  @override
  Duration get interval => const Duration(minutes: 5);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final visits = await ctx.db.query(Query(Col.encounters)
        .eq('type', Vals.opd)
        .eq('status', Vals.open)
        .eq('queue_status', Vals.waiting)
        .gte('checked_in_at', ctx.now.subtract(const Duration(hours: 18)))
        .sort('checked_in_at')
        .take(500));
    final long = visits.where((e) {
      final at = e.date('checked_in_at');
      return at != null && ctx.now.difference(at) > mediumAfter;
    }).toList();
    if (long.isEmpty) return const AgentReport();

    final doctors = await ctx.db.byIds(Col.users, long.map((e) => e.strOrNull('doctor_id')));
    final patients = await ctx.db.byIds(Col.patients, long.map((e) => e.str('patient_id')));
    final findings = <FindingDraft>[];
    for (final e in long) {
      final at = e.date('checked_in_at')!;
      final wait = ctx.now.difference(at);
      final doctor = doctors[e.str('doctor_id')]?.str('display_name') ?? 'the doctor';
      final patient = patients[e.str('patient_id')];
      final name = patient?.str('full_name') ?? 'A patient';
      final token = e.intOrNull('token_no');
      findings.add(FindingDraft(
        key: 'enc:${e.id}',
        title: 'Waiting ${formatDuration(wait)} for $doctor',
        summary: '$name${token == null ? '' : ' (token $token)'} checked in at ${formatTime(at)} and has not been called yet. '
            'Let the doctor know, or offer another doctor.',
        severity: wait > highAfter ? Severity.high : Severity.medium,
        category: 'patient experience',
        patientId: patient?.id,
        evidence: [
          if (patient != null)
            Evidence('$name · ${patient.str('uhid')}',
                collection: Col.patients, id: patient.id, routeId: 'patients.profile', routeArgs: {'id': patient.id}),
          Evidence('Waiting room${token == null ? '' : ', token $token'}',
              collection: Col.encounters, id: e.id, routeId: 'appointments.queue'),
        ],
        data: {'wait_minutes': wait.inMinutes, 'doctor_id': e.strOrNull('doctor_id'), 'token_no': token},
      ));
    }
    return AgentReport(findings: findings);
  }
}

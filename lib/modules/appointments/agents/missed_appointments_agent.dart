import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';

/// Appointments still "booked" long after their time: the patient never
/// came. Suggests marking them as no-shows in one go, so the day view and
/// no-show numbers stay true.
class MissedAppointmentsAgent extends HmsAgent {
  static const grace = Duration(hours: 2);

  @override
  String get id => 'appointments.missed';
  @override
  String get name => 'Missed appointments';
  @override
  String get description =>
      'Finds booked appointments more than 2 hours past their time and suggests marking them as no-shows.';
  @override
  Set<String> get watches => const {ApptCol.appointments};
  @override
  Duration get interval => const Duration(minutes: 30);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final missed = await ctx.db.query(Query(ApptCol.appointments)
        .eq('status', ApptStatus.booked)
        .gte('start_at', ctx.startOfToday.subtract(const Duration(days: 7)))
        .lt('start_at', ctx.now.subtract(grace))
        .sort('start_at')
        .take(500));
    if (missed.isEmpty) return const AgentReport();

    final patients = await ctx.db.byIds(Col.patients, missed.map((a) => a.str('patient_id')));
    final doctors = await ctx.db.byIds(Col.users, missed.map((a) => a.str('doctor_id')));
    String line(Rec a) {
      final start = a.date('start_at')!;
      final when = sameDay(start, ctx.now) ? formatTime(start) : '${formatDateShort(start)} ${formatTime(start)}';
      return '${patients[a.str('patient_id')]?.str('full_name') ?? 'Patient'} '
          '($when, ${doctors[a.str('doctor_id')]?.str('display_name') ?? 'doctor'})';
    }

    final n = missed.length;
    final shown = missed.take(5).map(line).join(', ');
    return AgentReport(proposals: [
      ProposalDraft(
        key: 'missed:${compactDay(ctx.now)}',
        title: 'Mark ${plural(n, 'missed appointment')} as no-show',
        summary: '${n == 1 ? 'This patient was' : 'These patients were'} booked but never checked in: $shown'
            '${n > 5 ? ' and ${n - 5} more' : ''}. Anyone who has arrived since is skipped.',
        handler: 'appointments.mark_no_show',
        payload: {'appointment_ids': [for (final a in missed) a.id]},
      ),
    ]);
  }
}

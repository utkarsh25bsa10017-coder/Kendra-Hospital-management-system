import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';
import 'common.dart';

/// "Appointments" tab on the patient profile: what's coming and what happened.
class PatientAppointmentsTab extends StatelessWidget {
  const PatientAppointmentsTab({super.key, required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(List<Rec>, Map<String, Rec>, Map<String, Rec>)>(
      watch: const {ApptCol.appointments, Col.encounters},
      deps: [patient.id],
      load: (db) async {
        final appts = await db.query(
            Query(ApptCol.appointments).eq('patient_id', patient.id).sort('start_at', desc: true).take(60));
        final doctors = await db.byIds(Col.users, appts.map((a) => a.str('doctor_id')));
        final encs = await db.byIds(Col.encounters, appts.map((a) => a.strOrNull('encounter_id')));
        return (appts, doctors, encs);
      },
      builder: (context, data) {
        final (appts, doctors, encs) = data;
        final today = dayOf(DateTime.now());
        String status(Rec a) => AppointmentService.effectiveStatus(a, encs[a.str('encounter_id')]);
        bool active(Rec a) {
          final s = status(a);
          return s == ApptStatus.checkedIn ||
              s == ApptStatus.inConsultation ||
              (s == ApptStatus.booked && !a.date('start_at')!.isBefore(today));
        }

        final upcoming = appts.where(active).toList().reversed.toList();
        final past = appts.where((a) => !upcoming.contains(a)).toList();
        final canBook = context.can(AppointmentPerms.manage);
        final visits = past.where((a) => status(a) == ApptStatus.completed).length;
        final missed = past.where((a) => status(a) == ApptStatus.noShow).length;
        final theme = Theme.of(context);

        Widget row(Rec a) {
          final s = status(a);
          final start = a.date('start_at')!;
          final doctor = doctors[a.str('doctor_id')];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Row(children: [
              _DateBox(start),
              Gap.h12,
              Expanded(
                child: TwoLine(
                  '${dayLabel(start)}, ${formatTime(start)}${start.year != today.year ? ' · ${start.year}' : ''}',
                  [
                    doctor?.str('display_name') ?? 'Doctor',
                    if (a.str('kind') != ApptKind.booked) ApptKind.label(a.str('kind')),
                    a.str('reason'),
                  ].where((x) => x.isNotEmpty).join(' · '),
                ),
              ),
              Gap.h8,
              ApptStatusChip(s),
              ApptActionsBar(
                appointment: a,
                status: s,
                patientName: patient.str('full_name'),
                showPrimary: false,
              ),
            ]),
          );
        }

        Widget list(List<Rec> items) => Column(children: [
              for (final (i, a) in items.indexed) ...[if (i > 0) const Divider(height: 1), row(a)],
            ]);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Today and upcoming',
              trailing: canBook
                  ? FilledButton.tonalIcon(
                      onPressed: () => context.app.nav.open('appointments.book', {'patientId': patient.id}),
                      icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                      label: const Text('Book'),
                    )
                  : null,
              child: upcoming.isEmpty
                  ? Text('No upcoming appointments.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : list(upcoming),
            ),
            Gap.v16,
            SectionCard(
              title: 'Past',
              subtitle: past.isEmpty ? null : '${plural(visits, 'visit')}${missed > 0 ? ' · ${plural(missed, 'no-show')}' : ''}',
              child: past.isEmpty
                  ? Text('No appointments yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : list(past),
            ),
          ],
        );
      },
    );
  }
}

class _DateBox extends StatelessWidget {
  const _DateBox(this.date);
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(Radii.sm)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(formatDateShort(date).split(' ').last.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
        Text('${date.day}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
      ]),
    );
  }
}

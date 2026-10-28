import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';

/// Dashboard tile: today's appointments by status. Tap to open the day view.
class TodayAppointmentsCard extends StatelessWidget {
  const TodayAppointmentsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<Map<String, int>>(
      watch: const {ApptCol.appointments, Col.encounters},
      load: (db) async {
        final appts = await AppointmentService.appointmentsOn(db, DateTime.now());
        final encs = await db.byIds(Col.encounters, appts.map((a) => a.strOrNull('encounter_id')));
        final out = <String, int>{};
        for (final a in appts) {
          out.update(AppointmentService.effectiveStatus(a, encs[a.str('encounter_id')]), (v) => v + 1, ifAbsent: () => 1);
        }
        return out;
      },
      builder: (context, counts) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final total = counts.entries.where((e) => e.key != ApptStatus.cancelled).fold(0, (n, e) => n + e.value);
        final canOpen = context.app.nav.canOpen('appointments.today');
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: canOpen ? () => context.app.nav.open('appointments.today') : null,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Icon(Icons.event_available_outlined, size: 20, color: cs.onSurfaceVariant),
                    Gap.h8,
                    Expanded(
                      child: Text("Today's appointments",
                          style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (canOpen) Icon(Icons.chevron_right, size: 18, color: cs.outline),
                  ]),
                  Gap.v12,
                  Text('$total',
                      style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  Gap.v8,
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final s in [
                      ApptStatus.booked,
                      ApptStatus.checkedIn,
                      ApptStatus.inConsultation,
                      ApptStatus.completed,
                      ApptStatus.noShow,
                    ])
                      if ((counts[s] ?? 0) > 0 || s != ApptStatus.noShow)
                        StatusChip('${counts[s] ?? 0} ${ApptStatus.label(s).toLowerCase()}', tone: ApptStatus.tone(s)),
                  ]),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

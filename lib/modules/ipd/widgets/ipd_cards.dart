import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../bed_days.dart';
import '../ipd_schema.dart';
import 'ipd_widgets.dart';

/// Dashboard: how full the hospital is, by ward.
class OccupancyCard extends StatelessWidget {
  const OccupancyCard({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<BoardData>(
      watch: const {IpdCol.beds, IpdCol.wards, IpdCol.admissions},
      load: BoardData.load,
      builder: (context, data) {
        final theme = Theme.of(context);
        final total = data.total();
        final occupied = data.count(IpdVals.occupied);
        final pct = total == 0 ? 0 : (occupied * 100 / total).round();
        return SectionCard(
          title: 'Bed occupancy',
          subtitle: '${data.count(IpdVals.available)} free · ${data.count(IpdVals.cleaning)} in cleaning',
          trailing: TextButton(onPressed: () => context.app.nav.open('ipd.beds'), child: const Text('Bed board')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$pct%', style: theme.textTheme.headlineMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  Gap.h12,
                  Expanded(
                    child: Text('$occupied of $total beds occupied',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ],
              ),
              Gap.v8,
              ShareBars(
                items: [for (final w in data.wards) ('${w.str('name')} (${data.total(w.id)})', data.count(IpdVals.occupied, w.id))],
                format: (v) => '${v.toInt()} in',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Dashboard: admissions and discharges since midnight.
class AdmissionsTodayCard extends StatelessWidget {
  const AdmissionsTodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(int, int, int)>(
      watch: const {IpdCol.admissions},
      load: (db) async {
        final today = startOfDay(DateTime.now());
        final tomorrow = endOfDay(today);
        return (
          await db.count(Query(IpdCol.admissions).between('admitted_at', today, tomorrow)),
          await db.count(Query(IpdCol.admissions).eq('status', IpdVals.discharged).between('discharged_at', today, tomorrow)),
          await db.count(const Query(IpdCol.admissions).eq('status', IpdVals.dischargePending)),
        );
      },
      builder: (context, d) {
        final (admitted, discharged, pending) = d;
        return KpiTile(
          label: 'Admissions & discharges today',
          value: '$admitted in · $discharged out',
          icon: Icons.swap_vert,
          tone: Tone.info,
          caption: pending == 0 ? 'No discharge waiting' : '${plural(pending, 'discharge')} waiting to be completed',
          onTap: () => context.app.nav.open('ipd.admissions'),
        );
      },
    );
  }
}

/// Dashboard: average length of stay of discharges in the last 30 days.
class AverageStayCard extends StatelessWidget {
  const AverageStayCard({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(double, int)>(
      watch: const {IpdCol.admissions},
      load: (db) async {
        final now = DateTime.now();
        final list = await db.query(Query(IpdCol.admissions)
            .eq('status', IpdVals.discharged)
            .gte('discharged_at', now.subtract(const Duration(days: 30)))
            .take(5000));
        if (list.isEmpty) return (0.0, 0);
        final days = list.fold<int>(
            0, (a, r) => a + BedDays.count(admittedAt: r.date('admitted_at')!, dischargedAt: r.date('discharged_at'), now: now));
        return (days / list.length, list.length);
      },
      builder: (context, d) {
        final (avg, n) = d;
        return KpiTile(
          label: 'Average stay (30 days)',
          value: n == 0 ? '—' : '${avg.toStringAsFixed(1)} days',
          icon: Icons.hotel_outlined,
          caption: n == 0 ? 'No discharges yet' : 'Over ${plural(n, 'discharge')}',
          onTap: () => context.app.nav.open('ipd.admissions'),
        );
      },
    );
  }
}

/// Patient profile tab: every stay of this patient.
class PatientAdmissionsTab extends StatelessWidget {
  const PatientAdmissionsTab({super.key, required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return LiveBuilder<(List<Rec>, Map<String, Rec>, Map<String, Rec>)>(
      watch: const {IpdCol.admissions},
      deps: [patient.id],
      load: (db) async {
        final list = await db.query(Query(IpdCol.admissions).eq('patient_id', patient.id).sort('admitted_at', desc: true).take(100));
        return (
          list,
          await db.byIds(IpdCol.beds, list.map((a) => a.strOrNull('bed_id'))),
          await db.byIds(IpdCol.wards, list.map((a) => a.strOrNull('ward_id'))),
        );
      },
      builder: (context, data) {
        final (list, beds, wards) = data;
        final now = DateTime.now();
        final current = list.where((a) => a.str('status') != IpdVals.discharged).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (current != null) ...[
              ToneBanner(
                tone: Tone.info,
                icon: Icons.king_bed_outlined,
                title: 'In hospital: ${beds[current.str('bed_id')]?.str('label') ?? ''} · ${wards[current.str('ward_id')]?.str('name') ?? ''}',
                message:
                    'Day ${BedDays.dayNumber(current.date('admitted_at')!, now)} · ${current.str('diagnosis')}',
                action: FilledButton(
                  onPressed: () => app.nav.open('ipd.admission', {'id': current.id}),
                  child: const Text('Open'),
                ),
              ),
              Gap.v16,
            ],
            DataList<Rec>(
              items: list,
              empty: EmptyState(
                icon: Icons.king_bed_outlined,
                title: 'Never admitted',
                action: context.can(IpdPerms.admit)
                    ? FilledButton.icon(
                        onPressed: () => app.nav.open('ipd.admit', {'patientId': patient.id}),
                        icon: const Icon(Icons.king_bed_outlined),
                        label: const Text('Admit'))
                    : null,
              ),
              onTap: (a) => app.nav.open('ipd.admission', {'id': a.id}),
              title: (a) => a.str('diagnosis', 'Admission'),
              subtitle: (a) => [
                a.str('number'),
                formatDate(a.date('admitted_at')),
                wards[a.str('ward_id')]?.str('name') ?? '',
              ].where((s) => s.isNotEmpty).join(' · '),
              trailing: (a) => AdmissionStatusChip(a.str('status')),
              columns: [
                ListColumn('Admission', (a) => TwoLine(a.str('number'), formatDate(a.date('admitted_at'))), flex: 2),
                ListColumn('Diagnosis', (a) => Text(a.str('diagnosis', '—'), overflow: TextOverflow.ellipsis), flex: 4),
                ListColumn('Ward', (a) => Text(wards[a.str('ward_id')]?.str('name') ?? '—'), flex: 2),
                ListColumn(
                    'Stay',
                    (a) => Text(a.str('status') == IpdVals.discharged
                        ? plural(BedDays.count(admittedAt: a.date('admitted_at')!, dischargedAt: a.date('discharged_at'), now: now), 'bed-day')
                        : 'Day ${BedDays.dayNumber(a.date('admitted_at')!, now)}'),
                    flex: 2),
                ListColumn('Status', (a) => AdmissionStatusChip(a.str('status')), width: 150),
              ],
            ),
          ],
        );
      },
    );
  }
}

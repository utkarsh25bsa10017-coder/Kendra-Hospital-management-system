import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_schema.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';

class _SummaryData {
  _SummaryData({
    required this.visits,
    required this.doctors,
    required this.lastRx,
    required this.lastRxDate,
    required this.results,
    required this.pending,
  });
  final List<Rec> visits;
  final Map<String, Rec> doctors;
  final Rec? lastRx;
  final DateTime? lastRxDate;
  final List<Rec> results;
  final List<Rec> pending;
}

/// What the doctor needs to know before writing: earlier visits, current
/// medicines, recent results and how the vitals have moved.
class PatientSummaryPane extends StatelessWidget {
  const PatientSummaryPane({super.key, required this.patient, required this.encounterId, this.onRepeat});
  final Rec patient;
  final String encounterId;
  final VoidCallback? onRepeat;

  Future<_SummaryData> _load(ReadDb db) async {
    final visits = (await db.query(Query(OpdCol.consultations)
            .eq('patient_id', patient.id)
            .eq('status', ConsultStatus.signed)
            .sort('started_at', desc: true)
            .take(12)))
        .where((c) => c.str('encounter_id') != encounterId)
        .toList();
    final doctors = await db.byIds(Col.users, visits.map((c) => c.strOrNull('doctor_id')));
    final last = await OpdService.lastPrescription(db, patient.id, excludeEncounterId: encounterId);
    final orders = await db.query(Query(Col.serviceOrders).eq('patient_id', patient.id).sort('ordered_at', desc: true).take(40));
    return _SummaryData(
      visits: visits,
      doctors: doctors,
      lastRx: last?.$1,
      lastRxDate: last?.$2,
      results: orders.where((o) => o.str('result_summary').trim().isNotEmpty).take(6).toList(),
      pending: orders
          .where((o) => o.str('result_summary').trim().isEmpty && o.str('encounter_id') != encounterId)
          .where((o) => const [Vals.ordered, Vals.collected, Vals.inProgress].contains(o.str('status')))
          .take(4)
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_SummaryData>(
      watch: const {OpdCol.consultations, Col.prescriptions, Col.serviceOrders},
      deps: [patient.id, encounterId],
      load: _load,
      builder: (context, d) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PatientCard(patient: patient),
          Gap.v12,
          _Visits(data: d),
          Gap.v12,
          _Medicines(data: d, onRepeat: onRepeat),
          Gap.v12,
          _Results(data: d),
          if (d.visits.any((c) => c.map('vitals').isNotEmpty)) ...[
            Gap.v12,
            _VitalsTrend(visits: d.visits),
          ],
        ],
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = patient;
    final app = context.app;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Avatar(p.str('full_name'), size: 44),
            Gap.h12,
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.str('full_name'), style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Caption(patientLine(p)),
              ]),
            ),
            if (app.registry.route('patients.profile') != null)
              IconButton(
                tooltip: 'Open patient profile',
                icon: const Icon(Icons.open_in_new, size: 20),
                onPressed: () => app.nav.open('patients.profile', {'id': p.id}),
              ),
          ]),
          Gap.v12,
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusChip(payerLabel(p), tone: payerTone(p)),
            if (p.strOrNull('blood_group') != null) StatusChip('Blood ${p.str('blood_group')}', icon: Icons.bloodtype_outlined),
            if (p.strOrNull('phone') != null) StatusChip(p.str('phone'), icon: Icons.phone_outlined),
            if (Allergy.isNone(p.str('allergies')))
              const StatusChip('No known allergies', icon: Icons.check_circle_outline, tone: Tone.success)
            else
              StatusChip('Allergies: ${p.str('allergies')}', icon: Icons.warning_amber_rounded, tone: Tone.danger),
          ]),
        ],
      ),
    );
  }
}

class _Visits extends StatelessWidget {
  const _Visits({required this.data});
  final _SummaryData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visits = data.visits.take(3).toList();
    return SectionCard(
      title: 'Last visits',
      subtitle: data.visits.isEmpty ? null : '${plural(data.visits.length, 'earlier note')} in Kendra',
      child: visits.isEmpty
          ? const Caption('First visit — no earlier notes.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in visits)
                  InkWell(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: () => context.app.nav.open('opd.consultation', {'id': c.id}),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(formatDateShort(c.date('started_at') ?? c.createdAt),
                                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.str('diagnosis', 'No diagnosis recorded'),
                                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                Caption([
                                  doctorLabel(data.doctors[c.str('doctor_id')]?.str('display_name') ?? ''),
                                  if (c.str('chief_complaint').isNotEmpty) c.str('chief_complaint'),
                                ].join(' · ')),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Medicines extends StatelessWidget {
  const _Medicines({required this.data, this.onRepeat});
  final _SummaryData data;
  final VoidCallback? onRepeat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = data.lastRx?.maps('items') ?? const [];
    return SectionCard(
      title: 'Current medicines',
      subtitle: data.lastRxDate == null ? null : 'From the ${formatDate(data.lastRxDate)} prescription',
      trailing: items.isEmpty || onRepeat == null
          ? null
          : TextButton.icon(onPressed: onRepeat, icon: const Icon(Icons.replay, size: 18), label: const Text('Repeat')),
      child: items.isEmpty
          ? const Caption('No earlier prescription.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(Icons.medication_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                      ),
                      Gap.h8,
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(m['drug_name'] as String? ?? '', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                          Caption(Rx.line(m)),
                        ]),
                      ),
                    ]),
                  ),
              ],
            ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.data});
  final _SummaryData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Recent results',
      child: data.results.isEmpty && data.pending.isEmpty
          ? const Caption('No lab results yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final o in data.results)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text(o.str('name'),
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (o.flag('critical'))
                          const StatusChip('Critical', tone: Tone.danger)
                        else if (o.flag('abnormal'))
                          const StatusChip('Abnormal', tone: Tone.warning),
                        Gap.h8,
                        Caption(formatDateShort(o.date('resulted_at') ?? o.date('ordered_at')!)),
                      ]),
                      Text(o.str('result_summary'),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: o.flag('abnormal') || o.flag('critical')
                                  ? ToneColors.of(context, Tone.danger).foreground
                                  : theme.colorScheme.onSurface)),
                    ]),
                  ),
                if (data.pending.isNotEmpty) ...[
                  if (data.results.isNotEmpty) const Divider(height: 16),
                  for (final o in data.pending)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Expanded(child: Text(o.str('name'), overflow: TextOverflow.ellipsis)),
                        StatusChip(titleCase(o.str('status')), tone: Tone.info),
                      ]),
                    ),
                ],
              ],
            ),
    );
  }
}

class _VitalsTrend extends StatelessWidget {
  const _VitalsTrend({required this.visits});
  final List<Rec> visits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = visits.where((c) => c.map('vitals').isNotEmpty).take(5).toList();
    final cols = <(String, String Function(Map<String, Object?>), VitalLevel Function(Map<String, Object?>))>[
      ('BP', Vitals.bpText, Vitals.bpLevel),
      ('Pulse', (v) => Vitals.fmt(Vitals.value(v, VitalKeys.pulse)), (v) => Vitals.level(VitalKeys.pulse, Vitals.value(v, VitalKeys.pulse))),
      ('SpO2', (v) => Vitals.fmt(Vitals.value(v, VitalKeys.spo2)), (v) => Vitals.level(VitalKeys.spo2, Vitals.value(v, VitalKeys.spo2))),
      ('Wt', (v) => Vitals.fmt(Vitals.value(v, VitalKeys.weightKg)), (v) => VitalLevel.normal),
      ('Sugar', (v) => Vitals.fmt(Vitals.value(v, VitalKeys.grbs)), (v) => Vitals.level(VitalKeys.grbs, Vitals.value(v, VitalKeys.grbs))),
    ].where((col) => rows.any((c) => col.$2(c.map('vitals')).isNotEmpty)).toList();
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    return SectionCard(
      title: 'Vitals trend',
      child: Table(
        columnWidths: const {0: FlexColumnWidth(1.2)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('DATE', style: head)),
            for (final col in cols) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(col.$1.toUpperCase(), style: head)),
          ]),
          for (final c in rows)
            TableRow(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(formatDateShort(c.date('started_at') ?? c.createdAt), style: theme.textTheme.bodySmall),
              ),
              for (final col in cols)
                Text(
                  col.$2(c.map('vitals')).isEmpty ? '–' : col.$2(c.map('vitals')),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: col.$3(c.map('vitals')) == VitalLevel.normal ? null : FontWeight.w700,
                    color: col.$3(c.map('vitals')) == VitalLevel.normal
                        ? null
                        : ToneColors.of(context, toneForLevel(col.$3(c.map('vitals')))).foreground,
                  ),
                ),
            ]),
        ],
      ),
    );
  }
}

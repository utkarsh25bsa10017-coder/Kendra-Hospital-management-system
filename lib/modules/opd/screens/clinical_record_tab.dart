import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_schema.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';

class _RecordData {
  _RecordData({
    required this.consultations,
    required this.doctors,
    required this.prescriptions,
    required this.rxDates,
    required this.orders,
  });
  final List<Rec> consultations;
  final Map<String, Rec> doctors;
  final List<Rec> prescriptions;
  final Map<String, DateTime> rxDates;
  final List<Rec> orders;
}

/// The "Clinical record" tab on the patient profile: every consultation,
/// the medicines prescribed, and tests with their results.
class ClinicalRecordTab extends StatelessWidget {
  const ClinicalRecordTab({super.key, required this.patient});
  final Rec patient;

  Future<_RecordData> _load(ReadDb db) async {
    final consultations = await db.query(
        Query(OpdCol.consultations).eq('patient_id', patient.id).sort('started_at', desc: true).take(60));
    final prescriptions = await db.query(Query(Col.prescriptions).eq('patient_id', patient.id).take(40));
    final orders = await db.query(Query(Col.serviceOrders).eq('patient_id', patient.id).sort('ordered_at', desc: true).take(30));
    final doctors = await db.byIds(Col.users, [
      ...consultations.map((c) => c.strOrNull('doctor_id')),
      ...prescriptions.map((r) => r.strOrNull('doctor_id')),
    ]);
    final encs = await db.byIds(Col.encounters, prescriptions.map((r) => r.strOrNull('encounter_id')));
    final dates = {for (final r in prescriptions) r.id: encs[r.str('encounter_id')]?.date('started_at') ?? r.createdAt};
    prescriptions.sort((a, b) => dates[b.id]!.compareTo(dates[a.id]!));
    return _RecordData(
      consultations: consultations,
      doctors: doctors,
      prescriptions: prescriptions.take(10).toList(),
      rxDates: dates,
      orders: orders,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_RecordData>(
      watch: const {OpdCol.consultations, Col.prescriptions, Col.serviceOrders},
      deps: [patient.id],
      load: _load,
      builder: (context, d) => LayoutBuilder(builder: (context, c) {
        final timeline = _Timeline(data: d, patient: patient);
        final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _MedicinesHistory(data: d),
          Gap.v16,
          _Orders(data: d),
        ]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AllergyLine(patient.str('allergies')),
            Gap.v16,
            if (c.maxWidth >= 900)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: timeline),
                Gap.h16,
                Expanded(flex: 2, child: side),
              ])
            else ...[
              timeline,
              Gap.v16,
              side,
            ],
          ],
        );
      }),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.data, required this.patient});
  final _RecordData data;
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final me = context.session?.userId;
    final canConsult = context.can(OpdPerms.consult);
    final items = data.consultations;
    return SectionCard(
      title: 'Consultations',
      subtitle: items.isEmpty ? null : '${plural(items.length, 'visit')} · latest first',
      child: items.isEmpty
          ? const EmptyState(
              icon: Icons.medical_services_outlined,
              title: 'No consultations yet',
              message: 'Notes written in OPD appear here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in items.indexed)
                  _TimelineEntry(
                    consultation: c,
                    doctor: data.doctors[c.str('doctor_id')],
                    last: i == items.length - 1,
                    onTap: () {
                      final signed = c.str('status') == ConsultStatus.signed;
                      if (signed) {
                        context.app.nav.open('opd.consultation', {'id': c.id});
                      } else if (canConsult && c.str('doctor_id') == me) {
                        context.app.nav.open('opd.consult', {'encounterId': c.str('encounter_id')});
                      } else {
                        context.app.nav.open('opd.consultation', {'id': c.id});
                      }
                    },
                    lineColor: cs.outlineVariant,
                  ),
              ],
            ),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.consultation,
    required this.doctor,
    required this.last,
    required this.onTap,
    required this.lineColor,
  });
  final Rec consultation;
  final Rec? doctor;
  final bool last;
  final VoidCallback onTap;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = consultation;
    final when = c.date('started_at') ?? c.createdAt;
    final signed = c.str('status') == ConsultStatus.signed;
    final rx = c.maps('rx_draft').length;
    final tests = c.maps('orders_draft').length;
    final vitals = Vitals.summary(c.map('vitals'));
    final critical = Vitals.critical(c.map('vitals'));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 52,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(children: [
                  Text('${when.day}', style: theme.textTheme.titleLarge?.copyWith(height: 1, color: cs.primary)),
                  Caption(formatDateShort(when).split(' ').last.toUpperCase(), maxLines: 1),
                  Caption('${when.year}', maxLines: 1),
                ]),
              ),
            ),
            SizedBox(
              width: 20,
              child: Column(children: [
                Container(width: 2, height: 14, color: lineColor),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: signed ? cs.primary : cs.secondary, shape: BoxShape.circle),
                ),
                if (!last) Expanded(child: Container(width: 2, color: lineColor)),
              ]),
            ),
            Gap.h8,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: Gap.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(c.str('diagnosis', signed ? 'No diagnosis recorded' : 'Consultation in progress'),
                          style: theme.textTheme.titleSmall),
                      if (c.str('icd_code').isNotEmpty) Caption(c.str('icd_code'), maxLines: 1),
                      if (!signed) const StatusChip('Draft', tone: Tone.warning),
                      if (c.date('amended_at') != null) const StatusChip('Amended', tone: Tone.info),
                    ]),
                    Gap.v4,
                    Caption([
                      doctorLabel(doctor?.str('display_name') ?? ''),
                      if ((doctor?.str('department') ?? '').isNotEmpty) doctor!.str('department'),
                      formatTime(when),
                    ].join(' · ')),
                    if (c.str('chief_complaint').isNotEmpty) ...[
                      Gap.v4,
                      Text(c.str('chief_complaint'), maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    ],
                    if (vitals.isNotEmpty || rx > 0 || tests > 0) ...[
                      Gap.v8,
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        if (critical.isNotEmpty)
                          InfoPill(critical.join(' · '), icon: Icons.priority_high, tone: Tone.danger)
                        else if (vitals.isNotEmpty)
                          InfoPill(vitals, icon: Icons.monitor_heart_outlined),
                        if (rx > 0) StatusChip(plural(rx, 'medicine'), icon: Icons.medication_outlined),
                        if (tests > 0) StatusChip(plural(tests, 'test'), icon: Icons.biotech_outlined),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Icon(Icons.chevron_right, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _MedicinesHistory extends StatelessWidget {
  const _MedicinesHistory({required this.data});
  final _RecordData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Medicines',
      subtitle: data.prescriptions.isEmpty ? null : 'Prescriptions, latest first',
      child: data.prescriptions.isEmpty
          ? const Caption('No medicines prescribed yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, r) in data.prescriptions.indexed) ...[
                  if (i > 0) const Divider(height: 20),
                  Row(children: [
                    Expanded(
                      child: Text(
                        '${formatDate(data.rxDates[r.id])} · ${doctorLabel(data.doctors[r.str('doctor_id')]?.str('display_name') ?? '')}',
                        style: theme.textTheme.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    StatusChip(
                      switch (r.str('status')) {
                        Vals.dispensed => 'Dispensed',
                        Vals.partiallyDispensed => 'Part dispensed',
                        _ => 'Not dispensed',
                      },
                      tone: switch (r.str('status')) {
                        Vals.dispensed => Tone.success,
                        Vals.partiallyDispensed => Tone.warning,
                        _ => Tone.neutral,
                      },
                    ),
                  ]),
                  Gap.v4,
                  for (final m in r.maps('items'))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: m['drug_name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(
                            text: '  ${Rx.line(m)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ])),
                    ),
                ],
              ],
            ),
    );
  }
}

class _Orders extends StatelessWidget {
  const _Orders({required this.data});
  final _RecordData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Tests and results',
      child: data.orders.isEmpty
          ? const Caption('No tests ordered yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, o) in data.orders.indexed) ...[
                  if (i > 0) const Divider(height: 16),
                  Row(children: [
                    Icon(o.str('order_type') == Vals.radiology ? Icons.image_outlined : Icons.biotech_outlined,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    Gap.h8,
                    Expanded(
                      child: Text(o.str('name'),
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                    ),
                    Caption(formatDateShort(o.date('ordered_at')!), maxLines: 1),
                    Gap.h8,
                    StatusChip(
                      switch (o.str('status')) {
                        Vals.resulted => 'Resulted',
                        Vals.verified => 'Verified',
                        Vals.collected => 'Collected',
                        Vals.inProgress => 'In progress',
                        Vals.cancelled => 'Cancelled',
                        _ => 'Ordered',
                      },
                      tone: switch (o.str('status')) {
                        Vals.resulted || Vals.verified => (o.flag('abnormal') || o.flag('critical')) ? Tone.danger : Tone.success,
                        Vals.cancelled => Tone.neutral,
                        _ => Tone.info,
                      },
                    ),
                  ]),
                  if (o.str('result_summary').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 26, top: 2),
                      child: Text(o.str('result_summary'),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: o.flag('abnormal') || o.flag('critical')
                                  ? ToneColors.of(context, Tone.danger).foreground
                                  : theme.colorScheme.onSurfaceVariant)),
                    ),
                ],
              ],
            ),
    );
  }
}

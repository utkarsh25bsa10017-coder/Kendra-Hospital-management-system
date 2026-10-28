import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_schema.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';
import 'prescription_print.dart';

/// A consultation with everything its note shows: the patient, the visit,
/// the doctor, the prescription, the tests ordered and the amendments.
class NoteData {
  NoteData({
    required this.consultation,
    required this.patient,
    required this.encounter,
    required this.doctor,
    required this.prescription,
    required this.orders,
    required this.amendments,
  });
  final Rec consultation;
  final Rec? patient;
  final Rec? encounter;
  final Rec? doctor;
  final Rec? prescription;
  final List<Rec> orders;
  final List<Rec> amendments;

  bool get signed => consultation.str('status') == ConsultStatus.signed;

  /// The medicines: as sent to the pharmacy, or the draft before signing.
  List<Map<String, Object?>> get items => prescription?.maps('items') ?? consultation.maps('rx_draft');

  /// The tests: as ordered (with results when back), or the draft before signing.
  List<Map<String, Object?>> get orderRows => orders.isNotEmpty
      ? [for (final o in orders) {'name': o.str('name'), 'priority': o.str('priority'), 'status': o.str('status'), 'result': o.str('result_summary')}]
      : [for (final o in consultation.maps('orders_draft')) {'name': o['name'], 'priority': o['priority'], 'status': null, 'result': null}];

  static Future<NoteData?> load(ReadDb db, String consultationId) async {
    final c = await db.get(OpdCol.consultations, consultationId);
    if (c == null) return null;
    final rxId = c.strOrNull('prescription_id');
    return NoteData(
      consultation: c,
      patient: await db.get(Col.patients, c.str('patient_id')),
      encounter: await db.get(Col.encounters, c.str('encounter_id')),
      doctor: await db.get(Col.users, c.str('doctor_id')),
      prescription: rxId == null ? null : await db.get(Col.prescriptions, rxId),
      orders: await db.query(Query(Col.serviceOrders).eq('encounter_id', c.str('encounter_id')).sort('ordered_at').take(50)),
      amendments: await db.query(Query(OpdCol.amendments).eq('consultation_id', c.id).sort('created_at').take(50)),
    );
  }
}

/// A signed consultation as the patient's printed OPD slip would read,
/// with the amendment history underneath.
class ConsultationNoteScreen extends StatelessWidget {
  const ConsultationNoteScreen({super.key, required this.consultationId});
  final String consultationId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<NoteData?>(
      watch: const {OpdCol.consultations, OpdCol.amendments, Col.serviceOrders, Col.prescriptions},
      deps: [consultationId],
      load: (db) => NoteData.load(db, consultationId),
      builder: (context, d) {
        if (d == null) {
          return const PageScaffold(
            title: 'Consultation',
            body: EmptyState(icon: Icons.description_outlined, title: 'Consultation not found'),
          );
        }
        final c = d.consultation;
        final signed = c.str('status') == ConsultStatus.signed;
        final canAmend = signed && context.can(OpdPerms.consult) && c.str('signed_by') == context.session?.userId;
        final canContinue = !signed && context.can(OpdPerms.consult);
        final when = c.date('started_at') ?? c.createdAt;
        return PageScaffold(
          title: d.patient?.str('full_name') ?? 'Consultation',
          subtitle: 'OPD consultation · ${formatDateTime(when)}',
          maxWidth: 920,
          actions: [
            PrintButton(
              label: 'Print prescription',
              name: prescriptionName(d),
              build: () => prescriptionPdf(d, Letterhead.of(context.app.settings)),
            ),
            if (canAmend && !context.isCompact) ...[
              Gap.h8,
              OutlinedButton.icon(
                onPressed: () => showAmendSheet(context, c),
                icon: const Icon(Icons.edit_note),
                label: const Text('Amend'),
              ),
            ],
            if (canAmend && context.isCompact)
              IconButton(tooltip: 'Amend', onPressed: () => showAmendSheet(context, c), icon: const Icon(Icons.edit_note)),
          ],
          primaryAction: canContinue
              ? PageAction('Continue writing', Icons.edit_outlined, () {
                  Navigator.of(context).pop();
                  context.app.nav.open('opd.consult', {'encounterId': c.str('encounter_id')});
                })
              : null,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!signed) ...[
                const _Banner('This note is still a draft. It is not signed and has not been sent to the pharmacy or billing.'),
                Gap.v12,
              ],
              _Paper(data: d),
              if (d.amendments.isNotEmpty) ...[
                Gap.v16,
                _Amendments(items: d.amendments),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, Tone.warning);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(children: [
        Icon(Icons.edit_note, color: c.foreground),
        Gap.h8,
        Expanded(child: Text(text, style: TextStyle(color: c.foreground))),
      ]),
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper({required this.data});
  final NoteData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.app.settings;
    final c = data.consultation;
    final p = data.patient;
    final compact = context.isCompact;
    final doctorName = doctorLabel(data.doctor?.str('display_name') ?? '');
    final vitals = c.map('vitals');
    final items = data.items;
    final orders = data.orderRows;
    final address = [settings.str(SettingKeys.hospitalAddress), settings.str(SettingKeys.hospitalPhone)]
        .where((s) => s.isNotEmpty)
        .join(' · ');

    Widget section(String label, String text) {
      if (text.trim().isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SubHeading(label),
          SelectableText(text, style: theme.textTheme.bodyLarge),
        ]),
      );
    }

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(settings.hospitalName, style: theme.textTheme.titleLarge?.copyWith(color: cs.primary)),
            if (address.isNotEmpty) Caption(address),
          ]),
        ),
        Gap.h16,
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('OPD CONSULTATION',
              style: theme.textTheme.labelMedium?.copyWith(letterSpacing: 1, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
          Text(formatDate(c.date('started_at') ?? c.createdAt), style: theme.textTheme.titleSmall),
          if (data.encounter?.intOrNull('token_no') != null) Caption('Token ${data.encounter!.intOrNull('token_no')}'),
        ]),
      ],
    );

    final patientGrid = InfoGrid(minItemWidth: compact ? 150 : 180, [
      ('Patient', p?.str('full_name') ?? '—'),
      ('UHID', p?.str('uhid') ?? '—'),
      ('Age / sex', p == null ? '—' : patientLine(p, withUhid: false)),
      ('Payer', p == null ? '—' : payerLabel(p)),
      ('Doctor', doctorName),
      ('Department', data.doctor?.str('department') ?? data.encounter?.str('department') ?? ''),
      if ((data.doctor?.str('registration_no') ?? '').isNotEmpty) ('Reg. no.', data.doctor!.str('registration_no')),
      ('Allergies', p == null || Allergy.isNone(p.str('allergies')) ? 'No known allergies' : p.str('allergies')),
    ]);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? Gap.lg : Gap.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Gap.v16,
            const Divider(),
            Gap.v16,
            patientGrid,
            if (vitals.isNotEmpty) ...[
              Gap.v16,
              const SubHeading('Vitals'),
              VitalsChips(vitals),
            ],
            section('Chief complaint', c.str('chief_complaint')),
            section('History', c.str('history')),
            section('Examination', c.str('examination')),
            if (c.str('diagnosis').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SubHeading('Diagnosis'),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: c.str('diagnosis'), style: theme.textTheme.titleMedium),
                    if (c.str('icd_code').isNotEmpty)
                      TextSpan(text: '   ICD-10 ${c.str('icd_code')}', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ])),
                ]),
              ),
            if (items.isNotEmpty) ...[
              Gap.v24,
              Row(children: [
                Text('Rx',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: cs.primary, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic)),
                Gap.h12,
                const SubHeading('Prescription'),
              ]),
              _RxTable(items: items, compact: compact),
            ],
            if (orders.isNotEmpty) ...[
              Gap.v16,
              const SubHeading('Investigations'),
              for (final o in orders)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('•  '),
                    Expanded(
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: o['name'] as String? ?? '', style: theme.textTheme.bodyLarge),
                        if ((o['result'] as String? ?? '').isNotEmpty)
                          TextSpan(text: ' — ${o['result']}', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                      ])),
                    ),
                    if (o['priority'] == 'urgent' || o['priority'] == 'stat')
                      StatusChip(o['priority'] == 'stat' ? 'STAT' : 'Urgent', tone: o['priority'] == 'stat' ? Tone.danger : Tone.warning),
                  ]),
                ),
            ],
            section('Advice', c.str('advice')),
            if (c.date('follow_up_date') != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.lg),
                child: Row(children: [
                  Icon(Icons.event_outlined, size: 20, color: cs.primary),
                  Gap.h8,
                  Text('Follow-up on ${formatWeekday(c.date('follow_up_date')!)}, ${formatDate(c.date('follow_up_date'))}',
                      style: theme.textTheme.titleSmall),
                ]),
              ),
            section('Other notes', c.str('notes')),
            Gap.v32,
            const Divider(),
            Gap.v12,
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: Gap.lg,
              runSpacing: Gap.sm,
              children: [
                Caption(c.str('status') == ConsultStatus.signed
                    ? 'Signed electronically by ${doctorLabel(c.str('signed_by_name', data.doctor?.str('display_name') ?? ''))} '
                        'on ${formatDateTime(c.date('signed_at'))}'
                    : 'Draft — not signed'),
                if (c.date('amended_at') != null) Caption('Amended ${formatDateTime(c.date('amended_at'))}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RxTable extends StatelessWidget {
  const _RxTable({required this.items, required this.compact});
  final List<Map<String, Object?>> items;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, m) in items.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 24, child: Text('${i + 1}.', style: theme.textTheme.titleSmall)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m['drug_name'] as String? ?? '', style: theme.textTheme.titleSmall),
                  if ((m['generic_name'] as String? ?? '').isNotEmpty) Caption(m['generic_name'] as String),
                  Text(Rx.line(m, withRoute: true)),
                ]),
              ),
              if (m['quantity'] is num) Text('× ${(m['quantity'] as num).toInt()}', style: theme.textTheme.titleSmall),
            ]),
          ),
      ]);
    }
    TableRow row(List<Widget> cells) => TableRow(
          children: [for (final c in cells) Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6), child: c)],
        );
    return Table(
      columnWidths: const {
        0: FixedColumnWidth(36),
        1: FlexColumnWidth(3),
        2: FlexColumnWidth(1.4),
        3: FlexColumnWidth(1.1),
        4: FlexColumnWidth(1),
        5: FlexColumnWidth(0.7),
        6: FlexColumnWidth(1.6),
      },
      border: TableBorder(horizontalInside: BorderSide(color: theme.colorScheme.outlineVariant)),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        row([
          Text('#', style: head),
          Text('MEDICINE', style: head),
          Text('DOSE', style: head),
          Text('FREQUENCY', style: head),
          Text('DAYS', style: head),
          Text('QTY', style: head),
          Text('INSTRUCTIONS', style: head),
        ]),
        for (final (i, m) in items.indexed)
          row([
            Text('${i + 1}'),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m['drug_name'] as String? ?? '', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if ((m['generic_name'] as String? ?? '').isNotEmpty) Caption(m['generic_name'] as String, maxLines: 1),
            ]),
            Text(m['dose'] as String? ?? ''),
            Text(m['frequency'] as String? ?? ''),
            Text(m['duration_days'] is num ? plural((m['duration_days'] as num).toInt(), 'day') : ''),
            Text(m['quantity'] is num ? '${(m['quantity'] as num).toInt()}' : ''),
            Text([m['instructions'], m['route']].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
          ]),
      ],
    );
  }
}

class _Amendments extends StatelessWidget {
  const _Amendments({required this.items});
  final List<Rec> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SectionCard(
      title: 'Amendments',
      subtitle: 'Changes made after the note was signed',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, a) in items.indexed) ...[
            if (i > 0) const Divider(height: 24),
            Text('${formatDateTime(a.createdAt)} · ${doctorLabel(a.str('amended_by_name'))}', style: theme.textTheme.titleSmall),
            Caption('Reason: ${a.str('reason')}'),
            Gap.v8,
            for (final ch in a.maps('changes'))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(amendableFields[ch['field']] ?? '${ch['field']}', style: theme.textTheme.labelLarge),
                  if ('${ch['old'] ?? ''}'.isNotEmpty)
                    Text('${ch['old']}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            decoration: TextDecoration.lineThrough, color: cs.onSurfaceVariant)),
                  Text('${ch['new'] ?? '(removed)'}', style: theme.textTheme.bodyMedium),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

/// Correct a signed note. A reason is required; the old and new text are kept.
Future<void> showAmendSheet(BuildContext context, Rec consultation) => showFormSheet<void>(
      context,
      title: 'Amend consultation note',
      width: 720,
      builder: (c) => _AmendForm(consultation: consultation),
    );

class _AmendForm extends StatefulWidget {
  const _AmendForm({required this.consultation});
  final Rec consultation;

  @override
  State<_AmendForm> createState() => _AmendFormState();
}

class _AmendFormState extends State<_AmendForm> {
  late final _c = {
    for (final f in amendableFields.keys)
      if (f != 'follow_up_date') f: TextEditingController(text: widget.consultation.str(f)),
  };
  late DateTime? _followUp = widget.consultation.date('follow_up_date');
  final _reason = TextEditingController();
  bool _saving = false;

  static const presets = ['Typing error', 'Lab result reviewed', 'Additional history from patient', 'Wrong diagnosis entered'];

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      await OpdService.amend(
        context.db,
        widget.consultation,
        {for (final e in _c.entries) e.key: e.value.text, 'follow_up_date': _followUp},
        reason: _reason.text,
        byName: context.session!.displayName,
      );
    }, success: 'Note amended. The old text is kept in the history.');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final multi = {'chief_complaint', 'history', 'examination', 'advice', 'notes'};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Caption('Change what needs correcting. Everyone who opens the note will see what changed, when and why.'),
        Gap.v16,
        FormGrid(minFieldWidth: 280, maxColumns: 2, children: [
          for (final e in _c.entries)
            if (multi.contains(e.key))
              FullWidth(child: AppTextField(label: amendableFields[e.key]!, controller: e.value, maxLines: 4, minLines: 1))
            else
              AppTextField(label: amendableFields[e.key]!, controller: e.value),
          DateField(label: 'Follow-up date', value: _followUp, onChanged: (d) => setState(() => _followUp = d)),
        ]),
        Gap.v16,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final p in presets) ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
        ]),
        Gap.v12,
        TextField(
          controller: _reason,
          minLines: 2,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Reason for the amendment (required)', alignLabelWithHint: true),
        ),
        Gap.v24,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton.icon(
            onPressed: _saving || _reason.text.trim().isEmpty ? null : _save,
            icon: const Icon(Icons.check),
            label: const Text('Save amendment'),
          ),
        ]),
      ],
    );
  }
}

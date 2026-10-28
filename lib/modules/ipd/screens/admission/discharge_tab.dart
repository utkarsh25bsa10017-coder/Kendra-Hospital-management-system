import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../../bed_charging.dart';
import '../../bed_days.dart';
import '../../ipd_schema.dart';
import '../../ipd_service.dart';
import '../../widgets/ipd_widgets.dart';
import '../admission_screen.dart';
import '../discharge_print.dart';

/// Discharge in two steps: the doctor signs off (summary, advice, type),
/// then the desk completes it once the patient is ready to leave.
class DischargeTab extends StatefulWidget {
  const DischargeTab({super.key, required this.view});
  final AdmissionView view;

  @override
  State<DischargeTab> createState() => _DischargeTabState();
}

class _DischargeTabState extends State<DischargeTab> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final status = v.status;
    final isDoctor = context.can(IpdPerms.discharge);
    final canComplete = context.can(IpdPerms.admit) || isDoctor;
    final step = switch (status) { IpdVals.admitted => 0, IpdVals.dischargePending => 1, _ => 2 };
    final app = context.app;

    final children = <Widget>[_Steps(step: step), Gap.v16];
    if (status == IpdVals.admitted || _editing) {
      if (isDoctor) {
        children.add(_SignOffForm(view: v, onDone: () => setState(() => _editing = false), editing: _editing));
      } else {
        children.add(const ToneBanner(
          tone: Tone.info,
          icon: Icons.hourglass_empty,
          title: 'Waiting for the doctor',
          message: 'The treating doctor writes the discharge summary and advice first. '
              'You can then complete the discharge here.',
        ));
      }
    } else {
      children.add(_SummaryCard(
        view: v,
        actions: [
          PrintButton(
            name: 'Discharge summary ${v.admission.str('number')} ${v.patientName}',
            label: 'Print summary',
            build: () async =>
                dischargePdf((await DischargeData.load(app.readDb, v.admission.id))!, Letterhead.of(app.settings)),
          ),
          if (status == IpdVals.dischargePending && isDoctor) ...[
            TextButton(onPressed: () => setState(() => _editing = true), child: const Text('Edit')),
            TextButton(
              onPressed: () async {
                final ok = await confirmDialog(context,
                    title: 'Cancel this discharge?', message: 'The patient stays admitted and the summary is kept.', confirmLabel: 'Cancel discharge');
                if (ok && context.mounted) {
                  await runGuarded(context, () => IpdService.cancelDischarge(context.app.db, v.admission), success: 'Discharge cancelled');
                }
              },
              child: const Text('Cancel discharge'),
            ),
          ],
        ],
      ));
      children.add(Gap.v16);
      if (status == IpdVals.dischargePending) {
        children.add(_CompleteCard(view: v, canComplete: canComplete));
      } else {
        children.add(_DischargedCard(view: v));
      }
    }
    return TourAnchor(
      id: 'ipd.discharge',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget item(int i, String title, String caption) {
      final done = step > i;
      final active = step == i;
      final c = ToneColors.of(context, done ? Tone.success : (active ? Tone.info : Tone.neutral));
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.background, shape: BoxShape.circle, border: Border.all(color: c.border)),
            child: done
                ? Icon(Icons.check, size: 18, color: c.foreground)
                : Text('${i + 1}', style: theme.textTheme.labelLarge?.copyWith(color: c.foreground)),
          ),
          Gap.h8,
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(color: active || done ? null : theme.colorScheme.onSurfaceVariant)),
                Text(caption, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      );
    }

    return Wrap(
      spacing: Gap.xl,
      runSpacing: Gap.md,
      children: [
        item(0, 'Doctor signs off', 'Summary, advice, type'),
        item(1, 'Complete discharge', 'Last bed-days charged, bed to cleaning'),
      ],
    );
  }
}

class _SignOffForm extends StatefulWidget {
  const _SignOffForm({required this.view, required this.onDone, required this.editing});
  final AdmissionView view;
  final VoidCallback onDone;
  final bool editing;

  @override
  State<_SignOffForm> createState() => _SignOffFormState();
}

class _SignOffFormState extends State<_SignOffForm> {
  late String _type = widget.view.admission.str('discharge_type', 'normal');
  late final _summary = TextEditingController(text: widget.view.admission.str('discharge_summary'));
  late final _advice = TextEditingController(text: widget.view.admission.str('discharge_advice'));
  bool _saving = false;

  @override
  void dispose() {
    _summary.dispose();
    _advice.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.app;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => IpdService.requestDischarge(app.db, widget.view.admission, type: _type, summary: _summary.text, advice: _advice.text),
      success: widget.editing ? 'Discharge summary updated' : 'Signed off. The desk can now complete the discharge.',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: widget.editing ? 'Edit discharge summary' : 'Sign off discharge',
      subtitle: 'The patient keeps the bed until the discharge is completed',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SubHeading('Type of discharge'),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final t in IpdVals.dischargeTypes)
                ChoiceChip(
                  showCheckmark: false,
                  selected: _type == t,
                  label: Text(dischargeTypeLabel(t)),
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          if (_type == 'lama') ...[
            Gap.v8,
            const ToneBanner(
              tone: Tone.warning,
              icon: Icons.warning_amber_rounded,
              title: 'Leaving against medical advice',
              message: 'Explain the risks and take the signed LAMA form before the patient leaves.',
            ),
          ],
          Gap.v16,
          AppTextField(
            label: 'Discharge summary',
            controller: _summary,
            hint: 'Course in hospital, procedures, condition at discharge',
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
          ),
          Gap.v16,
          AppTextField(
            label: 'Advice on discharge',
            controller: _advice,
            hint: 'Medicines, diet, activity, follow-up date, warning signs',
            minLines: 3,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
          ),
          Gap.v16,
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.sm,
            children: [
              if (widget.editing) TextButton(onPressed: widget.onDone, child: const Text('Cancel')),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.task_alt),
                label: Text(widget.editing ? 'Save summary' : 'Sign off discharge'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.view, this.actions = const []});
  final AdmissionView view;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = view.admission;
    final requested = a.date('discharge_requested_at');
    return SectionCard(
      title: 'Discharge summary',
      subtitle: [
        dischargeTypeLabel(a.str('discharge_type', 'normal')),
        if (requested != null) 'signed off ${formatRelative(requested)}',
      ].join(' · '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.str('discharge_summary', '—'), style: theme.textTheme.bodyLarge),
          if (a.str('discharge_advice').isNotEmpty) ...[
            Gap.v16,
            const SubHeading('Advice'),
            Text(a.str('discharge_advice'), style: theme.textTheme.bodyLarge),
          ],
          if (actions.isNotEmpty) ...[
            Gap.v8,
            Align(alignment: Alignment.centerRight, child: Wrap(spacing: Gap.xs, children: actions)),
          ],
        ],
      ),
    );
  }
}

class _CompleteCard extends StatefulWidget {
  const _CompleteCard({required this.view, required this.canComplete});
  final AdmissionView view;
  final bool canComplete;

  @override
  State<_CompleteCard> createState() => _CompleteCardState();
}

class _CompleteCardState extends State<_CompleteCard> {
  bool _saving = false;

  Future<void> _complete(BedDayPosting posting) async {
    final app = context.app;
    final v = widget.view;
    final ok = await confirmDialog(
      context,
      title: 'Complete discharge of ${v.patientName}?',
      message: [
        if (posting.ops.isNotEmpty)
          'Charges ${plural(posting.newDays, 'more bed-day')} (${formatMoney(posting.amountPaise)}).'
        else
          'All bed-days are already charged.',
        'Closes the inpatient visit and sends ${v.bedLabel} for cleaning.',
      ].join(' '),
      confirmLabel: 'Complete discharge',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    await runGuarded(
      context,
      () => IpdService.completeDischarge(app.db, v.admission),
      success: '${v.patientName} discharged. ${v.bedLabel} is marked for cleaning.',
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.view;
    return LiveBuilder<BedDayPosting>(
      watch: const {Col.charges, IpdCol.transfers},
      deps: [v.admission.id, v.admission.version],
      load: (db) {
        final now = DateTime.now();
        return BedCharging.prepare(db, v.admission, now: now, dischargedAt: now);
      },
      builder: (context, posting) {
        final stay = posting.owed.length;
        return SectionCard(
          title: 'Complete discharge',
          subtitle: 'When the bill is settled and the patient is ready to leave',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoGrid([
                ('Length of stay', plural(stay, 'bed-day')),
                ('Still to charge', posting.ops.isEmpty ? 'Nothing' : '${plural(posting.newDays, 'day')} · ${formatMoney(posting.amountPaise)}'),
                ('Bed after discharge', '${v.bedLabel} goes for cleaning'),
              ], minItemWidth: 180),
              if (posting.unpriced.isNotEmpty) ...[
                Gap.v12,
                ToneBanner(
                  tone: Tone.warning,
                  icon: Icons.price_change_outlined,
                  title: 'No price set for ${plural(posting.unpriced.length, 'day')}',
                  message: 'Ask an administrator to set the bed and nursing charges for this ward under Wards & beds.',
                ),
              ],
              Gap.v16,
              const SubHeading('Before the patient leaves'),
              for (final t in const [
                'Bill settled or approved by the insurer / TPA',
                'Unused medicines returned to pharmacy',
                'Discharge summary printed and explained',
                'Follow-up appointment given',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, left: 4, right: 4),
                      child: Icon(Icons.circle, size: 6, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    Gap.h8,
                    Expanded(child: Text(t)),
                  ]),
                ),
              Gap.v16,
              Wrap(
                alignment: WrapAlignment.end,
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => context.app.nav.open('billing.invoice', {'patientId': v.admission.str('patient_id')}),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Open bill'),
                  ),
                  if (widget.canComplete)
                    FilledButton.icon(
                      onPressed: _saving ? null : () => _complete(posting),
                      icon: const Icon(Icons.logout),
                      label: const Text('Complete discharge'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DischargedCard extends StatelessWidget {
  const _DischargedCard({required this.view});
  final AdmissionView view;

  @override
  Widget build(BuildContext context) {
    final a = view.admission;
    final admitted = a.date('admitted_at')!;
    final out = a.date('discharged_at');
    return SectionCard(
      title: 'Discharged',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoGrid([
            ('Admitted', formatDateTime(admitted)),
            ('Discharged', formatDateTime(out)),
            ('Length of stay', plural(BedDays.count(admittedAt: admitted, dischargedAt: out, now: DateTime.now()), 'bed-day')),
            ('Type', dischargeTypeLabel(a.str('discharge_type', 'normal'))),
          ], minItemWidth: 180),
          Gap.v16,
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => context.app.nav.open('billing.invoice', {'patientId': a.str('patient_id')}),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Open bill'),
            ),
          ),
        ],
      ),
    );
  }
}

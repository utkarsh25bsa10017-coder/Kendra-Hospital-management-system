import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../../ipd_schema.dart';
import '../../ipd_service.dart';
import '../admission_screen.dart';

/// Quick bedside note with vitals, and the timeline of everything recorded.
class NotesTab extends StatelessWidget {
  const NotesTab({super.key, required this.view});
  final AdmissionView view;

  @override
  Widget build(BuildContext context) {
    final canWrite = context.can(IpdPerms.notes) && !view.discharged;
    final timeline = _Timeline(admissionId: view.admission.id);
    if (!canWrite) return timeline;
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 860) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_NoteForm(view: view), Gap.v16, timeline],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: _NoteForm(view: view)),
          Gap.h16,
          Expanded(flex: 7, child: timeline),
        ],
      );
    });
  }
}

/// The vital signs a nurse records: (key, label with unit, hint).
const _vitals = <(String, String, String)>[
  ('bp_sys', 'BP systolic', 'mmHg'),
  ('bp_dia', 'BP diastolic', 'mmHg'),
  ('pulse', 'Pulse /min', ''),
  ('temp_c', 'Temp °C', 'e.g. 37.2'),
  ('spo2', 'SpO2 %', ''),
  ('rr', 'Resp. rate /min', ''),
  ('grbs', 'GRBS mg/dL', ''),
];

String _chipLabel(String kind) => switch (kind) {
      'nursing' => 'Nursing',
      'progress' => 'Progress',
      _ => noteKindLabel(kind),
    };

class _NoteForm extends StatefulWidget {
  const _NoteForm({required this.view});
  final AdmissionView view;

  @override
  State<_NoteForm> createState() => _NoteFormState();
}

class _NoteFormState extends State<_NoteForm> {
  String _kind = 'vitals';
  final _text = TextEditingController();
  final _v = {for (final (k, _, _) in _vitals) k: TextEditingController()};
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    for (final c in _v.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _vitalValues() => {
        for (final (k, _, _) in _vitals)
          if (_v[k]!.text.trim().isNotEmpty) k: k == 'temp_c' ? double.tryParse(_v[k]!.text.trim()) : int.tryParse(_v[k]!.text.trim()),
      };

  Future<void> _save() async {
    final app = context.app;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => IpdService.addNote(app.db,
          admission: widget.view.admission,
          kind: _kind,
          text: _text.text,
          vitals: _kind == 'vitals' ? _vitalValues() : null,
          byName: app.auth.session?.displayName),
      success: '${noteKindLabel(_kind)} saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _text.clear();
      for (final c in _v.values) {
        c.clear();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vitals = _kind == 'vitals';
    return SectionCard(
      title: 'Add to the chart',
      subtitle: 'Saved with your name and the time',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final k in IpdVals.noteKinds)
                ChoiceChip(
                  showCheckmark: false,
                  selected: _kind == k,
                  label: Text(_chipLabel(k)),
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          Gap.v16,
          if (vitals) ...[
            FormGrid(
              minFieldWidth: 128,
              maxColumns: 4,
              children: [
                for (final (k, label, hint) in _vitals)
                  TextFormField(
                    controller: _v[k],
                    keyboardType: TextInputType.numberWithOptions(decimal: k == 'temp_c'),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(k == 'temp_c' ? r'[0-9.]' : r'[0-9]'))],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(labelText: label, hintText: hint.isEmpty ? null : hint, isDense: true),
                  ),
              ],
            ),
            Gap.v16,
          ],
          AppTextField(
            label: vitals ? 'Remarks (optional)' : 'Note',
            controller: _text,
            hint: switch (_kind) {
              'nursing' => 'e.g. IV fluids continued, tolerating soft diet, ambulating with support',
              'progress' => 'Assessment and plan',
              'handover' => 'What the next shift needs to know',
              _ => null,
            },
            minLines: vitals ? 1 : 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
          ),
          Gap.v16,
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: Text('Save ${noteKindLabel(_kind).toLowerCase()}'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.admissionId});
  final String admissionId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<List<Rec>>(
      watch: const {IpdCol.notes},
      deps: [admissionId],
      load: (db) => db.query(Query(IpdCol.notes).eq('admission_id', admissionId).sort('recorded_at', desc: true).take(200)),
      builder: (context, notes) {
        final latest = notes.where((n) => n.map('vitals').isNotEmpty).firstOrNull;
        return SectionCard(
          title: 'Notes and vitals',
          subtitle: notes.isEmpty ? null : plural(notes.length, 'entry', 'entries'),
          child: notes.isEmpty
              ? const EmptyState(icon: Icons.edit_note, title: 'Nothing charted yet', message: 'Notes and vitals appear here, newest first.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (latest != null) ...[_LatestVitals(note: latest), Gap.v16],
                    for (final (i, n) in notes.indexed) ...[
                      if (i > 0) const Divider(height: Gap.xl),
                      _NoteItem(note: n),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _LatestVitals extends StatelessWidget {
  const _LatestVitals({required this.note});
  final Rec note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, Tone.info);
    final at = note.date('recorded_at') ?? note.createdAt;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Latest vitals · ${formatRelative(at)}', style: theme.textTheme.labelLarge?.copyWith(color: c.foreground)),
          Gap.v8,
          Wrap(
            spacing: Gap.lg,
            runSpacing: Gap.xs,
            children: [
              for (final b in vitalBits(note.map('vitals')))
                Text(b, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
            ],
          ),
        ],
      ),
    );
  }
}

class _NoteItem extends StatelessWidget {
  const _NoteItem({required this.note});
  final Rec note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = note.str('kind', 'nursing');
    final (icon, tone) = switch (kind) {
      'vitals' => (Icons.monitor_heart_outlined, Tone.info),
      'progress' => (Icons.medical_services_outlined, Tone.success),
      'handover' => (Icons.swap_horiz, Tone.warning),
      _ => (Icons.edit_note, Tone.neutral),
    };
    final c = ToneColors.of(context, tone);
    final at = note.date('recorded_at') ?? note.createdAt;
    final vitals = vitalBits(note.map('vitals'));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: c.background, shape: BoxShape.circle, border: Border.all(color: c.border)),
          child: Icon(icon, size: 18, color: c.foreground),
        ),
        Gap.h12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: Gap.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(noteKindLabel(kind), style: theme.textTheme.titleSmall),
                  Text('${note.str('by_name', 'Staff')} · ${formatRelative(at)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
              if (vitals.isNotEmpty) ...[
                Gap.v8,
                Wrap(spacing: Gap.xs + 2, runSpacing: Gap.xs + 2, children: [for (final b in vitals) StatusChip(b)]),
              ],
              if (note.str('text').isNotEmpty) ...[
                Gap.v8,
                Text(note.str('text'), style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

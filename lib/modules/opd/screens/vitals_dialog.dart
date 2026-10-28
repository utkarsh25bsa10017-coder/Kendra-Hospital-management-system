import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';

/// Quick vitals entry for the nurse before the patient goes in.
/// Returns true when saved.
Future<bool> showVitalsDialog(BuildContext context, {required Rec encounter, required Rec patient, Map<String, Object?> initial = const {}}) async {
  final saved = await showFormSheet<bool>(
    context,
    title: 'Vitals · ${patient.str('full_name')}',
    width: 620,
    builder: (c) => _VitalsForm(encounter: encounter, patient: patient, initial: initial),
  );
  return saved ?? false;
}

class _VitalsForm extends StatefulWidget {
  const _VitalsForm({required this.encounter, required this.patient, required this.initial});
  final Rec encounter;
  final Rec patient;
  final Map<String, Object?> initial;

  @override
  State<_VitalsForm> createState() => _VitalsFormState();
}

class _VitalsFormState extends State<_VitalsForm> {
  late Map<String, Object?> _v = Vitals.clean(widget.initial);
  bool _saving = false;

  Future<void> _save() async {
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      await OpdService.recordVitals(context.db, widget.encounter, _v, byName: context.session!.displayName);
    }, success: 'Vitals saved for ${widget.patient.str('full_name')}');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final critical = Vitals.critical(_v);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Caption('${patientLine(widget.patient)} · Token ${widget.encounter.intOrNull('token_no') ?? '–'}'),
        Gap.v16,
        VitalsEditor(initial: widget.initial, autofocus: true, onChanged: (v) => setState(() => _v = v)),
        Gap.v8,
        const Caption('BP as 120/80. Temperature in °C or °F. BMI is worked out from weight and height.'),
        if (critical.isNotEmpty) ...[
          Gap.v12,
          _CriticalNote(critical),
        ],
        Gap.v24,
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            Gap.h8,
            FilledButton.icon(
              onPressed: _saving || _v.isEmpty ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save vitals'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CriticalNote extends StatelessWidget {
  const _CriticalNote(this.items);
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, Tone.danger);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        children: [
          Icon(Icons.priority_high, color: c.foreground),
          Gap.h8,
          Expanded(
            child: Text('Critical: ${items.join(', ')}. Tell the doctor now — the board is alerted too.',
                style: TextStyle(color: c.foreground, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

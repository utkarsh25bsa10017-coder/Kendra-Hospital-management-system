import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';

bool get isApple => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;

/// "Ctrl" or "⌘", for shortcut hints.
String get modKeyLabel => isApple ? '⌘' : 'Ctrl';

SingleActivator modShortcut(LogicalKeyboardKey key) => SingleActivator(key, meta: isApple, control: !isApple);

/// "6 y · Female · SMH-26-000004".
String patientLine(Rec p, {bool withUhid = true}) => [
      ageLabel(p.date('dob'), p.intOrNull('age_years')),
      genderLabel(p.strOrNull('gender')),
      if (withUhid) p.str('uhid'),
    ].where((s) => s.isNotEmpty && s != '—').join(' · ');

String payerLabel(Rec p) => switch (p.str('payer_type', 'self')) {
      'insurance' => 'Insurance${p.str('insurer').isEmpty ? '' : ' · ${p.str('insurer')}'}',
      'corporate' => 'Corporate${p.str('insurer').isEmpty ? '' : ' · ${p.str('insurer')}'}',
      _ => 'Self pay',
    };

Tone payerTone(Rec p) => switch (p.str('payer_type', 'self')) {
      'insurance' => Tone.info,
      'corporate' => Tone.board,
      _ => Tone.neutral,
    };

(String, Tone) queueState(Rec encounter) {
  if (encounter.str('status') == Vals.cancelled || encounter.str('queue_status') == Vals.left) return ('Left', Tone.neutral);
  if (encounter.str('status') == Vals.closed || encounter.str('queue_status') == Vals.done) return ('Seen', Tone.success);
  if (encounter.str('queue_status') == Vals.withDoctor) return ('With doctor', Tone.info);
  return ('Waiting', Tone.warning);
}

Tone toneForLevel(VitalLevel l) => switch (l) {
      VitalLevel.critical => Tone.danger,
      VitalLevel.abnormal => Tone.warning,
      VitalLevel.normal => Tone.neutral,
    };

/// The queue token in a rounded square.
class TokenBadge extends StatelessWidget {
  const TokenBadge(this.token, {super.key, this.tone = Tone.info, this.size = 40});
  final int? token;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Text(
        token?.toString() ?? '–',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: c.foreground, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// The red "allergic to" strip shown wherever a clinician prescribes.
class AllergyBanner extends StatelessWidget {
  const AllergyBanner(this.allergies, {super.key, this.dense = false});
  final String allergies;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
      label: 'Allergies: $allergies',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: Gap.lg, vertical: dense ? Gap.sm : Gap.md),
        decoration: BoxDecoration(color: cs.error, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.onError, size: dense ? 18 : 22),
            Gap.h12,
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'ALLERGIES  ', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.6, color: cs.onError)),
                  TextSpan(text: allergies, style: TextStyle(fontWeight: FontWeight.w600, color: cs.onError)),
                ]),
                style: dense ? theme.textTheme.bodyMedium : theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Allergy banner, or a quiet "No known allergies" chip.
class AllergyLine extends StatelessWidget {
  const AllergyLine(this.allergies, {super.key, this.dense = false});
  final String allergies;
  final bool dense;

  @override
  Widget build(BuildContext context) => Allergy.isNone(allergies)
      ? const Align(
          alignment: Alignment.centerLeft,
          child: StatusChip('No known allergies', icon: Icons.check_circle_outline, tone: Tone.success))
      : AllergyBanner(allergies, dense: dense);
}

/// BP, pulse, temperature, SpO2 and sugar: what a queue needs at a glance.
Map<String, Object?> keyVitals(Map<String, Object?> v) => {
      for (final k in const [VitalKeys.bpSys, VitalKeys.bpDia, VitalKeys.pulse, VitalKeys.tempC, VitalKeys.spo2, VitalKeys.grbs])
        if (v[k] != null) k: v[k],
    };

/// Key vitals as one line of text, abnormal readings coloured and bold.
class KeyVitals extends StatelessWidget {
  const KeyVitals(this.vitals, {super.key, this.maxLines = 2});
  final Map<String, Object?> vitals;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final v = vitals;
    final parts = <(String, VitalLevel)>[];
    final bp = Vitals.bpText(v);
    if (bp.isNotEmpty) parts.add(('BP $bp', Vitals.bpLevel(v)));
    for (final (key, label, unit) in const [
      (VitalKeys.pulse, 'P', ''),
      (VitalKeys.tempC, 'T', ' °C'),
      (VitalKeys.spo2, 'SpO2', '%'),
      (VitalKeys.grbs, 'Sugar', ''),
    ]) {
      final n = Vitals.value(v, key);
      if (n != null) parts.add(('$label ${Vitals.fmt(n)}$unit', Vitals.level(key, n)));
    }
    final spans = <InlineSpan>[];
    for (final (i, (text, level)) in parts.indexed) {
      if (i > 0) spans.add(const TextSpan(text: ' · '));
      spans.add(TextSpan(
        text: text,
        style: level == VitalLevel.normal
            ? null
            : TextStyle(color: ToneColors.of(context, toneForLevel(level)).foreground, fontWeight: FontWeight.w700),
      ));
    }
    return Text.rich(TextSpan(children: spans), maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }
}

/// Like a status chip, but long text wraps instead of overflowing.
class InfoPill extends StatelessWidget {
  const InfoPill(this.label, {super.key, this.icon, this.tone = Tone.neutral});
  final String label;
  final IconData? icon;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: c.foreground)),
            Gap.h4,
          ],
          Flexible(
            child: Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c.foreground, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Vitals as small chips, abnormal ones coloured.
class VitalsChips extends StatelessWidget {
  const VitalsChips(this.vitals, {super.key});
  final Map<String, Object?> vitals;

  @override
  Widget build(BuildContext context) {
    final v = vitals;
    final chips = <Widget>[];
    void add(String label, VitalLevel level) =>
        chips.add(StatusChip(label, tone: level == VitalLevel.normal ? Tone.neutral : toneForLevel(level)));
    final bp = Vitals.bpText(v);
    if (bp.isNotEmpty) add('BP $bp', Vitals.bpLevel(v));
    for (final (key, label, unit) in const [
      (VitalKeys.pulse, 'Pulse', '/min'),
      (VitalKeys.tempC, 'Temp', ' °C'),
      (VitalKeys.spo2, 'SpO2', '%'),
      (VitalKeys.rr, 'RR', '/min'),
      (VitalKeys.weightKg, 'Wt', ' kg'),
      (VitalKeys.heightCm, 'Ht', ' cm'),
      (VitalKeys.bmi, 'BMI', ''),
      (VitalKeys.grbs, 'GRBS', ' mg/dL'),
    ]) {
      final n = Vitals.value(v, key);
      if (n != null) add('$label ${Vitals.fmt(n)}$unit', Vitals.level(key, n));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }
}

/// Compact numeric vitals boxes. BMI is worked out; abnormal values are
/// amber, critical ones red. Temperature accepts °C or °F.
class VitalsEditor extends StatefulWidget {
  const VitalsEditor({super.key, required this.initial, required this.onChanged, this.autofocus = false});
  final Map<String, Object?> initial;
  final ValueChanged<Map<String, Object?>> onChanged;
  final bool autofocus;

  @override
  State<VitalsEditor> createState() => _VitalsEditorState();
}

class _VitalsEditorState extends State<VitalsEditor> {
  late final _bp = TextEditingController(text: Vitals.bpText(widget.initial));
  late final _c = <String, TextEditingController>{
    for (final k in const [
      VitalKeys.pulse, VitalKeys.tempC, VitalKeys.spo2, VitalKeys.rr, VitalKeys.weightKg, VitalKeys.heightCm, VitalKeys.grbs,
    ])
      k: TextEditingController(text: Vitals.fmt(Vitals.value(widget.initial, k))),
  };

  @override
  void dispose() {
    _bp.dispose();
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> get _values {
    final out = <String, Object?>{};
    final bp = Vitals.parseBp(_bp.text);
    if (bp != null) {
      out[VitalKeys.bpSys] = bp.$1;
      out[VitalKeys.bpDia] = bp.$2;
    }
    for (final e in _c.entries) {
      final n = num.tryParse(e.value.text.trim());
      if (n == null) continue;
      out[e.key] = e.key == VitalKeys.tempC ? Vitals.tempToC(n) : n;
    }
    return Vitals.clean(out);
  }

  void _changed() {
    setState(() {});
    widget.onChanged(_values);
  }

  @override
  Widget build(BuildContext context) {
    final v = _values;
    final tempTyped = num.tryParse(_c[VitalKeys.tempC]!.text.trim());
    final bpBad = _bp.text.trim().isNotEmpty && Vitals.parseBp(_bp.text) == null;
    return Wrap(
      spacing: Gap.md,
      runSpacing: Gap.md,
      children: [
        _box(context, 'BP', _bp, 'mmHg', 140, bpBad ? VitalLevel.abnormal : Vitals.bpLevel(v),
            hint: '120/80', bp: true, autofocus: widget.autofocus, error: bpBad),
        _box(context, 'Pulse', _c[VitalKeys.pulse]!, '/min', 96, Vitals.level(VitalKeys.pulse, Vitals.value(v, VitalKeys.pulse))),
        _box(context, 'Temp', _c[VitalKeys.tempC]!, tempTyped != null && tempTyped > 45 ? '°F' : '°C', 96,
            Vitals.level(VitalKeys.tempC, Vitals.value(v, VitalKeys.tempC)), decimal: true),
        _box(context, 'SpO2', _c[VitalKeys.spo2]!, '%', 90, Vitals.level(VitalKeys.spo2, Vitals.value(v, VitalKeys.spo2))),
        _box(context, 'RR', _c[VitalKeys.rr]!, '/min', 90, Vitals.level(VitalKeys.rr, Vitals.value(v, VitalKeys.rr))),
        _box(context, 'Weight', _c[VitalKeys.weightKg]!, 'kg', 96, VitalLevel.normal, decimal: true),
        _box(context, 'Height', _c[VitalKeys.heightCm]!, 'cm', 96, VitalLevel.normal, decimal: true),
        _bmi(context, Vitals.value(v, VitalKeys.bmi)),
        _box(context, 'GRBS', _c[VitalKeys.grbs]!, 'mg/dL', 118, Vitals.level(VitalKeys.grbs, Vitals.value(v, VitalKeys.grbs))),
      ],
    );
  }

  InputDecoration _decoration(BuildContext context, String label, String suffix, VitalLevel level, {String? hint}) {
    final theme = Theme.of(context);
    final tone = ToneColors.of(context, toneForLevel(level));
    final flagged = level != VitalLevel.normal;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixText: suffix,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      fillColor: flagged ? tone.background : null,
      labelStyle: flagged ? TextStyle(color: tone.foreground, fontWeight: FontWeight.w600) : null,
      suffixStyle: theme.textTheme.bodySmall?.copyWith(color: flagged ? tone.foreground : theme.colorScheme.onSurfaceVariant),
      enabledBorder: flagged
          ? OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide(color: tone.foreground, width: 1.4))
          : null,
    );
  }

  Widget _box(BuildContext context, String label, TextEditingController c, String suffix, double width, VitalLevel level,
      {String? hint, bool bp = false, bool decimal = false, bool autofocus = false, bool error = false}) {
    final tone = ToneColors.of(context, toneForLevel(level));
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        autofocus: autofocus,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal || bp),
        textInputAction: TextInputAction.next,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(bp ? r'[0-9/ ]' : r'[0-9.]'))],
        style: level == VitalLevel.normal
            ? null
            : TextStyle(color: tone.foreground, fontWeight: FontWeight.w700),
        onChanged: (_) => _changed(),
        decoration: _decoration(context, error ? '$label ?' : label, suffix, level, hint: hint),
      ),
    );
  }

  Widget _bmi(BuildContext context, num? bmi) {
    final level = Vitals.level(VitalKeys.bmi, bmi);
    return SizedBox(
      width: 90,
      child: InputDecorator(
        isEmpty: bmi == null,
        decoration: _decoration(context, 'BMI', '', level).copyWith(enabled: false, hintText: 'auto'),
        child: Text(
          bmi == null ? '' : Vitals.fmt(bmi),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: level == VitalLevel.normal ? null : ToneColors.of(context, toneForLevel(level)).foreground,
          ),
        ),
      ),
    );
  }
}

/// A multi-line note field with one-tap phrases underneath.
class PhraseField extends StatelessWidget {
  const PhraseField({
    super.key,
    required this.label,
    required this.controller,
    required this.phrases,
    this.hint,
    this.focusNode,
    this.minLines = 2,
  });
  final String label;
  final TextEditingController controller;
  final List<String> phrases;
  final String? hint;
  final FocusNode? focusNode;
  final int minLines;

  static String appendPhrase(String text, String phrase) {
    final t = text.trimRight();
    if (t.toLowerCase().contains(phrase.toLowerCase())) return text;
    if (t.isEmpty) return phrase;
    // Keep acronyms as written ("P/A soft", "CVS: S1 S2 normal", "ORS ...").
    final firstWord = phrase.split(' ').first;
    final keepCase = firstWord.length > 1 && firstWord == firstWord.toUpperCase();
    final p = keepCase ? phrase : phrase[0].toLowerCase() + phrase.substring(1);
    if (phrase.startsWith('since')) return '$t $p';
    if (t.endsWith('.')) return '$t $phrase';
    if (t.endsWith(',')) return '$t $p';
    return '$t, $p';
  }

  /// Takes a phrase back out, with the comma that joined it.
  static String removePhrase(String text, String phrase) {
    final i = text.toLowerCase().indexOf(phrase.toLowerCase());
    if (i < 0) return text;
    var start = i;
    var end = i + phrase.length;
    if (start >= 2 && text.substring(start - 2, start) == ', ') {
      start -= 2;
    } else if (end + 2 <= text.length && text.substring(end, end + 2) == ', ') {
      end += 2;
    } else if (start >= 1 && text[start - 1] == ' ') {
      start -= 1;
    }
    final out = (text.substring(0, start) + text.substring(end)).trim();
    if (out.isEmpty || start > 0) return out;
    return out[0].toUpperCase() + out.substring(1);
  }

  static bool hasPhrase(String text, String phrase) => text.toLowerCase().contains(phrase.toLowerCase());

  void _toggle(String p) {
    final next = hasPhrase(controller.text, p) ? removePhrase(controller.text, p) : appendPhrase(controller.text, p);
    controller.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          focusNode: focusNode,
          minLines: minLines,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, hintText: hint, alignLabelWithHint: true),
        ),
        if (phrases.isNotEmpty) ...[
          Gap.v8,
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in phrases)
                  FilterChip(
                    label: Text(p),
                    selected: hasPhrase(value.text, p),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _toggle(p),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Keeps a tab's state (typed text, scroll position) when switching tabs.
class KeepTabAlive extends StatefulWidget {
  const KeepTabAlive({super.key, required this.child});
  final Widget child;

  @override
  State<KeepTabAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<KeepTabAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Small grey caption.
class Caption extends StatelessWidget {
  const Caption(this.text, {super.key, this.maxLines = 2});
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
  }
}

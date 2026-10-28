import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import 'lab_widgets.dart';

typedef PreviousValues = Map<String, (Map<String, Object?>, DateTime)>;

const _quickComments = [
  'Correlate clinically',
  'Repeat sample advised',
  'Sample haemolysed',
  'Confirmed on repeat run',
  'Smear examined',
];

/// A form generated from the test's parameters. Tab or Enter moves to the
/// next value, Ctrl/⌘+S saves, and every value is flagged as it is typed.
class ResultEntryForm extends StatefulWidget {
  const ResultEntryForm({
    super.key,
    required this.params,
    required this.onSave,
    this.sex,
    this.initial = const {},
    this.initialComments = '',
    this.previous = const {},
    this.saveLabel = 'Save results',
    this.onCancel,
    this.doctorName = '',
    this.autofocus = true,
  });

  final List<LabParam> params;
  final String? sex;
  final Map<String, String> initial;
  final String initialComments;
  final PreviousValues previous;
  final Future<void> Function(Map<String, String> raw, String comments) onSave;
  final String saveLabel;
  final VoidCallback? onCancel;
  final String doctorName;
  final bool autofocus;

  @override
  State<ResultEntryForm> createState() => ResultEntryFormState();
}

class ResultEntryFormState extends State<ResultEntryForm> {
  final _ctrls = <String, TextEditingController>{};
  final _choices = <String, String?>{};
  final _nodes = <String, FocusNode>{};
  final _comments = TextEditingController();
  final _commentsNode = FocusNode();
  bool _saving = false;
  bool _tried = false;

  List<LabParam> get _params => widget.params;

  @override
  void initState() {
    super.initState();
    for (final p in _params) {
      final v = widget.initial[p.key] ?? '';
      if (p.isChoice) {
        _choices[p.key] = p.choices.contains(v) ? v : null;
      } else {
        _ctrls[p.key] = TextEditingController(text: v);
      }
      _nodes[p.key] = FocusNode(debugLabel: 'lab.${p.key}');
    }
    _comments.text = widget.initialComments;
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final n in _nodes.values) {
      n.dispose();
    }
    _comments.dispose();
    _commentsNode.dispose();
    super.dispose();
  }

  String _raw(LabParam p) => p.isChoice ? (_choices[p.key] ?? '') : _ctrls[p.key]!.text;
  String _flag(LabParam p) => p.flagFor(_raw(p), sex: widget.sex);

  Map<String, String> get values => {for (final p in _params) p.key: _raw(p)};
  bool get saving => _saving;

  void _next(LabParam p) {
    final i = _params.indexOf(p);
    if (i < 0 || i == _params.length - 1) {
      _commentsNode.requestFocus();
    } else {
      _nodes[_params[i + 1].key]!.requestFocus();
    }
  }

  Future<void> save() async {
    if (_saving) return;
    setState(() => _tried = true);
    final bad = _params.where((p) => p.problem(_raw(p)) != null).toList();
    if (bad.isNotEmpty) {
      context.toast('${bad.first.name}: enter a number', error: true);
      _nodes[bad.first.key]?.requestFocus();
      return;
    }
    final empty = _params.where((p) => _raw(p).trim().isEmpty).toList();
    if (empty.length == _params.length) {
      context.toast('Enter at least one result', error: true);
      _nodes[_params.first.key]?.requestFocus();
      return;
    }
    final critical = _params.where((p) => LabFlag.isCritical(_flag(p))).toList();
    if (critical.isNotEmpty) {
      final lines = [
        for (final p in critical)
          '• ${p.name} ${p.value(_raw(p))['value']} ${p.unit} — ${LabFlag.label(_flag(p)).toLowerCase()} (limit ${p.criticalLabel})',
      ].join('\n');
      final who = widget.doctorName.isEmpty ? 'the treating doctor' : widget.doctorName;
      final ok = await confirmDialog(
        context,
        title: critical.length == 1 ? 'Confirm critical value' : 'Confirm ${critical.length} critical values',
        message: '$lines\n\nRecheck the sample and the patient\'s identity first. After saving, the pathologist is '
            'alerted to verify this report before anything else, and $who must be informed.',
        confirmLabel: 'Values are correct',
        destructive: true,
      );
      if (!ok || !mounted) return;
    } else if (empty.isNotEmpty) {
      final ok = await confirmDialog(
        context,
        title: 'Save with ${plural(empty.length, 'empty value')}?',
        message: '${empty.map((p) => p.name).take(6).join(', ')}${empty.length > 6 ? '…' : ''} will be left off the report.',
        confirmLabel: 'Save anyway',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(values, _comments.text);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = _params.where((p) => LabFlag.isCritical(_flag(p))).toList();
    final flagged = _params.where((p) => LabFlag.isAbnormal(_flag(p))).length;
    final filled = _params.where((p) => _raw(p).trim().isNotEmpty).length;
    final compact = context.isCompact;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): save,
      },
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (critical.isNotEmpty) ...[
              LabBanner(
                tone: Tone.danger,
                icon: Icons.warning_amber_rounded,
                title: critical.length == 1 ? 'Critical value' : '${critical.length} critical values',
                message: '${critical.map((p) => '${p.label} ${p.value(_raw(p))['value']} ${p.unit}'.trim()).join(', ')}. '
                    'Recheck the sample now. The pathologist and doctor are alerted when you save.',
              ),
              Gap.v16,
            ],
            SectionCard(
              title: 'Results',
              subtitle: '$filled of ${_params.length} entered${flagged > 0 ? ' · $flagged flagged' : ''}',
              trailing: compact
                  ? null
                  : Text('Tab or Enter: next  ·  Ctrl+S: save',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: LayoutBuilder(builder: (context, box) {
                final wide = box.maxWidth >= 640;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide) _header(theme),
                    for (final (i, p) in _params.indexed) ...[
                      if (i > 0 || wide) const Divider(height: 1),
                      _row(context, p, i, wide),
                    ],
                  ],
                );
              }),
            ),
            Gap.v16,
            SectionCard(
              title: 'Comments',
              subtitle: 'Printed on the report',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('lab.comments'),
                    controller: _comments,
                    focusNode: _commentsNode,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: 'Optional, e.g. "Platelet count confirmed on smear"'),
                  ),
                  Gap.v8,
                  Wrap(
                    spacing: Gap.sm,
                    runSpacing: Gap.sm,
                    children: [
                      for (final c in _quickComments)
                        ActionChip(
                          label: Text(c),
                          onPressed: () => setState(() {
                            final t = _comments.text.trim();
                            _comments.text = t.isEmpty ? c : '$t. $c';
                          }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Gap.v16,
            if (!compact)
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _saving ? null : save,
                    icon: const Icon(Icons.check),
                    label: Text(widget.saveLabel),
                  ),
                  if (widget.onCancel != null) ...[
                    Gap.h8,
                    TextButton(onPressed: _saving ? null : widget.onCancel, child: const Text('Cancel')),
                  ],
                ],
              )
            else if (widget.onCancel != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: _saving ? null : widget.onCancel, child: const Text('Cancel')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final s = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Expanded(flex: 4, child: Text('Parameter', style: s)),
        Expanded(flex: 6, child: Text('Result', style: s)),
        Expanded(flex: 4, child: Text('Reference range', style: s)),
      ]),
    );
  }

  Widget _row(BuildContext context, LabParam p, int index, bool wide) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final flag = _flag(p);
    final input = p.isChoice ? _choiceField(context, p, flag) : _textField(context, p, index, flag);
    final ref = p.refLabel(widget.sex);
    final refText = [if (ref.isNotEmpty) ref, if (p.isNumeric && p.unit.isNotEmpty && ref.isNotEmpty) p.unit].join(' ');
    final prev = widget.previous[p.key];
    final delta = _deltaWarning(p, prev);
    final prevLine = prev == null
        ? null
        : Text.rich(TextSpan(children: [
            TextSpan(text: 'Last ', style: muted),
            WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic, child: FlaggedValue(prev.$1, showUnit: false, style: theme.textTheme.bodySmall)),
            TextSpan(text: ' · ${formatDateShort(prev.$2)}', style: muted),
          ]));
    final deltaLine = delta == null
        ? null
        : Text(delta, style: theme.textTheme.bodySmall?.copyWith(color: ToneColors.of(context, Tone.warning).foreground, fontWeight: FontWeight.w600));

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.name, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        if (p.hasCriticalLimits && wide) Text('Critical ${p.criticalLabel}', style: muted),
      ],
    );

    if (wide && p.isChoice) {
      // Choices get the result and range columns, so the options fit on one line.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 4, child: Padding(padding: const EdgeInsets.only(right: Gap.md), child: name)),
            Expanded(
              flex: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [Flexible(child: input), Gap.h12, FlagBadge(flag)]),
                  if (refText.isNotEmpty || prevLine != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, top: 2),
                      child: Wrap(spacing: Gap.md, children: [
                        if (refText.isNotEmpty) Text('Normal: $refText', style: muted),
                        ?prevLine,
                      ]),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 4, child: Padding(padding: const EdgeInsets.only(right: Gap.md), child: name)),
            Expanded(
              flex: 6,
              child: Row(children: [
                if (p.isChoice) Flexible(child: input) else SizedBox(width: 190, child: input),
                Gap.h12,
                FlagBadge(flag),
              ]),
            ),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(refText.isEmpty ? '—' : refText, style: theme.textTheme.bodyMedium),
                  ?prevLine,
                  ?deltaLine,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [Expanded(child: name), FlagBadge(flag)]),
          Gap.v8,
          input,
          Gap.v4,
          Wrap(spacing: Gap.md, children: [
            if (refText.isNotEmpty) Text(p.isChoice ? 'Normal: $refText' : 'Ref $refText', style: muted),
            ?prevLine,
          ]),
          ?deltaLine,
        ],
      ),
    );
  }

  /// A sudden big change can mean a mislabelled sample.
  String? _deltaWarning(LabParam p, (Map<String, Object?>, DateTime)? prev) {
    if (!p.isNumeric || prev == null) return null;
    final now = p.parse(_raw(p));
    final was = (prev.$1['numeric'] as num?)?.toDouble();
    if (now == null || was == null || was == 0) return null;
    final change = (now - was).abs() / was.abs();
    if (change < 0.5) return null;
    return 'Big change since ${formatDateShort(prev.$2)}. Check the sample label.';
  }

  Widget _textField(BuildContext context, LabParam p, int index, String flag) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, LabFlag.tone(flag));
    final flagged = flag.isNotEmpty;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: flagged ? c.foreground.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant, width: flagged ? 1.4 : 1),
    );
    return TextField(
      key: ValueKey('lab.value.${p.key}'),
      controller: _ctrls[p.key],
      focusNode: _nodes[p.key],
      autofocus: widget.autofocus && index == 0 && !context.isCompact,
      keyboardType: p.isNumeric ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
      inputFormatters: p.isNumeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))] : null,
      textInputAction: TextInputAction.next,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _next(p),
      style: theme.textTheme.bodyLarge?.copyWith(
        fontWeight: flagged ? FontWeight.w700 : FontWeight.w500,
        color: flagged ? c.foreground : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        hintText: p.isNumeric ? null : (p.refText.isEmpty ? null : p.refText),
        suffixText: p.isNumeric && p.unit.isNotEmpty ? p.unit : null,
        fillColor: flagged ? c.background : null,
        enabledBorder: border,
        errorText: _tried ? p.problem(_raw(p)) : null,
      ),
    );
  }

  Widget _choiceField(BuildContext context, LabParam p, String flag) {
    final theme = Theme.of(context);
    final node = _nodes[p.key]!;
    void pick(String? v) => setState(() => _choices[p.key] = v);

    KeyEventResult onKey(FocusNode _, KeyEvent e) {
      if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
      final k = e.logicalKey;
      if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
        _next(p);
        return KeyEventResult.handled;
      }
      final cur = p.choices.indexOf(_choices[p.key] ?? '');
      if (k == LogicalKeyboardKey.arrowRight) {
        pick(p.choices[(cur + 1) % p.choices.length]);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft) {
        pick(p.choices[cur <= 0 ? p.choices.length - 1 : cur - 1]);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
        pick(null);
        return KeyEventResult.handled;
      }
      final ch = e.character?.toLowerCase() ?? '';
      if (ch.isEmpty) return KeyEventResult.ignored;
      final n = int.tryParse(ch);
      if (n != null && n >= 1 && n <= p.choices.length) {
        pick(p.choices[n - 1]);
        return KeyEventResult.handled;
      }
      // First letter picks; pressing it again moves to the next match.
      final matches = [for (final (i, c) in p.choices.indexed) if (c.toLowerCase().startsWith(ch)) i];
      if (matches.isEmpty) return KeyEventResult.ignored;
      final after = matches.where((i) => i > cur).toList();
      pick(p.choices[after.isEmpty ? matches.first : after.first]);
      return KeyEventResult.handled;
    }

    return Focus(
      focusNode: node,
      onKeyEvent: onKey,
      child: Builder(builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: focused ? theme.colorScheme.primary : Colors.transparent, width: 1.6),
          ),
          child: ExcludeFocus(
            child: Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final (i, choice) in p.choices.indexed)
                  _choiceChip(context, p, choice, i, node),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _choiceChip(BuildContext context, LabParam p, String choice, int i, FocusNode node) {
    final selected = _choices[p.key] == choice;
    final f = p.flagFor(choice, sex: widget.sex);
    final c = ToneColors.of(context, f.isEmpty ? Tone.success : Tone.warning);
    return ChoiceChip(
      key: ValueKey('lab.choice.${p.key}.$i'),
      label: Text(choice),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      selectedColor: p.normalChoices.isEmpty ? null : c.background,
      side: selected && p.normalChoices.isNotEmpty ? BorderSide(color: c.foreground) : null,
      labelStyle: selected && p.normalChoices.isNotEmpty ? TextStyle(color: c.foreground, fontWeight: FontWeight.w700) : null,
      onSelected: (on) {
        setState(() => _choices[p.key] = on ? choice : null);
        node.requestFocus();
      },
    );
  }
}

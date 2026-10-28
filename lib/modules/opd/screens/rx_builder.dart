import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../clinical_data.dart';
import 'opd_widgets.dart';

/// Options list shared by the autocomplete fields below.
Widget _optionsView<T extends Object>(
  BuildContext context, {
  required double width,
  required Iterable<T> options,
  required AutocompleteOnSelected<T> onSelected,
  required Widget Function(T option, bool highlighted) tile,
}) {
  final list = options.toList();
  return Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(Radii.md),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: 320, maxWidth: width),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          shrinkWrap: true,
          itemCount: list.length,
          itemBuilder: (c, i) {
            final highlighted = AutocompleteHighlightedOption.of(c) == i;
            if (highlighted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (c.mounted) Scrollable.ensureVisible(c, alignment: 0.5);
              });
            }
            return InkWell(onTap: () => onSelected(list[i]), child: tile(list[i], highlighted));
          },
        ),
      ),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

// ---------------------------------------------------------------- diagnosis

/// Diagnosis with suggestions (the doctor's frequent ones first) and the ICD
/// code filled in from the suggestion.
class DiagnosisField extends StatelessWidget {
  const DiagnosisField({
    super.key,
    required this.controller,
    required this.icd,
    required this.focusNode,
    required this.frequent,
  });
  final TextEditingController controller;
  final TextEditingController icd;
  final FocusNode focusNode;
  final List<DiagnosisOption> frequent;

  List<DiagnosisOption> get _all {
    final seen = <String>{};
    return [
      for (final d in [...frequent, ...commonDiagnoses])
        if (seen.add(d.name.toLowerCase())) d,
    ];
  }

  void _use(DiagnosisOption d) {
    final cur = controller.text.trim();
    if (cur.isEmpty || cur.toLowerCase() == d.name.toLowerCase()) {
      controller.text = d.name;
      icd.text = d.icd;
    } else if (!cur.toLowerCase().contains(d.name.toLowerCase())) {
      controller.text = '$cur; ${d.name}';
      if (d.icd.isNotEmpty) icd.text = icd.text.trim().isEmpty ? d.icd : '${icd.text.trim()}, ${d.icd}';
    }
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = frequent.isNotEmpty ? frequent.take(6).toList() : commonDiagnoses.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, c) {
          final icdWidth = c.maxWidth < 420 ? 96.0 : 120.0;
          final fieldWidth = c.maxWidth - icdWidth - Gap.sm;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RawAutocomplete<DiagnosisOption>(
                  textEditingController: controller,
                  focusNode: focusNode,
                  displayStringForOption: (d) => d.name,
                  optionsBuilder: (v) {
                    final q = v.text.trim().toLowerCase();
                    if (q.length < 2) return const [];
                    final words = q.split(RegExp(r'\s+'));
                    return _all
                        .where((d) => d.name.toLowerCase() != q)
                        .where((d) => words.every('${d.name} ${d.icd}'.toLowerCase().contains))
                        .take(8);
                  },
                  onSelected: (d) => icd.text = d.icd,
                  fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
                    controller: ctrl,
                    focusNode: focus,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => onSubmit(),
                    decoration: InputDecoration(
                      labelText: 'Diagnosis',
                      hintText: 'Type to search, e.g. "URTI" or "J06"',
                      helperText: '$modKeyLabel+D jumps here',
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                  optionsViewBuilder: (context, onSelected, options) => _optionsView<DiagnosisOption>(
                    context,
                    width: fieldWidth,
                    options: options,
                    onSelected: onSelected,
                    tile: (d, hi) => Container(
                      color: hi ? theme.colorScheme.primaryContainer : null,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(children: [
                        Expanded(child: Text(d.name, style: theme.textTheme.bodyMedium)),
                        if (frequent.any((f) => f.name == d.name)) ...[const StatusChip('Frequent', tone: Tone.info), Gap.h8],
                        Text(d.icd, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                ),
              ),
              Gap.h8,
              SizedBox(
                width: icdWidth,
                child: TextField(
                  controller: icd,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'ICD-10'),
                ),
              ),
            ],
          );
        }),
        Gap.v8,
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _FieldLabel(frequent.isNotEmpty ? 'Your frequent' : 'Common'),
            for (final d in chips)
              ActionChip(label: Text(d.name), visualDensity: VisualDensity.compact, onPressed: () => _use(d)),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- prescription

/// Write medicines fast: search, pick, tap a frequency and a duration, Enter.
/// Quantity is worked out; allergies are checked on every medicine.
class RxBuilder extends StatefulWidget {
  const RxBuilder({
    super.key,
    required this.items,
    required this.onChanged,
    required this.drugs,
    required this.allergies,
    this.lastRxLabel,
    this.onRepeatLast,
    this.usual = const [],
    this.usualFor,
    this.onUseUsual,
  });

  final List<Map<String, Object?>> items;
  final ValueChanged<List<Map<String, Object?>>> onChanged;
  final List<DrugOption> drugs;
  final String allergies;
  final String? lastRxLabel;
  final VoidCallback? onRepeatLast;
  final List<Map<String, Object?>> usual;
  final String? usualFor;
  final VoidCallback? onUseUsual;

  @override
  State<RxBuilder> createState() => RxBuilderState();
}

class RxBuilderState extends State<RxBuilder> {
  final _med = TextEditingController();
  final _dose = TextEditingController();
  final _freq = TextEditingController();
  final _days = TextEditingController();
  final _qty = TextEditingController();
  final _instr = TextEditingController();
  final _medFocus = FocusNode();
  final _doseFocus = FocusNode();
  final _freqFocus = FocusNode();
  final _daysFocus = FocusNode();
  final _qtyFocus = FocusNode();
  final _instrFocus = FocusNode();
  DrugOption? _picked;
  bool _qtyManual = false;
  int? _editing;
  String _route = 'Oral';

  bool get hasPendingEntry => _med.text.trim().isNotEmpty;
  String get pendingName => _med.text.trim();
  void focusMedicine() => _medFocus.requestFocus();

  @override
  void initState() {
    super.initState();
    _med.addListener(_medChanged);
    for (final c in [_dose, _freq, _days]) {
      c.addListener(_recalc);
    }
  }

  @override
  void dispose() {
    for (final c in [_med, _dose, _freq, _days, _qty, _instr]) {
      c.dispose();
    }
    for (final f in [_medFocus, _doseFocus, _freqFocus, _daysFocus, _qtyFocus, _instrFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _medChanged() {
    if (_picked != null && _med.text != _picked!.name) _picked = null;
    if (mounted) setState(() {});
  }

  String get _form => Rx.formOf(_picked?.form, _med.text);

  void _recalc() {
    if (_qtyManual) return;
    final q = Rx.quantity(
        frequency: _freq.text, days: int.tryParse(_days.text.trim()), form: _form, dose: _dose.text, name: _med.text);
    final t = q?.toString() ?? '';
    if (_qty.text != t) _qty.text = t;
    if (mounted) setState(() {});
  }

  String get _defaultDays {
    for (final m in widget.items.reversed) {
      final d = m['duration_days'];
      if (d is num && d > 0) return '${d.toInt()}';
    }
    return '5';
  }

  void _pick(DrugOption d) {
    final form = Rx.formOf(d.form, d.name);
    _picked = d;
    _qtyManual = false;
    _dose.text = d.defaultDose.isNotEmpty ? d.defaultDose : Rx.defaultDose(form);
    _freq.text = d.defaultFrequency.isNotEmpty ? d.defaultFrequency : '1-0-1';
    if (_days.text.trim().isEmpty) _days.text = _defaultDays;
    _route = Rx.defaultRoute(form, d.name);
    _recalc();
    _freqFocus.requestFocus();
    _freq.selection = TextSelection(baseOffset: 0, extentOffset: _freq.text.length);
  }

  /// A name typed that is not in the list: fill sensible defaults.
  void _freeText() {
    final form = _form;
    if (_dose.text.trim().isEmpty) _dose.text = Rx.defaultDose(form);
    if (_freq.text.trim().isEmpty) _freq.text = '1-0-1';
    if (_days.text.trim().isEmpty) _days.text = _defaultDays;
    _route = Rx.defaultRoute(form, _med.text);
    _recalc();
    _doseFocus.requestFocus();
  }

  void _clear() {
    _picked = null;
    _editing = null;
    _qtyManual = false;
    for (final c in [_med, _dose, _freq, _qty, _instr]) {
      c.clear();
    }
    _days.clear();
    _route = 'Oral';
    setState(() {});
  }

  void _edit(int i) {
    final m = widget.items[i];
    _editing = i;
    _picked = null;
    _med.text = m['drug_name'] as String? ?? '';
    _dose.text = m['dose'] as String? ?? '';
    _freq.text = m['frequency'] as String? ?? '';
    _days.text = (m['duration_days'] as num?)?.toInt().toString() ?? '';
    _instr.text = m['instructions'] as String? ?? '';
    _route = m['route'] as String? ?? 'Oral';
    _qty.text = (m['quantity'] as num?)?.toInt().toString() ?? '';
    _qtyManual = true;
    setState(() {});
    _medFocus.requestFocus();
  }

  void _remove(int i) {
    final list = [...widget.items]..removeAt(i);
    if (_editing == i) _clear();
    widget.onChanged(list);
  }

  Future<void> _add() async {
    final name = _med.text.trim();
    if (name.isEmpty) {
      _medFocus.requestFocus();
      return;
    }
    final generic = _picked?.generic ?? '';
    final allergy = Allergy.match(widget.allergies, drugName: name, genericName: generic);
    if (allergy != null) {
      final ok = await confirmDialog(
        context,
        title: 'Allergy warning',
        message: 'This patient is allergic to "$allergy". $name${generic.isEmpty ? '' : ' ($generic)'} '
            'may cause a reaction.\n\nPrescribe it anyway?',
        confirmLabel: 'Prescribe anyway',
        destructive: true,
      );
      if (!ok) {
        _medFocus.requestFocus();
        return;
      }
    }
    final item = <String, Object?>{
      'medicine_id': _picked?.id,
      'drug_name': name,
      'generic_name': generic.isEmpty ? null : generic,
      'strength': _picked?.strength.isEmpty ?? true ? null : _picked!.strength,
      'form': _form,
      'dose': _dose.text.trim(),
      'frequency': _freq.text.trim(),
      'duration_days': int.tryParse(_days.text.trim()),
      'route': _route,
      'instructions': _instr.text.trim(),
      'quantity': int.tryParse(_qty.text.trim()),
      'allergy_override': ?allergy,
    };
    final list = [...widget.items];
    final same = list.indexWhere((m) => (m['drug_name'] as String? ?? '').toLowerCase() == name.toLowerCase());
    if (_editing != null && _editing! < list.length) {
      list[_editing!] = item;
    } else if (same >= 0) {
      list[same] = item;
      if (mounted) context.toast('$name was already on the prescription. Updated it.');
    } else {
      list.add(item);
    }
    widget.onChanged(list);
    _clear();
    _medFocus.requestFocus();
  }

  Iterable<DrugOption> _options(TextEditingValue v) {
    final q = v.text.trim().toLowerCase();
    if (q.isEmpty || (_picked != null && _picked!.name == v.text)) return const [];
    final words = q.split(RegExp(r'\s+'));
    final starts = <DrugOption>[];
    final rest = <DrugOption>[];
    for (final d in widget.drugs) {
      final hay = '${d.name} ${d.generic}'.toLowerCase();
      if (!words.every(hay.contains)) continue;
      (d.name.toLowerCase().startsWith(q) || d.generic.toLowerCase().startsWith(q) ? starts : rest).add(d);
      if (starts.length >= 10) break;
    }
    return [...starts, ...rest].take(10);
  }

  Widget _medicineField(BuildContext context, double width) {
    final theme = Theme.of(context);
    return RawAutocomplete<DrugOption>(
      textEditingController: _med,
      focusNode: _medFocus,
      displayStringForOption: (d) => d.name,
      optionsBuilder: _options,
      onSelected: _pick,
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
        controller: ctrl,
        focusNode: focus,
        textInputAction: TextInputAction.next,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (_) {
          onSubmit();
          if (_picked == null && _med.text.trim().isNotEmpty) _freeText();
        },
        decoration: InputDecoration(
          labelText: _editing == null ? 'Medicine' : 'Medicine (editing)',
          hintText: 'Search name or generic',
          prefixIcon: const Icon(Icons.medication_outlined),
          isDense: true,
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => _optionsView<DrugOption>(
        context,
        width: width,
        options: options,
        onSelected: onSelected,
        tile: (d, hi) {
          final allergy = Allergy.match(widget.allergies, drugName: d.name, genericName: d.generic);
          return Container(
            color: hi ? theme.colorScheme.primaryContainer : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (d.detail.isNotEmpty) Caption(d.detail, maxLines: 1),
                  ],
                ),
              ),
              if (allergy != null) StatusChip('Allergy', icon: Icons.warning_amber_rounded, tone: Tone.danger),
            ]),
          );
        },
      ),
    );
  }

  Widget _small(String label, TextEditingController c, FocusNode f,
      {bool number = false, String? suffix, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      focusNode: f,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _add(),
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
    );
  }

  void _setFreq(String f) {
    _freq.text = f;
    if (_days.text.trim().isEmpty) _days.text = _defaultDays;
    _daysFocus.requestFocus();
  }

  void _setDays(int d) {
    _days.text = '$d';
    _instrFocus.requestFocus();
  }

  void _addInstruction(String s) {
    _instr.text = PhraseField.appendPhrase(_instr.text, s);
    _instr.selection = TextSelection.collapsed(offset: _instr.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = _med.text.trim();
    final warning =
        name.isEmpty ? null : Allergy.match(widget.allergies, drugName: name, genericName: _picked?.generic);
    final usualNames = widget.usual.map((m) => m['drug_name']).whereType<String>().toList();
    final haveNames = widget.items.map((m) => (m['drug_name'] as String? ?? '').toLowerCase()).toSet();
    final showUsual = widget.onUseUsual != null &&
        usualNames.isNotEmpty &&
        !usualNames.every((n) => haveNames.contains(n.toLowerCase()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onRepeatLast != null || showUsual) ...[
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              if (widget.onRepeatLast != null)
                OutlinedButton.icon(
                  onPressed: widget.onRepeatLast,
                  icon: const Icon(Icons.replay, size: 18),
                  label: Text('Repeat last prescription${widget.lastRxLabel == null ? '' : ' · ${widget.lastRxLabel}'}'),
                ),
              if (showUsual)
                OutlinedButton.icon(
                  onPressed: widget.onUseUsual,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text('Your usual for ${widget.usualFor}: ${usualNames.take(3).join(', ')}'
                      '${usualNames.length > 3 ? ' +${usualNames.length - 3}' : ''}'),
                ),
            ],
          ),
          Gap.v12,
        ],
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            border: Border.all(color: warning != null ? cs.error : cs.outlineVariant, width: warning != null ? 1.5 : 1),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 600;
            final medWidth = wide ? c.maxWidth - 116 - 120 - 76 - 76 - 4 * Gap.sm : c.maxWidth;
            final dose = _small('Dose', _dose, _doseFocus);
            final freq = _small('Frequency', _freq, _freqFocus);
            final days = _small('Days', _days, _daysFocus, number: true);
            final qty = _small('Qty', _qty, _qtyFocus, number: true, onChanged: (_) => _qtyManual = true);
            final freqChips = [
              for (final f in Rx.frequencies)
                ChoiceChip(
                  label: Text(f),
                  selected: _freq.text.trim().toUpperCase() == f.toUpperCase(),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _setFreq(f),
                ),
            ];
            final dayChips = [
              for (final d in Rx.durations)
                ChoiceChip(
                  label: Text(d == 30 ? '1 month' : '$d days'),
                  selected: _days.text.trim() == '$d',
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _setDays(d),
                ),
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _medicineField(context, medWidth)),
                    Gap.h8,
                    SizedBox(width: 116, child: dose),
                    Gap.h8,
                    SizedBox(width: 120, child: freq),
                    Gap.h8,
                    SizedBox(width: 76, child: days),
                    Gap.h8,
                    SizedBox(width: 76, child: qty),
                  ])
                else ...[
                  _medicineField(context, medWidth),
                  Gap.v8,
                  Row(children: [Expanded(child: dose), Gap.h8, Expanded(child: freq)]),
                  Gap.v8,
                  Row(children: [Expanded(child: days), Gap.h8, Expanded(child: qty)]),
                ],
                Gap.v8,
                if (wide)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [const _FieldLabel('Frequency'), ...freqChips, const SizedBox(width: Gap.md), const _FieldLabel('Days'), ...dayChips],
                  )
                else ...[
                  Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: freqChips),
                  Gap.v8,
                  Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: dayChips),
                ],
                Gap.v12,
                Row(children: [
                  Expanded(child: _small('Instructions', _instr, _instrFocus)),
                  Gap.h8,
                  if (_editing != null) ...[
                    TextButton(onPressed: _clear, child: const Text('Cancel')),
                    Gap.h4,
                  ],
                  FilledButton.icon(
                    onPressed: _add,
                    icon: Icon(_editing == null ? Icons.add : Icons.check, size: 18),
                    label: Text(_editing == null ? 'Add' : 'Update'),
                  ),
                ]),
                Gap.v8,
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in Rx.instructions)
                    ActionChip(label: Text(s), visualDensity: VisualDensity.compact, onPressed: () => _addInstruction(s)),
                ]),
                if (warning != null) ...[
                  Gap.v12,
                  _Warning('Allergy: this patient is allergic to "$warning". Check before prescribing $name.'),
                ],
                if (!context.isCompact) ...[
                  Gap.v8,
                  Caption('Enter adds the medicine · Tab moves to the next box · $modKeyLabel+M jumps to the medicine search'),
                ],
              ],
            );
          }),
        ),
        Gap.v12,
        if (widget.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.sm),
            child: Caption('No medicines yet. Search above, or repeat the last prescription.'),
          )
        else
          for (final (i, m) in widget.items.indexed)
            _RxItemTile(
              index: i,
              item: m,
              editing: _editing == i,
              allergy: Allergy.match(widget.allergies,
                  drugName: m['drug_name'] as String? ?? '', genericName: m['generic_name'] as String?),
              onEdit: () => _edit(i),
              onRemove: () => _remove(i),
            ),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, Tone.danger);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
          color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.sm)),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: c.foreground, size: 20),
        Gap.h8,
        Expanded(child: Text(text, style: TextStyle(color: c.foreground, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

class _RxItemTile extends StatelessWidget {
  const _RxItemTile({
    required this.index,
    required this.item,
    required this.allergy,
    required this.editing,
    required this.onEdit,
    required this.onRemove,
  });
  final int index;
  final Map<String, Object?> item;
  final String? allergy;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = item['drug_name'] as String? ?? '';
    final detail = [item['generic_name'], item['strength']].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final qty = item['quantity'];
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      decoration: BoxDecoration(
        color: editing ? cs.primaryContainer.withValues(alpha: 0.5) : cs.surface,
        border: Border.all(color: allergy != null ? cs.error : cs.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('${index + 1}.', style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: Gap.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(name, style: theme.textTheme.titleSmall),
                      if (detail.isNotEmpty) Caption(detail, maxLines: 1),
                    ]),
                    Gap.v4,
                    Text(Rx.line(item, withRoute: true), style: theme.textTheme.bodyMedium),
                    if (allergy != null) ...[
                      Gap.v4,
                      StatusChip('Allergy: $allergy', icon: Icons.warning_amber_rounded, tone: Tone.danger),
                    ],
                  ],
                ),
              ),
              if (qty is num) StatusChip('Qty ${qty.toInt()}'),
              IconButton(tooltip: 'Edit', onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
              IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.close, size: 20)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- tests

class OrdersBuilder extends StatefulWidget {
  const OrdersBuilder({super.key, required this.items, required this.onChanged, required this.tests});
  final List<Map<String, Object?>> items;
  final ValueChanged<List<Map<String, Object?>>> onChanged;
  final List<TestOption> tests;

  @override
  State<OrdersBuilder> createState() => _OrdersBuilderState();
}

class _OrdersBuilderState extends State<OrdersBuilder> {
  final _test = TextEditingController();
  final _focus = FocusNode();
  TestOption? _picked;
  String _priority = 'routine';

  static const priorities = [('routine', 'Routine'), ('urgent', 'Urgent'), ('stat', 'STAT')];

  @override
  void initState() {
    super.initState();
    _test.addListener(() {
      if (_picked != null && _test.text != _picked!.name) _picked = null;
    });
  }

  @override
  void dispose() {
    _test.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add([TestOption? quick]) {
    final t = quick ?? _picked;
    final name = (t?.name ?? _test.text).trim();
    if (name.isEmpty) {
      _focus.requestFocus();
      return;
    }
    if (widget.items.any((o) => (o['name'] as String? ?? '').toLowerCase() == name.toLowerCase())) {
      context.toast('$name is already ordered');
    } else {
      widget.onChanged([
        ...widget.items,
        {
          'service_code': t?.code,
          'name': name,
          'order_type': t?.type ?? (name.toLowerCase().contains('x-ray') || name.toLowerCase().startsWith('usg') ? 'radiology' : 'lab'),
          'priority': quick != null ? 'routine' : _priority,
        },
      ]);
    }
    if (quick == null) {
      _test.clear();
      _picked = null;
      _priority = 'routine';
      setState(() {});
      _focus.requestFocus();
    }
  }

  List<TestOption> get _quick {
    final out = <TestOption>[];
    for (final q in quickTestNames) {
      final l = q.toLowerCase();
      final hit = widget.tests.where((t) => t.name.toLowerCase().contains(l) || (t.code ?? '').toLowerCase().contains(l)).firstOrNull;
      if (hit != null && !out.contains(hit)) out.add(hit);
    }
    return out;
  }

  String _short(TestOption t) {
    for (final q in quickTestNames) {
      if (t.name.toLowerCase().contains(q.toLowerCase()) || (t.code ?? '').toLowerCase().contains(q.toLowerCase())) return q;
    }
    return t.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ordered = widget.items.map((o) => (o['name'] as String? ?? '').toLowerCase()).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 600;
          final field = RawAutocomplete<TestOption>(
            textEditingController: _test,
            focusNode: _focus,
            displayStringForOption: (t) => t.name,
            optionsBuilder: (v) {
              final q = v.text.trim().toLowerCase();
              if (q.isEmpty || (_picked != null && _picked!.name == v.text)) return const [];
              final words = q.split(RegExp(r'\s+'));
              return widget.tests.where((t) => words.every('${t.name} ${t.code ?? ''}'.toLowerCase().contains)).take(10);
            },
            onSelected: (t) => setState(() => _picked = t),
            fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
              controller: ctrl,
              focusNode: focus,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final before = _picked;
                onSubmit();
                // Enter on a highlighted suggestion picks it; Enter again adds.
                if (_picked == before) _add();
              },
              decoration: const InputDecoration(
                labelText: 'Add a test',
                hintText: 'Search lab or X-ray',
                prefixIcon: Icon(Icons.biotech_outlined),
                isDense: true,
              ),
            ),
            optionsViewBuilder: (context, onSelected, options) => _optionsView<TestOption>(
              context,
              width: wide ? c.maxWidth - 250 - 100 : c.maxWidth,
              options: options,
              onSelected: onSelected,
              tile: (t, hi) => Container(
                color: hi ? cs.primaryContainer : null,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Expanded(child: Text(t.name)),
                  Text(t.type == 'radiology' ? 'Radiology' : 'Lab',
                      style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            ),
          );
          final priority = SegmentedButton<String>(
            segments: [for (final (v, l) in priorities) ButtonSegment(value: v, label: Text(l))],
            selected: {_priority},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          );
          final add = FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.add, size: 18), label: const Text('Add'));
          if (wide) {
            return Row(children: [Expanded(child: field), Gap.h8, priority, Gap.h8, add]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            field,
            Gap.v8,
            Row(children: [Expanded(child: priority), Gap.h8, add]),
          ]);
        }),
        Gap.v8,
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const _FieldLabel('Quick add'),
            for (final t in _quick)
              ActionChip(
                label: Text(_short(t)),
                avatar: Icon(ordered.contains(t.name.toLowerCase()) ? Icons.check : Icons.add, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: ordered.contains(t.name.toLowerCase()) ? null : () => _add(t),
              ),
          ],
        ),
        Gap.v12,
        if (widget.items.isEmpty)
          const Caption('No tests ordered.')
        else
          for (final (i, o) in widget.items.indexed)
            Container(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              padding: const EdgeInsets.fromLTRB(Gap.md, 4, 4, 4),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outlineVariant),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                Icon(o['order_type'] == 'radiology' ? Icons.image_outlined : Icons.biotech_outlined,
                    size: 20, color: cs.onSurfaceVariant),
                Gap.h12,
                Expanded(
                  child: TwoLine(
                    o['name'] as String? ?? '',
                    [o['order_type'] == 'radiology' ? 'Radiology' : 'Lab', o['service_code']]
                        .whereType<String>()
                        .where((s) => s.isNotEmpty)
                        .join(' · '),
                  ),
                ),
                Tooltip(
                  message: 'Tap to change priority',
                  child: ActionChip(
                    label: Text(switch (o['priority']) { 'stat' => 'STAT', 'urgent' => 'Urgent', _ => 'Routine' }),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: o['priority'] == 'routine' || o['priority'] == null
                        ? null
                        : ToneColors.of(context, o['priority'] == 'stat' ? Tone.danger : Tone.warning).background,
                    onPressed: () {
                      final next = switch (o['priority']) { 'routine' || null => 'urgent', 'urgent' => 'stat', _ => 'routine' };
                      final list = [...widget.items];
                      list[i] = {...o, 'priority': next};
                      widget.onChanged(list);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => widget.onChanged([...widget.items]..removeAt(i)),
                ),
              ]),
            ),
      ],
    );
  }
}

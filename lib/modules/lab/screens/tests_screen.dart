import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

class _Catalogue {
  _Catalogue(this.tests, this.prices);
  final List<Rec> tests;
  final Map<String, Rec> prices;
}

/// The test catalogue: parameters, reference ranges, turnaround and price.
class LabTestsScreen extends StatefulWidget {
  const LabTestsScreen({super.key});

  @override
  State<LabTestsScreen> createState() => _LabTestsScreenState();
}

class _LabTestsScreenState extends State<LabTestsScreen> {
  String _search = '';
  String _dept = '';

  Future<_Catalogue> _load(ReadDb db) async {
    var q = const Query(LabCol.tests).matching(_search).sort('name').take(300).withArchived();
    if (_dept.isNotEmpty) q = q.eq('department', _dept);
    final tests = await db.query(q);
    return _Catalogue(tests, await LabService.pricesByCode(db, tests.map((t) => t.str('code'))));
  }

  Future<void> _edit(Rec? test, Rec? price) =>
      showFormSheet<void>(context, title: test == null ? 'New lab test' : test.str('name'), width: 960, builder: (c) => TestEditor(test: test, price: price));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageScaffold(
      title: 'Lab tests',
      subtitle: 'Parameters, reference ranges, turnaround and prices',
      primaryAction: PageAction('New test', Icons.add, () => _edit(null, null)),
      headerBottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchField(hint: 'Test name or code', onChanged: (v) => setState(() => _search = v)),
          Gap.v12,
          FilterChips<String>(
            options: [('', 'All'), for (final d in labDepartments) d],
            value: _dept,
            onChanged: (d) => setState(() => _dept = d),
          ),
        ],
      ),
      body: LiveBuilder<_Catalogue>(
        watch: const {LabCol.tests, Col.services},
        deps: [_search, _dept],
        load: _load,
        builder: (context, c) {
          Widget params(Rec t) {
            final ps = paramsOf(t);
            final crit = ps.where((p) => p.hasCriticalLimits).length;
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${ps.length}'),
              if (crit > 0) ...[
                Gap.h8,
                Tooltip(
                  message: '${plural(crit, 'parameter')} with critical limits',
                  child: Icon(Icons.warning_amber_rounded, size: 16, color: ToneColors.of(context, Tone.danger).foreground),
                ),
              ],
            ]);
          }

          Widget status(Rec t) => t.flag('active') && !t.archived
              ? const StatusChip('Active', tone: Tone.success)
              : const StatusChip('Off');
          final wide = context.isExpanded;
          return DataList<Rec>(
            items: c.tests,
            empty: EmptyState(
              icon: Icons.science_outlined,
              title: _search.isEmpty ? 'No tests yet' : 'No test matches "$_search"',
              message: 'Add the tests your lab runs, with their reference ranges.',
            ),
            onTap: (t) => _edit(t, c.prices[t.str('code')]),
            title: (t) => t.str('name'),
            subtitle: (t) => [
              t.str('code'),
              departmentLabel(t.str('department')),
              plural(paramsOf(t).length, 'parameter'),
              formatMoney(c.prices[t.str('code')]?.integer('price_paise'), alwaysDecimals: false),
            ].join(' · '),
            trailing: (t) => t.flag('active') ? const SizedBox.shrink() : const StatusChip('Off'),
            columns: [
              ListColumn('Test', (t) => TwoLine(t.str('name'), t.str('code')), flex: 5),
              ListColumn('Department', (t) => Text(departmentLabel(t.str('department'))), flex: 2),
              if (wide) ListColumn('Sample', (t) => TwoLine(t.str('sample_type'), t.str('container')), flex: 3),
              ListColumn('Parameters', params, width: 100),
              ListColumn('Report in', (t) => Text(formatDuration(Duration(minutes: t.integer('tat_minutes', defaultTatMinutes)))),
                  width: 100),
              ListColumn('Price', (t) => MoneyText(c.prices[t.str('code')]?.integer('price_paise'), style: theme.textTheme.bodyMedium),
                  width: 110, numeric: true),
              ListColumn('Status', status, width: 90),
            ],
          );
        },
      ),
    );
  }
}

/// Holds the text of one parameter while it is edited.
class _ParamDraft {
  _ParamDraft(LabParam p)
      : key = p.key,
        kind = p.kind,
        name = TextEditingController(text: p.name),
        short = TextEditingController(text: p.short),
        unit = TextEditingController(text: p.unit),
        low = TextEditingController(text: _num(p.low)),
        high = TextEditingController(text: _num(p.high)),
        fLow = TextEditingController(text: _num(p.femaleLow)),
        fHigh = TextEditingController(text: _num(p.femaleHigh)),
        cLow = TextEditingController(text: _num(p.criticalLow)),
        cHigh = TextEditingController(text: _num(p.criticalHigh)),
        ref = TextEditingController(text: p.refText),
        choices = TextEditingController(text: p.choices.join(', ')),
        decimals = TextEditingController(text: '${p.decimals}');

  static String _num(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }

  String key;
  String kind;
  final TextEditingController name, short, unit, low, high, fLow, fHigh, cLow, cHigh, ref, choices, decimals;

  List<TextEditingController> get all => [name, short, unit, low, high, fLow, fHigh, cLow, cHigh, ref, choices, decimals];

  static double? _d(TextEditingController c) => c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());

  LabParam build() => LabParam(
        key: key,
        name: name.text.trim(),
        short: short.text.trim(),
        unit: unit.text.trim(),
        kind: kind,
        low: kind == LabParam.numeric ? _d(low) : null,
        high: kind == LabParam.numeric ? _d(high) : null,
        femaleLow: kind == LabParam.numeric ? _d(fLow) : null,
        femaleHigh: kind == LabParam.numeric ? _d(fHigh) : null,
        criticalLow: kind == LabParam.numeric ? _d(cLow) : null,
        criticalHigh: kind == LabParam.numeric ? _d(cHigh) : null,
        refText: ref.text.trim(),
        choices: kind == LabParam.choice
            ? choices.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
            : const [],
        decimals: int.tryParse(decimals.text.trim()) ?? 0,
      );

  void dispose() {
    for (final c in all) {
      c.dispose();
    }
  }
}

/// Edits one test and its price. The price lives in the core price list,
/// so only people allowed to change prices can change it here.
class TestEditor extends StatefulWidget {
  const TestEditor({super.key, this.test, this.price});
  final Rec? test;
  final Rec? price;

  @override
  State<TestEditor> createState() => _TestEditorState();
}

class _TestEditorState extends State<TestEditor> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.test?.str('code') ?? 'LAB-');
  late final _name = TextEditingController(text: widget.test?.str('name') ?? '');
  late final _sample = TextEditingController(text: widget.test?.str('sample_type') ?? '');
  late final _container = TextEditingController(text: widget.test?.str('container') ?? '');
  late final _tat = TextEditingController(text: '${widget.test?.integer('tat_minutes', defaultTatMinutes) ?? defaultTatMinutes}');
  late final _price = TextEditingController(text: moneyInput(widget.price?.integer('price_paise')));
  late String _dept = widget.test?.str('department', 'biochemistry') ?? 'biochemistry';
  late bool _active = widget.test?.flag('active') ?? true;
  late final List<_ParamDraft> _params = [for (final p in paramsOf(widget.test)) _ParamDraft(p)];
  bool _saving = false;

  bool get _isNew => widget.test == null;

  @override
  void dispose() {
    for (final c in [_code, _name, _sample, _container, _tat, _price]) {
      c.dispose();
    }
    for (final p in _params) {
      p.dispose();
    }
    super.dispose();
  }

  bool get _canPrice => context.can(CorePerms.pricesEdit) || context.can(CorePerms.adminSettings);

  static String _slug(String s) {
    final k = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return k.isEmpty ? 'p' : (k.length > 20 ? k.substring(0, 20) : k);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_params.isEmpty) {
      context.toast('Add at least one parameter', error: true);
      return;
    }
    // Give new parameters stable keys from their names.
    final used = <String>{};
    for (final p in _params) {
      if (p.key.isEmpty) p.key = _slug(p.name.text);
      var k = p.key;
      var n = 2;
      while (!used.add(k)) {
        k = '${p.key}_${n++}';
      }
      p.key = k;
    }
    final code = _code.text.trim().toUpperCase();
    final data = {
      'code': code,
      'name': _name.text.trim(),
      'department': _dept,
      'sample_type': _sample.text.trim(),
      'container': _container.text.trim(),
      'tat_minutes': int.tryParse(_tat.text.trim()) ?? defaultTatMinutes,
      'parameters': [for (final p in _params) p.build().toJson()],
      'active': _active,
    };
    final price = parseMoney(_price.text);
    final db = context.db;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      final ops = <WriteOp>[
        _isNew
            ? InsertOp(LabCol.tests, data)
            : UpdateOp(LabCol.tests, widget.test!.id, data, expectedVersion: widget.test!.version),
      ];
      if (_canPrice && price != null) {
        final cur = widget.price ?? await db.first(Query(Col.services).eq('code', code));
        if (cur == null) {
          ops.add(InsertOp(Col.services, {
            'code': code,
            'name': _name.text.trim(),
            'category': Vals.lab,
            'price_paise': price,
            'department': departmentLabel(_dept),
            'active': _active,
          }));
        } else if (cur.integer('price_paise') != price || cur.str('name') != _name.text.trim() || cur.flag('active') != _active) {
          ops.add(UpdateOp(Col.services, cur.id, {'price_paise': price, 'name': _name.text.trim(), 'active': _active},
              expectedVersion: cur.version));
        }
      }
      await db.batch(ops);
    }, success: _isNew ? 'Test added' : 'Saved');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGrid(minFieldWidth: 240, children: [
            AppTextField(
              label: 'Code',
              controller: _code,
              enabled: _isNew,
              helper: _isNew ? 'Same as the price-list code, e.g. LAB-CBC' : null,
              textCapitalization: TextCapitalization.characters,
              validator: Validators.required('Code'),
            ),
            AppTextField(label: 'Test name', controller: _name, validator: Validators.required('Test name')),
            AppDropdown<String>(
              label: 'Department',
              value: _dept,
              items: labDepartments,
              onChanged: (v) => setState(() => _dept = v ?? _dept),
            ),
            AppTextField(label: 'Sample type', controller: _sample, hint: 'e.g. Serum'),
            AppTextField(label: 'Container', controller: _container, hint: 'e.g. Plain / SST (yellow top)'),
            AppTextField(
              label: 'Report within (minutes)',
              controller: _tat,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: Validators.positiveInt,
            ),
            _canPrice
                ? MoneyField(label: 'Price', controller: _price, required: true)
                : AppTextField(
                    label: 'Price',
                    initialValue: formatMoney(widget.price?.integer('price_paise')),
                    enabled: false,
                    helper: 'Prices are changed by an administrator or accountant',
                  ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Available to order'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ]),
          Gap.v24,
          Row(children: [
            Expanded(child: Text('Parameters', style: theme.textTheme.titleMedium)),
            OutlinedButton.icon(
              onPressed: () => setState(() => _params.add(_ParamDraft(const LabParam(key: '', name: '')))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add parameter'),
            ),
          ]),
          Gap.v4,
          Text('Values outside the range are flagged H or L; outside the critical limits, HH or LL, and the doctor is alerted.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Gap.v12,
          for (final (i, p) in _params.indexed) ...[
            _paramCard(context, p, i),
            Gap.v12,
          ],
          Gap.v12,
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_isNew ? 'Add test' : 'Save changes'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paramCard(BuildContext context, _ParamDraft p, int i) {
    final theme = Theme.of(context);
    final numeric = p.kind == LabParam.numeric;
    String? number(String? v) => (v == null || v.trim().isEmpty || double.tryParse(v.trim()) != null) ? null : 'Enter a number';
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('${i + 1}', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Gap.h12,
            Expanded(
              child: Text(p.name.text.isEmpty ? 'New parameter' : p.name.text,
                  style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'Move up',
              onPressed: i == 0 ? null : () => setState(() => _params.insert(i - 1, _params.removeAt(i))),
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
            IconButton(
              tooltip: 'Remove parameter',
              onPressed: () => setState(() => _params.removeAt(i).dispose()),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
          ]),
          Gap.v8,
          FormGrid(minFieldWidth: 180, maxColumns: 4, children: [
            AppTextField(label: 'Name', controller: p.name, validator: Validators.required('Name'), onChanged: (_) => setState(() {})),
            AppTextField(label: 'Short name', controller: p.short, hint: 'e.g. Hb'),
            AppDropdown<String>(
              label: 'Kind',
              value: p.kind,
              items: const [(LabParam.numeric, 'Number'), (LabParam.choice, 'Choice'), (LabParam.text, 'Text')],
              onChanged: (v) => setState(() => p.kind = v ?? p.kind),
            ),
            if (numeric) AppTextField(label: 'Unit', controller: p.unit, hint: 'e.g. g/dL'),
            if (numeric) AppTextField(label: 'Low', controller: p.low, keyboardType: TextInputType.number, validator: number),
            if (numeric) AppTextField(label: 'High', controller: p.high, keyboardType: TextInputType.number, validator: number),
            if (numeric) AppTextField(label: 'Critical below', controller: p.cLow, keyboardType: TextInputType.number, validator: number),
            if (numeric) AppTextField(label: 'Critical above', controller: p.cHigh, keyboardType: TextInputType.number, validator: number),
            if (numeric) AppTextField(label: 'Female low', controller: p.fLow, keyboardType: TextInputType.number, validator: number),
            if (numeric) AppTextField(label: 'Female high', controller: p.fHigh, keyboardType: TextInputType.number, validator: number),
            if (numeric)
              AppTextField(
                label: 'Decimals',
                controller: p.decimals,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            if (p.kind == LabParam.choice)
              FullWidth(
                child: AppTextField(
                  label: 'Choices',
                  controller: p.choices,
                  hint: 'Comma separated, e.g. Negative, Positive',
                  validator: Validators.required('Choices'),
                ),
              ),
            FullWidth(
              child: AppTextField(
                label: p.kind == LabParam.choice ? 'Normal answer(s)' : 'Reference text',
                controller: p.ref,
                hint: p.kind == LabParam.choice
                    ? 'e.g. Negative. Separate several with "/". Leave empty if no answer is abnormal.'
                    : 'Optional. Shown instead of the range, e.g. "< 100 optimal"',
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

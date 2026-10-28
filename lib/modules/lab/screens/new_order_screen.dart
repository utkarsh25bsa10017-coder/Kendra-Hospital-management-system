import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_catalog.dart';
import '../lab_schema.dart';
import '../lab_service.dart';
import 'lab_widgets.dart';

/// Walk-in or phoned-in orders: pick the patient, tick tests, choose priority.
class LabNewOrderScreen extends StatefulWidget {
  const LabNewOrderScreen({super.key, this.patientId});
  final String? patientId;

  @override
  State<LabNewOrderScreen> createState() => _LabNewOrderScreenState();
}

class _LabNewOrderScreenState extends State<LabNewOrderScreen> {
  bool _loading = true;
  bool _saving = false;
  Rec? _patient;
  Map<String, Rec> _tests = const {};
  Map<String, Rec> _prices = const {};
  Set<String> _pending = const {};
  final _selected = <String>[];
  String _priority = Priority.routine;
  String _search = '';
  final _notes = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final tests = await LabService.testsByCode(db, activeOnly: true);
    final prices = await LabService.pricesByCode(db, tests.keys);
    final patient = widget.patientId == null ? null : await db.get(Col.patients, widget.patientId);
    if (!mounted) return;
    setState(() {
      _tests = tests;
      _prices = prices;
      _loading = false;
    });
    await _setPatient(patient);
  }

  Future<void> _setPatient(Rec? p) async {
    var pending = <String>{};
    if (p != null) {
      final open = await context.app.readDb.query(LabService.labOrders()
          .eq('patient_id', p.id)
          .isIn('status', [Vals.ordered, Vals.collected, Vals.resulted])
          .take(50));
      pending = {for (final o in open) o.str('service_code')};
    }
    if (mounted) {
      setState(() {
        _patient = p;
        _pending = pending;
      });
    }
  }

  Future<void> _choosePatient() async {
    final p = await pickPatient(context, title: 'Who is the test for?');
    if (p != null) await _setPatient(p);
  }

  int _price(String code) => _prices[code]?.integer('price_paise') ?? 0;
  int get _total => _selected.fold(0, (a, c) => a + _price(c));

  void _toggle(String code) => setState(() => _selected.contains(code) ? _selected.remove(code) : _selected.add(code));

  void _togglePanel(List<String> codes) {
    final available = codes.where(_tests.containsKey).toList();
    setState(() {
      if (available.every(_selected.contains)) {
        _selected.removeWhere(available.contains);
      } else {
        for (final c in available) {
          if (!_selected.contains(c)) _selected.add(c);
        }
      }
    });
  }

  Future<void> _place() async {
    final p = _patient;
    if (p == null) {
      context.toast('Choose the patient first', error: true);
      return;
    }
    if (_selected.isEmpty) {
      context.toast('Tick at least one test', error: true);
      return;
    }
    final app = context.app;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      final encounter = await app.readDb.first(Query(Col.encounters)
          .eq('patient_id', p.id)
          .eq('status', Vals.open)
          .sort('started_at', desc: true));
      await LabService.createOrders(app.db,
          patientId: p.id,
          tests: [for (final c in _selected) _tests[c]!],
          priority: _priority,
          notes: _notes.text,
          encounterId: encounter?.id);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    app.nav.toast('Ordered ${plural(_selected.length, 'test')} for ${p.str('full_name')}'
        '${_priority == Priority.stat ? ' as STAT' : ''}');
    if (nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PageScaffold(title: 'New lab order', body: LoadingView());
    final n = _selected.length;
    return PageScaffold(
      title: 'New lab order',
      subtitle: _patient == null ? 'Choose the patient, then tick the tests' : 'For ${_patient!.str('full_name')}',
      maxWidth: 1240,
      primaryAction: PageAction(n == 0 ? 'Place order' : 'Place order · ${plural(n, 'test')}', Icons.send_outlined,
          _saving ? null : _place),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 980;
        if (!wide) {
          // Narrow: priority before the long test list, the bill at the end.
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _patientCard(context),
            Gap.v16,
            _optionsCard(context),
            Gap.v16,
            _testsCard(context),
            Gap.v16,
            _summaryCard(context),
          ]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Column(children: [_patientCard(context), Gap.v16, _testsCard(context)])),
            Gap.h24,
            SizedBox(
              width: 380,
              child: Column(children: [_summaryCard(context), Gap.v16, _optionsCard(context)]),
            ),
          ],
        );
      }),
    );
  }

  Widget _patientCard(BuildContext context) {
    final theme = Theme.of(context);
    final p = _patient;
    return SectionCard(
      title: 'Patient',
      child: p == null
          ? Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _choosePatient,
                icon: const Icon(Icons.person_search_outlined),
                label: const Text('Choose patient'),
              ),
            )
          : Row(
              children: [
                Avatar(p.str('full_name'), size: 40),
                Gap.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.str('full_name'), style: theme.textTheme.titleSmall),
                      Text(patientLine(p), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      if (p.str('allergies').isNotEmpty) ...[
                        Gap.v4,
                        StatusChip('Allergies: ${p.str('allergies')}', tone: Tone.danger, icon: Icons.warning_amber_rounded),
                      ],
                    ],
                  ),
                ),
                TextButton(onPressed: _choosePatient, child: const Text('Change')),
              ],
            ),
    );
  }

  Widget _testsCard(BuildContext context) {
    final theme = Theme.of(context);
    final words = _search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    bool match(Rec t) {
      final hay = '${t.str('name')} ${t.str('code')} ${departmentLabel(t.str('department'))}'.toLowerCase();
      return words.every(hay.contains);
    }

    final byDept = <String, List<Rec>>{};
    for (final t in _tests.values.where(match)) {
      byDept.putIfAbsent(t.str('department'), () => []).add(t);
    }
    final order = [for (final (d, _) in labDepartments) d, ...byDept.keys.where((k) => !labDepartments.any((e) => e.$1 == k))];

    return SectionCard(
      title: 'Tests',
      subtitle: '${_tests.length} available',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchField(hint: 'Search by test name or code', onChanged: (v) => setState(() => _search = v)),
          Gap.v12,
          Text('Common panels', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Gap.v8,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final (name, codes) in labPanels)
                FilterChip(
                  label: Text('$name · ${codes.where(_tests.containsKey).length}'),
                  selected: codes.where(_tests.containsKey).isNotEmpty && codes.where(_tests.containsKey).every(_selected.contains),
                  onSelected: (_) => _togglePanel(codes),
                ),
            ],
          ),
          Gap.v8,
          if (byDept.isEmpty)
            const EmptyState(icon: Icons.search_off, title: 'No test matches', message: 'Try another name or code.')
          else
            for (final d in order)
              if (byDept[d] != null) ...[
                SubHeading(departmentLabel(d)),
                for (final t in byDept[d]!) _testRow(context, t),
              ],
        ],
      ),
    );
  }

  Widget _testRow(BuildContext context, Rec t) {
    final theme = Theme.of(context);
    final code = t.str('code');
    final on = _selected.contains(code);
    final tat = t.intOrNull('tat_minutes');
    final already = _pending.contains(code);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () => _toggle(code),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(value: on, onChanged: (_) => _toggle(code)),
            Gap.h4,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.str('name'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: on ? FontWeight.w600 : null)),
                  Text(
                    [t.str('sample_type'), if (tat != null) 'report in ${formatDuration(Duration(minutes: tat))}'].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (already) ...[
              const StatusChip('Already ordered', tone: Tone.warning),
              Gap.h8,
            ],
            MoneyText(_price(code), style: theme.textTheme.bodyMedium),
            Gap.h8,
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    final theme = Theme.of(context);
    final dupes = _selected.where(_pending.contains).toList();
    return SectionCard(
      title: 'Order',
      subtitle: _selected.isEmpty ? 'Nothing ticked yet' : plural(_selected.length, 'test'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selected.isEmpty)
            Text('Tick tests or tap a panel.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          else
            for (final c in _selected)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(_tests[c]?.str('name') ?? c, overflow: TextOverflow.ellipsis)),
                  MoneyText(_price(c)),
                  IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _toggle(c),
                  ),
                ]),
              ),
          const Divider(height: Gap.xl),
          Row(children: [
            Expanded(child: Text('Total', style: theme.textTheme.titleSmall)),
            MoneyText(_total, style: theme.textTheme.titleMedium),
          ]),
          Text('Charged when the sample is collected.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (dupes.isNotEmpty) ...[
            Gap.v12,
            LabBanner(
              tone: Tone.warning,
              icon: Icons.content_copy,
              title: 'Already ordered and not reported yet',
              message: dupes.map((c) => _tests[c]?.str('name') ?? c).join(', '),
            ),
          ],
          if (!context.isCompact) ...[
            Gap.v16,
            FilledButton.icon(
              onPressed: _saving ? null : _place,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Place order'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _optionsCard(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Priority and notes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: Priority.routine, label: Text('Routine')),
              ButtonSegment(value: Priority.urgent, label: Text('Urgent')),
              ButtonSegment(value: Priority.stat, label: Text('STAT'), icon: Icon(Icons.bolt, size: 18)),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          if (_priority == Priority.stat) ...[
            Gap.v8,
            Text('STAT reports are due within 1 hour. Use for emergencies only.',
                style: theme.textTheme.bodySmall?.copyWith(color: ToneColors.of(context, Tone.danger).foreground)),
          ],
          Gap.v16,
          AppTextField(label: 'Clinical notes for the lab', controller: _notes, maxLines: 3, hint: 'e.g. Fever for 3 days, on antibiotics'),
        ],
      ),
    );
  }
}

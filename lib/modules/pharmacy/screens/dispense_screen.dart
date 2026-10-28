import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_service.dart';
import 'pharmacy_widgets.dart';

/// One medicine on the counter: what was prescribed, the product matched to
/// it, how many, and which batches they come from.
class _Line {
  _Line({this.rxIndex, this.item, this.product, this.matchedBy, required this.qty, this.alreadyDone = false})
      : originalProduct = product;
  final int? rxIndex;
  final Map<String, Object?>? item;
  Rec? product;
  final Rec? originalProduct;
  String? matchedBy; // medicine | name | generic | manual | substitute
  int qty;
  bool alreadyDone;
  bool include = true;
  bool manualBatches = false;
  List<BatchPick> picks = const [];
  int shortBy = 0;

  int get picked => picks.fold(0, (a, p) => a + p.qty);
  int get amount => picks.fold(0, (a, p) => a + p.qty * p.batch.integer('mrp_paise', product?.integer('mrp_paise') ?? 0));
  bool get active => include && !alreadyDone && product != null && picked > 0;
}

/// Dispense a prescription ([prescriptionId]) or make a counter sale.
/// Products are matched and batches picked first-expiry-first-out, so the
/// pharmacist mostly confirms.
class DispenseScreen extends StatefulWidget {
  const DispenseScreen({super.key, this.prescriptionId, this.patientId});
  final String? prescriptionId;
  final String? patientId;

  @override
  State<DispenseScreen> createState() => _DispenseScreenState();
}

class _DispenseScreenState extends State<DispenseScreen> {
  bool _loading = true;
  bool _saving = false;
  Rec? _rx;
  Rec? _patient;
  Rec? _doctor;
  late ProductIndex _index;
  Map<String, StockInfo> _stock = {};
  Map<String, Rec> _medicines = {};
  final _lines = <_Line>[];

  bool get _isRx => widget.prescriptionId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    Rec? rx;
    Rec? patient;
    Rec? doctor;
    if (widget.prescriptionId != null) {
      rx = await db.get(Col.prescriptions, widget.prescriptionId);
      patient = await db.get(Col.patients, rx?.strOrNull('patient_id'));
      doctor = await db.get(Col.users, rx?.strOrNull('doctor_id'));
    } else if (widget.patientId != null) {
      patient = await db.get(Col.patients, widget.patientId);
    }
    final products = await PharmacyService.activeProducts(db);
    final batches = await PharmacyService.batchesWithStock(db);
    final meds = await db.byIds(Col.medicines, [
      for (final i in rx?.maps('items') ?? const <Map<String, Object?>>[]) i['medicine_id'] as String?,
      for (final p in products) p.strOrNull('medicine_id'),
    ]);
    _medicines = meds;
    _index = ProductIndex(products, medicines: meds);
    _stock = PharmacyService.summarize(products, batches);
    if (rx != null) {
      for (final (i, item) in rx.maps('items').indexed) {
        final (product, how) = _index.match(item, stock: _stock);
        final unit = product?.str('unit');
        final remaining = PharmacyService.remainingQty(item, unit: unit);
        final line = _Line(rxIndex: i, item: item, product: product, matchedBy: how, qty: remaining, alreadyDone: remaining == 0);
        _lines.add(line);
      }
    }
    _recompute();
    for (final l in _lines) {
      l.include = !l.alreadyDone && l.product != null && l.picked > 0;
    }
    if (!mounted) return;
    setState(() {
      _rx = rx;
      _patient = patient;
      _doctor = doctor;
      _loading = false;
    });
  }

  /// Re-picks batches (FEFO) for every line not set by hand, so two lines of
  /// the same product never claim the same units.
  void _recompute() {
    final taken = <String, int>{};
    for (final l in _lines.where((l) => l.manualBatches && l.include)) {
      for (final p in l.picks) {
        taken[p.batch.id] = (taken[p.batch.id] ?? 0) + p.qty;
      }
    }
    for (final l in _lines) {
      if (l.manualBatches || l.alreadyDone) continue;
      final p = l.product;
      if (p == null) {
        l.picks = const [];
        l.shortBy = l.qty;
        continue;
      }
      final avail = [
        for (final b in _stock[p.id]?.batches ?? const <Rec>[])
          b.copyWith({'qty_on_hand': b.integer('qty_on_hand') - (taken[b.id] ?? 0)})
      ];
      final r = PharmacyService.pickFefo(avail, l.qty);
      l.picks = r.picks;
      l.shortBy = r.shortBy;
      if (l.include) {
        for (final pk in r.picks) {
          taken[pk.batch.id] = (taken[pk.batch.id] ?? 0) + pk.qty;
        }
      }
    }
  }

  void _update(VoidCallback f) => setState(() {
        f();
        _recompute();
      });

  int _defaultQty(Rec p) => {'tablet', 'capsule'}.contains(p.str('unit')) ? 10 : 1;

  Future<void> _addProduct() async {
    final p = await pickProduct(context, _stock);
    if (p == null || !mounted) return;
    _update(() => _lines.add(_Line(product: p, matchedBy: 'manual', qty: _defaultQty(p))));
  }

  Future<void> _changeProduct(_Line l) async {
    final p = await pickProduct(context, _stock, title: 'Choose the medicine to give');
    if (p == null || !mounted) return;
    _update(() {
      l.product = p;
      l.matchedBy = 'manual';
      l.manualBatches = false;
      l.include = true;
    });
  }

  void _substitute(_Line l, Rec p) => _update(() {
        l.product = p;
        l.matchedBy = 'substitute';
        l.manualBatches = false;
        l.include = true;
      });

  Future<void> _choosePatient() async {
    final p = await pickPatient(context);
    if (p != null && mounted) setState(() => _patient = p);
  }

  Future<void> _editBatches(_Line l) async {
    final p = l.product;
    if (p == null) return;
    final db = context.app.readDb;
    final batches = await PharmacyService.stockBatches(db, p.id);
    if (!mounted) return;
    final current = {for (final pk in l.picks) pk.batch.id: pk.qty};
    final chosen = await showFormSheet<Map<String, int>>(
      context,
      title: 'Batches of ${p.str('name')}',
      builder: (c) => _BatchPicker(batches: batches, initial: current, unit: p.str('unit'), wanted: l.qty),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      l.manualBatches = true;
      l.picks = [
        for (final b in batches)
          if ((chosen[b.id] ?? 0) > 0) BatchPick(b, chosen[b.id]!)
      ];
      l.qty = l.picked;
      l.shortBy = 0;
      l.include = l.picked > 0;
      _recompute();
    });
  }

  List<String> get _allergyHits => _patient == null
      ? const []
      : PharmacyService.allergyConflicts(_patient!.str('allergies'), [
          for (final l in _lines.where((l) => l.active))
            (l.product!.str('name'), '${l.product!.str('generic_name')} ${l.item?['drug_name'] ?? ''}'),
        ]);

  Future<void> _dispense() async {
    final app = context.app;
    final active = _lines.where((l) => l.active).toList();
    if (_patient == null) {
      app.nav.toast('Choose the patient first', error: true);
      return;
    }
    if (active.isEmpty) {
      app.nav.toast('Nothing selected to dispense', error: true);
      return;
    }
    final hits = _allergyHits;
    if (hits.isNotEmpty) {
      final ok = await confirmDialog(context,
          title: 'Allergy warning',
          message: '${hits.join('\n')}\n\nDispense only if the doctor has confirmed.',
          confirmLabel: 'Dispense anyway',
          destructive: true);
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    Rec? saved;
    final ok = await runGuarded(context, () async {
      final rx = _rx == null ? null : await app.readDb.get(Col.prescriptions, _rx!.id);
      saved = await PharmacyService.dispense(
        app.db,
        patientId: _patient!.id,
        prescription: rx,
        byName: app.auth.session?.displayName ?? 'Pharmacist',
        lines: [for (final l in active) DispenseLine(product: l.product!, picks: l.picks, rxIndex: l.rxIndex)],
      );
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok || saved == null) return;
    app.nav.toast('Dispensed ${saved!.str('number')} · ${formatMoney(saved!.integer('total_paise'))} added to the bill');
    Navigator.of(context).pop();
    app.nav.open('pharmacy.dispense_summary', {'id': saved!.id});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    if (_isRx && _rx == null) {
      return const PageScaffold(
          title: 'Prescription', body: EmptyState(icon: Icons.search_off, title: 'Prescription not found'));
    }
    final active = _lines.where((l) => l.active).toList();
    final total = active.fold<int>(0, (a, l) => a + l.amount);
    final done = _rx != null && (_rx!.str('status') == Vals.dispensed || _lines.every((l) => l.alreadyDone));
    final title = _isRx ? 'Dispense prescription' : 'Counter sale';
    final subtitle = _isRx
        ? '${_doctor?.str('display_name') ?? 'Doctor'} · ${formatDateTime(_rx!.createdAt)}'
        : 'Sell medicines to a patient without a prescription';

    final patientCard = _PatientCard(
      patient: _patient,
      doctor: _doctor,
      allergyHits: _allergyHits,
      onChoose: _isRx ? null : _choosePatient,
      notes: _rx?.str('notes') ?? '',
    );
    final totals = _TotalsCard(
      lines: active.length,
      units: active.fold(0, (a, l) => a + l.picked),
      total: total,
      saving: _saving,
      onDispense: done || active.isEmpty ? null : _dispense,
      note: done ? 'Everything on this prescription has been dispensed.' : null,
    );
    final lines = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_lines.isEmpty)
          Card(
            child: EmptyState(
              icon: Icons.medication_outlined,
              title: 'No medicines yet',
              message: 'Add the medicines the patient is buying.',
              action: FilledButton.icon(onPressed: _addProduct, icon: const Icon(Icons.add), label: const Text('Add medicine')),
            ),
          ),
        for (final l in _lines) ...[
          _LineCard(
            line: l,
            isRx: _isRx,
            stock: _stock,
            medicine: _medicines[l.product?.str('medicine_id')],
            alternatives: l.product == null ? const [] : _index.alternatives(l.product!),
            onInclude: (v) => _update(() => l.include = v),
            onQty: (v) => _update(() {
              l.qty = v;
              l.manualBatches = false;
            }),
            onChange: () => _changeProduct(l),
            onBatches: () => _editBatches(l),
            onSubstitute: (p) => _substitute(l, p),
            onRemove: _isRx && l.rxIndex != null ? null : () => _update(() => _lines.remove(l)),
          ),
          Gap.v12,
        ],
        if (_lines.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
                onPressed: _addProduct,
                icon: const Icon(Icons.add),
                label: Text(_isRx ? 'Add another medicine' : 'Add medicine')),
          ),
      ],
    );

    return PageScaffold(
      title: title,
      subtitle: subtitle,
      primaryAction: PageAction(
          active.isEmpty ? 'Dispense' : 'Dispense ${formatMoney(total)}',
          Icons.check,
          _saving || done || active.isEmpty ? null : _dispense),
      body: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 960) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: TourAnchor(id: 'pharmacy.fefo_lines', child: lines)),
              Gap.h16,
              SizedBox(width: 340, child: Column(children: [patientCard, Gap.v12, totals])),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [patientCard, Gap.v12, lines, Gap.v16, totals],
        );
      }),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.patient, required this.doctor, required this.allergyHits, required this.onChoose, required this.notes});
  final Rec? patient;
  final Rec? doctor;
  final List<String> allergyHits;
  final VoidCallback? onChoose;
  final String notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = patient;
    if (p == null) {
      return SectionCard(
        title: 'Patient',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Muted('The charge goes to the patient\'s bill, so choose who is buying.'),
            Gap.v12,
            FilledButton.icon(onPressed: onChoose, icon: const Icon(Icons.person_search_outlined), label: const Text('Choose patient')),
          ],
        ),
      );
    }
    final allergies = p.str('allergies');
    return SectionCard(
      title: 'Patient',
      trailing: onChoose == null ? null : TextButton(onPressed: onChoose, child: const Text('Change')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Avatar(p.str('full_name'), size: 40),
            Gap.h12,
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.str('full_name'), style: theme.textTheme.titleMedium),
                Muted([
                  p.str('uhid'),
                  ageLabel(p.date('dob'), p.intOrNull('age_years')),
                  genderLabel(p.strOrNull('gender')),
                ].where((s) => s.isNotEmpty && s != '—').join(' · ')),
              ]),
            ),
          ]),
          if (doctor != null) ...[
            Gap.v12,
            Row(children: [
              Icon(Icons.medical_services_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
              Gap.h8,
              Expanded(child: Text([doctor!.str('display_name'), doctor!.str('department')].where((s) => s.isNotEmpty).join(' · '))),
            ]),
          ],
          Gap.v12,
          if (allergies.isEmpty)
            const Align(alignment: Alignment.centerLeft, child: StatusChip('No known allergies', tone: Tone.success))
          else
            NoticeBox(
              tone: Tone.danger,
              icon: Icons.warning_amber_rounded,
              title: 'Allergies: $allergies',
              lines: allergyHits.isEmpty ? const ['None of these medicines matches the recorded allergy.'] : allergyHits,
            ),
          if (notes.isNotEmpty) ...[
            Gap.v12,
            NoticeBox(tone: Tone.info, icon: Icons.sticky_note_2_outlined, title: 'Doctor\'s note', lines: [notes]),
          ],
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.lines, required this.units, required this.total, required this.saving, required this.onDispense, this.note});
  final int lines;
  final int units;
  final int total;
  final bool saving;
  final VoidCallback? onDispense;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'To dispense',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Muted('${plural(lines, 'medicine')} · ${plural(units, 'unit')}')),
            MoneyText(total, style: theme.textTheme.headlineSmall),
          ]),
          Gap.v4,
          const Muted('Charged at MRP to the patient\'s bill. Billing collects the payment.'),
          if (note != null) ...[Gap.v12, NoticeBox(tone: Tone.success, icon: Icons.task_alt, title: note!)],
          if (!context.isCompact) ...[
            Gap.v16,
            FilledButton.icon(
              onPressed: saving ? null : onDispense,
              icon: const Icon(Icons.check),
              label: Text(saving ? 'Saving…' : 'Dispense'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.isRx,
    required this.stock,
    required this.medicine,
    required this.alternatives,
    required this.onInclude,
    required this.onQty,
    required this.onChange,
    required this.onBatches,
    required this.onSubstitute,
    required this.onRemove,
  });
  final _Line line;
  final bool isRx;
  final Map<String, StockInfo> stock;
  final Rec? medicine;
  final List<Rec> alternatives;
  final ValueChanged<bool> onInclude;
  final ValueChanged<int> onQty;
  final VoidCallback onChange;
  final VoidCallback onBatches;
  final ValueChanged<Rec> onSubstitute;
  final VoidCallback? onRemove;

  String _sig(Map<String, Object?> i) => [
        i['dose'],
        i['frequency'],
        if (i['duration_days'] != null) '${i['duration_days']} days',
        i['route'],
      ].where((x) => x != null && '$x'.isNotEmpty).join(' · ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = line;
    final p = l.product;
    final item = l.item;
    final info = p == null ? null : stock[p.id];
    final unit = p?.str('unit') ?? '';
    final inStockAlts = [for (final a in alternatives) if ((stock[a.id]?.onHand ?? 0) > 0) a]
      ..sort((a, b) => (stock[b.id]?.onHand ?? 0).compareTo(stock[a.id]?.onHand ?? 0));
    final schedule = medicine?.str('schedule') ?? '';
    final faded = !l.include || l.alreadyDone;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!l.alreadyDone)
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: Checkbox(
                value: l.include && p != null && l.picked > 0,
                onChanged: p == null || (l.picked == 0 && !l.include) ? null : (v) => onInclude(v ?? false)),
          )
        else
          const Padding(padding: EdgeInsets.fromLTRB(8, 8, 16, 0), child: Icon(Icons.task_alt, size: 22)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item != null ? '${item['drug_name'] ?? p?.str('name') ?? 'Medicine'}' : (p?.str('name') ?? 'Medicine'),
                    style: theme.textTheme.titleMedium),
                if (item != null && _sig(item).isNotEmpty) ...[Gap.v4, Muted(_sig(item))],
                if (item != null && '${item['instructions'] ?? ''}'.isNotEmpty) ...[
                  Gap.v4,
                  Text('${item['instructions']}',
                      style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                ],
                if (item == null && p != null) ...[Gap.v4, Muted([p.str('generic_name'), medicine?.str('strength') ?? ''].where((s) => s.isNotEmpty && s != '—').join(' · '))],
              ],
            ),
          ),
        ),
        Gap.h8,
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: l.alreadyDone
              ? const StatusChip('Given', tone: Tone.success)
              : MoneyText(l.active ? l.amount : 0, style: theme.textTheme.titleMedium),
        ),
        if (onRemove != null)
          IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.close)),
      ],
    );

    if (l.alreadyDone) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.lg, Gap.md),
          child: Opacity(opacity: 0.7, child: header),
        ),
      );
    }

    final productRow = p == null
        ? NoticeBox(
            tone: Tone.warning,
            icon: Icons.help_outline,
            title: 'Not on the pharmacy list',
            lines: const ['Find the product to give, or leave this one out.'],
            action: OutlinedButton(onPressed: onChange, child: const Text('Find')),
          )
        : Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.medication_outlined, size: 18, color: theme.colorScheme.primary),
              Text(p.str('name'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (p.str('rack').isNotEmpty) StatusChip('Rack ${p.str('rack')}', icon: Icons.shelves),
              if (isRx)
                switch (l.matchedBy) {
                  'medicine' || 'name' => const StatusChip('Matched', tone: Tone.success, icon: Icons.check),
                  'generic' => const StatusChip('Same generic: check strength', tone: Tone.warning),
                  'substitute' => StatusChip('Substitute for ${l.originalProduct?.str('name') ?? 'prescribed'}', tone: Tone.warning),
                  _ => const StatusChip('Chosen by hand'),
                },
              if (schedule == 'H1' || schedule == 'X') StatusChip('Schedule $schedule: enter in register', tone: Tone.warning),
              if (!isRx && schedule == 'H') const StatusChip('Schedule H: sell against a prescription', tone: Tone.warning),
              TextButton(onPressed: onChange, child: const Text('Change')),
            ],
          );

    final qtyRow = p == null
        ? null
        : Wrap(
            spacing: Gap.lg,
            runSpacing: Gap.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QtyStepper(value: l.qty, onChanged: onQty, unit: qtyLabel(l.qty, unit).replaceFirst(RegExp(r'^\d+ '), '')),
              if (item != null)
                Muted('Prescribed ${PharmacyService.prescribedQty(item, unit: unit)}'
                    '${((item['dispensed_qty'] as num?)?.toInt() ?? 0) > 0 ? ', ${item['dispensed_qty']} given before' : ''}'),
              Muted('${qtyLabel(info?.onHand ?? 0, unit)} in stock · MRP ${formatMoney(p.integer('mrp_paise'))}'),
            ],
          );

    final picks = p == null || l.picks.isEmpty
        ? null
        : Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.inventory_2_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
              for (final pk in l.picks) _PickChip(pick: pk, unit: unit),
              TextButton.icon(
                onPressed: onBatches,
                icon: const Icon(Icons.tune, size: 18),
                label: Text(l.manualBatches ? 'Batches (set by you)' : 'Change batch'),
              ),
            ],
          );

    final warnings = <Widget>[];
    if (p != null && info != null) {
      final days = (item?['duration_days'] as num?)?.toInt();
      final usable = l.picks.where((pk) {
        final e = pk.batch.date('expiry_date');
        return days != null && e != null && e.isBefore(startOfDay(DateTime.now()).add(Duration(days: days)));
      });
      if (l.picked == 0 && l.qty > 0) {
        warnings.add(NoticeBox(
          tone: Tone.danger,
          icon: Icons.remove_shopping_cart_outlined,
          title: info.expired ? 'Only expired stock left' : 'Out of stock',
          lines: [
            if (inStockAlts.isEmpty) 'No other brand of ${p.str('generic_name', 'this medicine')} in stock. Raise a purchase order.'
            else 'Same generic in stock: give a substitute below if the doctor agrees.',
          ],
        ));
      } else if (l.shortBy > 0 && !l.manualBatches) {
        warnings.add(NoticeBox(
          tone: Tone.warning,
          icon: Icons.inventory_outlined,
          title: 'Only ${l.picked} in stock, ${l.shortBy} short',
          lines: const ['Give what is here; the rest stays on the prescription for later.'],
        ));
      }
      if (usable.isNotEmpty) {
        warnings.add(NoticeBox(
          tone: Tone.warning,
          icon: Icons.schedule,
          title: 'Batch ${usable.first.batch.str('batch_no')} expires before the $days-day course ends',
          lines: const ['Check the patient will finish it in time, or choose a later batch.'],
        ));
      }
      if ((l.picked == 0 || l.shortBy > 0) && inStockAlts.isNotEmpty) {
        warnings.add(Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Muted('Substitute:'),
            for (final a in inStockAlts.take(3))
              ActionChip(
                avatar: const Icon(Icons.swap_horiz, size: 18),
                label: Text('${a.str('name')} (${stock[a.id]?.onHand ?? 0})'),
                onPressed: () => onSubstitute(a),
              ),
          ],
        ));
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.lg, Gap.lg),
        child: Opacity(
          opacity: faded ? 0.6 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Gap.v8,
                    productRow,
                    if (qtyRow != null) ...[Gap.v8, qtyRow],
                    if (picks != null) ...[Gap.v8, picks],
                    for (final w in warnings) ...[Gap.v8, w],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickChip extends StatelessWidget {
  const _PickChip({required this.pick, required this.unit});
  final BatchPick pick;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final e = pick.batch.date('expiry_date');
    final near = PharmacyService.isNearExpiry(e, DateTime.now());
    return StatusChip(
      '${pick.batch.str('batch_no')} · exp ${PharmacyService.expiryLabel(e)} · ${pick.qty}',
      tone: near ? Tone.warning : Tone.info,
      icon: near ? Icons.schedule : Icons.qr_code_2,
    );
  }
}

/// Choose quantities per batch by hand. Expired batches are shown but
/// cannot be picked.
class _BatchPicker extends StatefulWidget {
  const _BatchPicker({required this.batches, required this.initial, required this.unit, required this.wanted});
  final List<Rec> batches;
  final Map<String, int> initial;
  final String unit;
  final int wanted;

  @override
  State<_BatchPicker> createState() => _BatchPickerState();
}

class _BatchPickerState extends State<_BatchPicker> {
  late final Map<String, int> _qty = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final total = _qty.values.fold<int>(0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Muted('Kendra picks the batch that expires first. Change it only if the shelf says otherwise. '
            'Wanted: ${widget.wanted}, chosen: $total.'),
        Gap.v12,
        if (widget.batches.isEmpty) const Muted('No batch of this medicine is in stock.'),
        for (final b in widget.batches) ...[
          Builder(builder: (context) {
            final expired = PharmacyService.isExpired(b.date('expiry_date'), now);
            final have = b.integer('qty_on_hand');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Wrap(
                spacing: Gap.md,
                runSpacing: Gap.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  SizedBox(
                    width: 220,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Batch ${b.str('batch_no')}', style: theme.textTheme.titleSmall),
                      Gap.v4,
                      Row(children: [ExpiryChip(b.date('expiry_date')), Gap.h8, Flexible(child: Muted('$have on hand'))]),
                    ]),
                  ),
                  if (expired)
                    const Muted('Expired: cannot be dispensed')
                  else
                    QtyStepper(
                      value: _qty[b.id] ?? 0,
                      max: math.max(0, have),
                      onChanged: (v) => setState(() => _qty[b.id] = v),
                    ),
                ],
              ),
            );
          }),
          const Divider(height: 1),
        ],
        Gap.v16,
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            Gap.h8,
            FilledButton(onPressed: () => Navigator.pop(context, _qty), child: Text('Use $total')),
          ],
        ),
      ],
    );
  }
}

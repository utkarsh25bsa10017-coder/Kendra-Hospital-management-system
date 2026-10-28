import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../catalog_data.dart';
import '../pharmacy_schema.dart';
import 'pharmacy_widgets.dart';

const _forms = ['tablet', 'capsule', 'syrup', 'injection', 'ointment', 'drops', 'inhaler', 'other'];
const _schedules = ['OTC', 'H', 'H1', 'X'];

class _CatalogRow {
  _CatalogRow(this.medicine, this.product);
  final Rec medicine;
  final Rec? product;
}

class _CatalogData {
  _CatalogData(this.rows, this.suppliers);
  final List<_CatalogRow> rows;
  final Map<String, Rec> suppliers;
}

/// The shared medicine list (doctors prescribe from it) with the
/// pharmacy's prices and reorder rules, and the suppliers.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this)..addListener(() => setState(() {}));
  String _search = '';

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<_CatalogData> _load(ReadDb db) async {
    final meds = await db.query(const Query(Col.medicines).matching(_search).sort('name').take(1000));
    final products = await db.query(Query(PCol.products).isIn('medicine_id', meds.map((m) => m.id)).take(2000));
    final byMed = {for (final p in products) p.str('medicine_id'): p};
    final suppliers = {for (final s in await db.query(const Query(PCol.suppliers).sort('name').take(500))) s.id: s};
    return _CatalogData([for (final m in meds) _CatalogRow(m, byMed[m.id])], suppliers);
  }

  @override
  Widget build(BuildContext context) {
    final onSuppliers = _tabs.index == 1;
    return PageScaffold(
      title: 'Medicines',
      subtitle: 'The medicine list doctors prescribe from, with prices, reorder levels and suppliers',
      scrollable: false,
      primaryAction: onSuppliers
          ? PageAction('Add supplier', Icons.add_business_outlined, () => editSupplierSheet(context))
          : PageAction('Add medicine', Icons.add, () => editProductSheet(context)),
      headerBottom: TabBar(
        controller: _tabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: const [Tab(text: 'Medicines'), Tab(text: 'Suppliers')],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          SingleChildScrollView(
            padding: EdgeInsets.only(top: Gap.lg, bottom: context.isCompact ? 96 : Gap.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SearchField(hint: 'Brand or generic name', onChanged: (v) => setState(() => _search = v)),
                Gap.v12,
                LiveBuilder<_CatalogData>(
                  watch: const {Col.medicines, PCol.products, PCol.suppliers},
                  deps: [_search],
                  load: _load,
                  builder: (context, d) => DataList<_CatalogRow>(
                    items: d.rows,
                    empty: EmptyState(
                      icon: Icons.vaccines_outlined,
                      title: _search.isEmpty ? 'No medicines yet' : 'No medicine matches "$_search"',
                    ),
                    onTap: (r) => editProductSheet(context, medicine: r.medicine, product: r.product),
                    title: (r) => r.medicine.str('name'),
                    subtitle: (r) => [
                      r.medicine.str('generic_name'),
                      if (r.product != null) 'MRP ${formatMoney(r.product!.integer('mrp_paise'))}' else 'Not stocked',
                      if (r.product != null) 'reorder at ${r.product!.integer('reorder_level')}',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    trailing: (r) => _scheduleChip(r.medicine),
                    columns: [
                      ListColumn('Medicine', (r) => TwoLine(r.medicine.str('name'), r.medicine.str('generic_name')), flex: 5),
                      ListColumn('Form', (r) => TwoLine(titleCase(r.medicine.str('form')), _strength(r.medicine)), flex: 3),
                      ListColumn('Schedule', (r) => _scheduleChip(r.medicine), width: 96),
                      ListColumn('MRP', (r) => r.product == null ? const Muted('Not stocked') : TwoLine(formatMoney(r.product!.integer('mrp_paise')), 'per ${r.product!.str('unit')}'),
                          numeric: true, flex: 2),
                      ListColumn('Reorder', (r) => Text(r.product == null ? '—' : '${r.product!.integer('reorder_level')} → ${r.product!.integer('reorder_qty')}'),
                          numeric: true, flex: 2),
                      ListColumn('Rack', (r) => Text(r.product?.str('rack', '—') ?? '—'), width: 64),
                      ListColumn('Supplier', (r) => Text(d.suppliers[r.product?.str('preferred_supplier_id')]?.str('name') ?? '—', overflow: TextOverflow.ellipsis),
                          flex: 3),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.only(top: Gap.lg, bottom: context.isCompact ? 96 : Gap.xl),
            child: LiveBuilder<(List<Rec>, Map<String, int>)>(
              watch: const {PCol.suppliers, PCol.products},
              load: (db) async {
                final suppliers = await db.query(const Query(PCol.suppliers).sort('name').take(500).withArchived());
                final products = await db.query(const Query(PCol.products).eq('active', true).take(5000));
                final counts = <String, int>{};
                for (final p in products) {
                  final s = p.str('preferred_supplier_id');
                  counts[s] = (counts[s] ?? 0) + 1;
                }
                return (suppliers, counts);
              },
              builder: (context, d) => DataList<Rec>(
                items: d.$1,
                empty: const EmptyState(icon: Icons.local_shipping_outlined, title: 'No suppliers yet', message: 'Add the distributors you buy from.'),
                onTap: (s) => editSupplierSheet(context, supplier: s),
                title: (s) => s.str('name'),
                subtitle: (s) => [s.str('phone'), '${d.$2[s.id] ?? 0} medicines', 'delivers in ${s.integer('lead_days', 3)} days']
                    .where((x) => x.isNotEmpty)
                    .join(' · '),
                trailing: (s) => s.flag('active') ? const SizedBox.shrink() : const StatusChip('Inactive'),
                columns: [
                  ListColumn('Supplier', (s) => TwoLine(s.str('name'), s.str('address')), flex: 4),
                  ListColumn('Phone', (s) => Text(s.str('phone', '—')), flex: 2),
                  ListColumn('GSTIN', (s) => Text(s.str('gstin', '—'), overflow: TextOverflow.ellipsis), flex: 3),
                  ListColumn('Medicines', (s) => Text('${d.$2[s.id] ?? 0}'), numeric: true, flex: 2),
                  ListColumn('Delivers in', (s) => Text(plural(s.integer('lead_days', 3), 'day')), numeric: true, flex: 2),
                  ListColumn('Status', (s) => s.flag('active') ? const StatusChip('Active', tone: Tone.success) : const StatusChip('Inactive'),
                      width: 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _strength(Rec m) => m.str('strength') == '—' ? '' : m.str('strength');

  static Widget _scheduleChip(Rec m) => switch (m.str('schedule')) {
        'H1' => const StatusChip('H1', tone: Tone.warning),
        'X' => const StatusChip('X', tone: Tone.danger),
        'H' => const StatusChip('H', tone: Tone.info),
        '' => const SizedBox.shrink(),
        final s => StatusChip(s),
      };
}

/// Add or edit a medicine and its pharmacy settings in one place.
Future<void> editProductSheet(BuildContext context, {Rec? medicine, Rec? product}) =>
    showFormSheet<void>(context,
        title: medicine == null ? 'Add medicine' : 'Edit ${medicine.str('name')}',
        width: 760,
        builder: (c) => _ProductForm(medicine: medicine, product: product));

class _ProductForm extends StatefulWidget {
  const _ProductForm({this.medicine, this.product});
  final Rec? medicine;
  final Rec? product;

  @override
  State<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<_ProductForm> {
  final _form = GlobalKey<FormState>();
  late final Rec? m = widget.medicine;
  late final Rec? p = widget.product;
  late final _name = TextEditingController(text: m?.str('name'));
  late final _generic = TextEditingController(text: m?.str('generic_name'));
  late final _strength = TextEditingController(text: m?.str('strength'));
  late final _unit = TextEditingController(text: m?.str('unit', p?.str('unit') ?? 'tablet') ?? 'tablet');
  late final _dose = TextEditingController(text: m?.str('default_dose'));
  late final _freq = TextEditingController(text: m?.str('default_frequency'));
  late final _sku = TextEditingController(text: p?.str('sku'));
  late final _mrp = TextEditingController(text: moneyInput(p?.intOrNull('mrp_paise')));
  late final _cost = TextEditingController(text: moneyInput(p?.intOrNull('purchase_price_paise')));
  late final _gst = TextEditingController(text: p == null ? '12' : p!.real('gst_percent').toStringAsFixed(p!.real('gst_percent') % 1 == 0 ? 0 : 1));
  late final _level = TextEditingController(text: '${p?.integer('reorder_level') ?? 0}');
  late final _qty = TextEditingController(text: '${p?.integer('reorder_qty') ?? 0}');
  late final _rack = TextEditingController(text: p?.str('rack'));
  late String _dosageForm = m?.str('form', 'tablet') ?? 'tablet';
  late String _schedule = m?.str('schedule', 'H') ?? 'H';
  late String? _supplier = p?.strOrNull('preferred_supplier_id');
  late bool _active = m?.flag('active') ?? true;
  List<Rec> _suppliers = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (!_forms.contains(_dosageForm)) _dosageForm = 'other';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_suppliers.isEmpty) {
      context.app.readDb.query(const Query(PCol.suppliers).eq('active', true).sort('name').take(500)).then((s) {
        if (mounted) setState(() => _suppliers = s);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _generic, _strength, _unit, _dose, _freq, _sku, _mrp, _cost, _gst, _level, _qty, _rack]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.app;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await runGuarded(context, () async {
      final db = app.db;
      final medId = m?.id ?? db.newId();
      final med = {
        'name': _name.text.trim(),
        'generic_name': _generic.text.trim(),
        'form': _dosageForm,
        'strength': _strength.text.trim(),
        'unit': _unit.text.trim().toLowerCase(),
        'schedule': _schedule,
        'default_dose': _dose.text.trim(),
        'default_frequency': _freq.text.trim(),
        'active': _active,
      };
      var sku = _sku.text.trim().toUpperCase();
      if (sku.isEmpty) {
        final taken = {for (final x in await db.query(const Query(PCol.products).take(5000).withArchived())) x.str('sku')};
        sku = skuFor(_name.text, taken);
      }
      final prod = {
        'medicine_id': medId,
        'name': _name.text.trim(),
        'generic_name': _generic.text.trim(),
        'sku': sku,
        'unit': _unit.text.trim().toLowerCase(),
        'mrp_paise': parseMoney(_mrp.text) ?? 0,
        'purchase_price_paise': parseMoney(_cost.text) ?? 0,
        'gst_percent': double.tryParse(_gst.text.trim()) ?? 12.0,
        'reorder_level': int.tryParse(_level.text.trim()) ?? 0,
        'reorder_qty': int.tryParse(_qty.text.trim()) ?? 0,
        'rack': _rack.text.trim().toUpperCase(),
        'preferred_supplier_id': _supplier,
        'active': _active,
      };
      await db.batch([
        if (m == null) InsertOp(Col.medicines, med, id: medId) else UpdateOp(Col.medicines, m!.id, med, expectedVersion: m!.version),
        if (p == null) InsertOp(PCol.products, prod) else UpdateOp(PCol.products, p!.id, prod, expectedVersion: p!.version),
      ]);
    }, success: m == null ? 'Added ${_name.text.trim()}' : 'Saved');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SubHeading('Medicine (shared with doctors)'),
          FormGrid(minFieldWidth: 200, children: [
            AppTextField(label: 'Brand or common name', controller: _name, validator: Validators.required('Name'), hint: 'e.g. Dolo 650'),
            AppTextField(label: 'Generic name', controller: _generic, hint: 'e.g. Paracetamol'),
            AppTextField(label: 'Strength', controller: _strength, hint: 'e.g. 650 mg'),
            AppDropdown<String>(label: 'Form', value: _dosageForm, items: [for (final f in _forms) (f, titleCase(f))], onChanged: (v) => setState(() => _dosageForm = v ?? 'tablet')),
            AppTextField(label: 'Dispensing unit', controller: _unit, hint: 'tablet, bottle, tube, vial…', validator: Validators.required('Unit')),
            AppDropdown<String>(label: 'Schedule', value: _schedule, items: [for (final s in _schedules) (s, s == 'OTC' ? 'OTC (no prescription)' : 'Schedule $s')], onChanged: (v) => setState(() => _schedule = v ?? 'H')),
            AppTextField(label: 'Default dose', controller: _dose, hint: '1 tablet'),
            AppTextField(label: 'Default frequency', controller: _freq, hint: '1-0-1'),
          ]),
          Gap.v16,
          const SubHeading('Pharmacy'),
          FormGrid(minFieldWidth: 200, children: [
            MoneyField(label: 'MRP per unit', controller: _mrp, required: true),
            MoneyField(label: 'Purchase price per unit', controller: _cost),
            AppTextField(label: 'GST %', controller: _gst, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            AppTextField(label: 'Reorder level', controller: _level, keyboardType: TextInputType.number, inputFormatters: digits, helper: 'Suggest an order at or below this'),
            AppTextField(label: 'Reorder quantity', controller: _qty, keyboardType: TextInputType.number, inputFormatters: digits),
            AppTextField(label: 'Rack', controller: _rack, hint: 'A3'),
            AppDropdown<String>(
              label: 'Preferred supplier',
              value: _supplier,
              items: [for (final s in _suppliers) (s.id, s.str('name'))],
              onChanged: (v) => setState(() => _supplier = v),
            ),
            AppTextField(label: 'SKU', controller: _sku, hint: 'Made from the name if empty'),
          ]),
          Gap.v12,
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
            subtitle: const Text('Inactive medicines are hidden from prescribing and dispensing'),
          ),
          Gap.v16,
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            Gap.h8,
            FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.check), label: const Text('Save')),
          ]),
        ],
      ),
    );
  }
}

Future<void> editSupplierSheet(BuildContext context, {Rec? supplier}) => showFormSheet<void>(context,
    title: supplier == null ? 'Add supplier' : 'Edit ${supplier.str('name')}', builder: (c) => _SupplierForm(supplier: supplier));

class _SupplierForm extends StatefulWidget {
  const _SupplierForm({this.supplier});
  final Rec? supplier;

  @override
  State<_SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<_SupplierForm> {
  final _form = GlobalKey<FormState>();
  late final s = widget.supplier;
  late final _name = TextEditingController(text: s?.str('name'));
  late final _phone = TextEditingController(text: s?.str('phone'));
  late final _gstin = TextEditingController(text: s?.str('gstin'));
  late final _address = TextEditingController(text: s?.str('address'));
  late final _lead = TextEditingController(text: '${s?.integer('lead_days', 3) ?? 3}');
  late bool _active = s?.flag('active') ?? true;

  @override
  void dispose() {
    for (final c in [_name, _phone, _gstin, _address, _lead]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.app;
    final nav = Navigator.of(context);
    final data = {
      'name': _name.text.trim(),
      'phone': _phone.text.trim(),
      'gstin': _gstin.text.trim().toUpperCase(),
      'address': _address.text.trim(),
      'lead_days': int.tryParse(_lead.text.trim()) ?? 3,
      'active': _active,
    };
    final ok = await runGuarded(context, () async {
      if (s == null) {
        await app.db.insert(PCol.suppliers, data);
      } else {
        await app.db.update(PCol.suppliers, s!.id, data, expectedVersion: s!.version);
      }
    }, success: s == null ? 'Added ${data['name']}' : 'Saved');
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGrid(minFieldWidth: 240, maxColumns: 2, children: [
            AppTextField(label: 'Name', controller: _name, validator: Validators.required('Name')),
            AppTextField(label: 'Phone', controller: _phone, keyboardType: TextInputType.phone),
            AppTextField(label: 'GSTIN', controller: _gstin),
            AppTextField(
                label: 'Delivers in (days)',
                controller: _lead,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
            FullWidth(child: AppTextField(label: 'Address', controller: _address, maxLines: 2)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
          ),
          Gap.v16,
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            Gap.h8,
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('Save')),
          ]),
        ],
      ),
    );
  }
}

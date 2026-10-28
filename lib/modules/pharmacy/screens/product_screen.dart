import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'catalog_screen.dart';
import 'pharmacy_widgets.dart';

class _ProductData {
  _ProductData(this.product, this.medicine, this.supplier, this.info, this.batches, this.movements, this.refs, this.pending, this.suppliers);
  final Rec product;
  final Rec? medicine;
  final Rec? supplier;
  final StockInfo info;
  final List<Rec> batches;
  final List<Rec> movements;
  final Map<String, Rec> refs; // dispenses and receipts by id
  final List<Rec> pending; // approvals waiting
  final Map<String, Rec> suppliers;
}

/// One medicine: its batches, every movement, and the controlled ways to
/// change stock (adjustment with a reason, expiry write-off).
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.productId});
  final String productId;

  Future<_ProductData?> _load(ReadDb db) async {
    final p = await db.get(PCol.products, productId);
    if (p == null) return null;
    final batches = await db.query(Query(PCol.batches).eq('product_id', p.id).sort('expiry_date').take(200));
    final movements = await db.query(Query(PCol.movements).eq('product_id', p.id).sort('moved_at', desc: true).take(100));
    final refIds = movements.map((m) => m.strOrNull('ref_id'));
    final refs = {
      ...await db.byIds(PCol.dispenses, refIds),
      ...await db.byIds(PCol.receipts, refIds),
    };
    final pending = await db.query(Query(Col.approvals)
        .isIn('type', ['pharmacy.adjustment', 'pharmacy.writeoff'])
        .eq('status', 'pending')
        .take(50));
    final ids = batches.map((b) => b.id).toSet();
    final mine = pending.where((a) {
      final pl = a.map('payload');
      return ids.contains(pl['batch_id']) || (pl['batch_ids'] as List? ?? const []).any(ids.contains);
    }).toList();
    final suppliers = await db.byIds(PCol.suppliers, [p.strOrNull('preferred_supplier_id'), ...batches.map((b) => b.strOrNull('supplier_id'))]);
    return _ProductData(
      p,
      await db.get(Col.medicines, p.strOrNull('medicine_id')),
      suppliers[p.str('preferred_supplier_id')],
      PharmacyService.summarize([p], batches)[p.id]!,
      batches,
      movements,
      refs,
      mine,
      suppliers,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_ProductData?>(
      watch: const {PCol.products, PCol.batches, PCol.movements, Col.approvals},
      deps: [productId],
      load: _load,
      builder: (context, d) {
        if (d == null) {
          return const PageScaffold(title: 'Medicine', body: EmptyState(icon: Icons.search_off, title: 'Medicine not found'));
        }
        return _ProductPage(d: d);
      },
    );
  }
}

class _ProductPage extends StatelessWidget {
  const _ProductPage({required this.d});
  final _ProductData d;

  @override
  Widget build(BuildContext context) {
    final p = d.product;
    final m = d.medicine;
    final info = d.info;
    final canAdjust = context.can(PharmacyPerms.adjust);
    final unit = p.str('unit');
    final now = DateTime.now();
    final expiredBatches = d.batches.where((b) => b.integer('qty_on_hand') > 0 && PharmacyService.isExpired(b.date('expiry_date'), now)).toList();

    return PageScaffold(
      title: p.str('name'),
      subtitle: [p.str('generic_name'), m?.str('strength') ?? '', 'SKU ${p.str('sku')}']
          .where((s) => s.isNotEmpty && s != '—')
          .join(' · '),
      actions: [
        if (context.can(PharmacyPerms.catalog))
          IconButton(
            tooltip: 'Edit price and reorder settings',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => editProductSheet(context, product: p, medicine: m),
          ),
      ],
      primaryAction: canAdjust && d.batches.isNotEmpty
          ? PageAction('Adjust stock', Icons.tune, () => _adjust(context))
          : null,
      headerBottom: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        StockChips(info),
        if (p.str('rack').isNotEmpty) StatusChip('Rack ${p.str('rack')}', icon: Icons.shelves),
        if ((m?.str('schedule') ?? '').isNotEmpty) StatusChip('Schedule ${m!.str('schedule')}'),
        if (d.supplier != null) StatusChip(d.supplier!.str('name'), icon: Icons.local_shipping_outlined),
      ]),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveGrid(minWidth: 200, children: [
            KpiTile(label: 'On hand', value: qtyLabel(info.onHand, unit), caption: 'Reorder at ${info.reorderLevel}', icon: Icons.inventory_2_outlined,
                tone: info.out ? Tone.danger : (info.low ? Tone.warning : Tone.neutral)),
            KpiTile(label: 'Stock value', value: formatMoney(info.valuePaise), caption: 'At cost', icon: Icons.currency_rupee),
            KpiTile(
                label: 'Nearest expiry',
                value: PharmacyService.expiryLabel(info.nearestExpiry),
                caption: info.nearExpiry ? '${info.nearExpiryQty} expire within 60 days' : 'Nothing close to expiry',
                icon: Icons.schedule,
                tone: info.nearExpiry ? Tone.warning : Tone.neutral),
            KpiTile(label: 'MRP', value: formatMoney(p.integer('mrp_paise')), caption: 'Per $unit · cost ${formatMoney(p.integer('purchase_price_paise'))}', icon: Icons.sell_outlined),
          ]),
          if (expiredBatches.isNotEmpty) ...[
            Gap.v16,
            NoticeBox(
              tone: Tone.danger,
              icon: Icons.event_busy,
              title: '${plural(expiredBatches.length, 'expired batch', 'expired batches')} still counted as stock',
              lines: [
                '${qtyLabel(info.expiredQty, unit)} worth ${formatMoney(info.expiredValuePaise)} at cost. '
                    'They are never picked for dispensing; take them off the shelf and write them off.'
              ],
              action: canAdjust ? FilledButton.tonal(onPressed: () => _writeOff(context, expiredBatches), child: const Text('Write off')) : null,
            ),
          ],
          for (final a in d.pending) ...[
            Gap.v12,
            NoticeBox(
              tone: Tone.board,
              icon: Icons.hourglass_top,
              title: 'Waiting for approval: ${a.str('title')}',
              lines: ['${a.str('requested_by_name')} · ${formatMoney(a.integer('amount_paise'))} · ${a.str('reason')}'],
            ),
          ],
          Gap.v16,
          SectionCard(
            title: 'Batches',
            subtitle: 'Dispensing takes the earliest expiry first',
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
            child: d.batches.isEmpty
                ? const Muted('No stock received yet.')
                : DataList<Rec>(
                    items: d.batches,
                    title: (b) => 'Batch ${b.str('batch_no')}',
                    subtitle: (b) =>
                        '${b.integer('qty_on_hand')} of ${b.integer('qty_received')} left · exp ${PharmacyService.expiryLabel(b.date('expiry_date'))} · cost ${formatMoney(b.integer('cost_paise'))}',
                    trailing: (b) => b.integer('qty_on_hand') == 0 ? const StatusChip('Used up') : ExpiryChip(b.date('expiry_date'), prefix: ''),
                    columns: [
                      ListColumn('Batch', (b) => TwoLine(b.str('batch_no'), d.suppliers[b.str('supplier_id')]?.str('name')), flex: 3),
                      ListColumn('Expiry', (b) => ExpiryChip(b.date('expiry_date'), prefix: ''), flex: 3),
                      ListColumn('On hand', (b) => TwoLine('${b.integer('qty_on_hand')}', 'of ${b.integer('qty_received')} received'), flex: 2),
                      ListColumn('Cost', (b) => MoneyText(b.integer('cost_paise')), numeric: true, flex: 2),
                      ListColumn('MRP', (b) => MoneyText(b.integer('mrp_paise')), numeric: true, flex: 2),
                      ListColumn('Value', (b) => MoneyText(b.integer('qty_on_hand') * b.integer('cost_paise')), numeric: true, flex: 2),
                    ],
                  ),
          ),
          Gap.v16,
          SectionCard(
            title: 'Movements',
            subtitle: 'Every change in stock, newest first',
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
            child: d.movements.isEmpty
                ? const Muted('No movements yet.')
                : DataList<Rec>(
                    items: d.movements,
                    onTap: (mv) {
                      final ref = d.refs[mv.str('ref_id')];
                      if (ref?.collection == PCol.dispenses) context.app.nav.open('pharmacy.dispense_summary', {'id': ref!.id});
                    },
                    title: (mv) => '${MoveType.label(mv.str('type'))} ${_signed(mv.integer('qty'))}',
                    subtitle: (mv) => [
                      formatDateTime(mv.date('moved_at') ?? mv.createdAt),
                      _batchNo(mv),
                      _ref(mv),
                      mv.str('reason'),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    columns: [
                      ListColumn('When', (mv) => TwoLine(formatDate(mv.date('moved_at') ?? mv.createdAt), formatTime(mv.date('moved_at') ?? mv.createdAt)), flex: 2),
                      ListColumn('Type', (mv) => MoveTypeChip(mv.str('type')), flex: 2),
                      ListColumn('Qty', (mv) => Text(_signed(mv.integer('qty')), style: TextStyle(fontWeight: FontWeight.w600, color: _qtyColor(context, mv.integer('qty')))),
                          numeric: true, flex: 1),
                      ListColumn('Batch', (mv) => Text(_batchNo(mv)), flex: 2),
                      ListColumn('Reference', (mv) => TwoLine(_ref(mv).isEmpty ? '—' : _ref(mv), mv.str('reason')), flex: 4),
                      ListColumn('By', (mv) => Text(mv.str('by_name'), overflow: TextOverflow.ellipsis), flex: 2),
                    ],
                  ),
          ),
          Gap.v16,
          SectionCard(
            title: 'Settings',
            child: InfoGrid([
              ('Form', titleCase(m?.str('form') ?? '')),
              ('Dispensing unit', unit),
              ('GST', '${p.real('gst_percent').toStringAsFixed(p.real('gst_percent') % 1 == 0 ? 0 : 1)}%'),
              ('Reorder level', '${p.integer('reorder_level')}'),
              ('Reorder quantity', '${p.integer('reorder_qty')}'),
              ('Preferred supplier', d.supplier?.str('name') ?? ''),
              ('Default dose', m?.str('default_dose') ?? ''),
              ('Default frequency', m?.str('default_frequency') ?? ''),
            ], minItemWidth: 180),
          ),
        ],
      ),
    );
  }

  static String _signed(int q) => q > 0 ? '+$q' : (q < 0 ? '−${-q}' : '0');

  Color? _qtyColor(BuildContext context, int q) =>
      q > 0 ? ToneColors.of(context, Tone.success).foreground : (q < 0 ? ToneColors.of(context, Tone.danger).foreground : null);

  String _batchNo(Rec mv) {
    for (final b in d.batches) {
      if (b.id == mv.str('batch_id')) return b.str('batch_no');
    }
    return '';
  }

  String _ref(Rec mv) {
    final r = d.refs[mv.str('ref_id')];
    if (r != null) return r.str('number');
    if (mv.str('ref_collection') == Col.approvals) return 'Approved request';
    return '';
  }

  Future<void> _adjust(BuildContext context) async {
    final app = context.app;
    final result = await showFormSheet<(Rec, int, String)>(
      context,
      title: 'Adjust stock: ${d.product.str('name')}',
      builder: (c) => _AdjustForm(batches: d.batches.where((b) => !b.archived).toList(), unit: d.product.str('unit')),
    );
    if (result == null || !context.mounted) return;
    final (batch, delta, reason) = result;
    await runGuarded(context, () async {
      final (_, msg) = await PharmacyService.adjustOrRequest(app,
          batch: batch, qtyDelta: delta, reason: reason, productName: d.product.str('name'));
      app.nav.toast(msg);
    });
  }

  Future<void> _writeOff(BuildContext context, List<Rec> batches) async {
    final app = context.app;
    final value = batches.fold<int>(0, (a, b) => a + b.integer('qty_on_hand') * b.integer('cost_paise'));
    final needsApproval = value > PharmacyService.adjustApprovalPaise;
    final ok = await confirmDialog(
      context,
      title: 'Write off expired stock?',
      message: '${batches.map((b) => 'Batch ${b.str('batch_no')}: ${b.integer('qty_on_hand')} (exp ${PharmacyService.expiryLabel(b.date('expiry_date'))})').join('\n')}\n\n'
          'Value at cost ${formatMoney(value)}.${needsApproval ? ' This is above ${formatMoney(PharmacyService.adjustApprovalPaise)}, so the board approves it first.' : ''}',
      confirmLabel: needsApproval ? 'Ask for approval' : 'Write off',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await runGuarded(context, () async {
      final (_, msg) = await PharmacyService.writeOffOrRequest(app, batches, productName: d.product.str('name'));
      app.nav.toast(msg);
    });
  }
}

class _AdjustForm extends StatefulWidget {
  const _AdjustForm({required this.batches, required this.unit});
  final List<Rec> batches;
  final String unit;

  @override
  State<_AdjustForm> createState() => _AdjustFormState();
}

class _AdjustFormState extends State<_AdjustForm> {
  late Rec? _batch = widget.batches.where((b) => b.integer('qty_on_hand') > 0).firstOrNull ?? widget.batches.firstOrNull;
  bool _remove = true;
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  static const _presets = ['Physical count', 'Damaged / broken', 'Leaked or spoilt', 'Found during count', 'Free goods from supplier'];

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _batch;
    final n = int.tryParse(_qty.text.trim()) ?? 0;
    final delta = _remove ? -n : n;
    final value = b == null ? 0 : PharmacyService.adjustmentValue(b, delta);
    final tooMany = b != null && _remove && n > b.integer('qty_on_hand');
    final ok = b != null && n > 0 && !tooMany && _reason.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Muted('Stock never changes without a reason. The movement is kept for audit.'),
        Gap.v16,
        AppDropdown<Rec>(
          label: 'Batch',
          value: b,
          items: [
            for (final x in widget.batches)
              (x, '${x.str('batch_no')} · exp ${PharmacyService.expiryLabel(x.date('expiry_date'))} · ${x.integer('qty_on_hand')} on hand')
          ],
          onChanged: (v) => setState(() => _batch = v),
        ),
        Gap.v16,
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Remove'), icon: Icon(Icons.remove)),
            ButtonSegment(value: false, label: Text('Add'), icon: Icon(Icons.add)),
          ],
          selected: {_remove},
          onSelectionChanged: (s) => setState(() => _remove = s.first),
        ),
        Gap.v16,
        AppTextField(
          label: 'How many (${widget.unit})',
          controller: _qty,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
        ),
        Gap.v12,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final p in _presets) ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
        ]),
        Gap.v12,
        AppTextField(label: 'Reason', controller: _reason, maxLines: 2, onChanged: (_) => setState(() {})),
        Gap.v16,
        if (tooMany)
          NoticeBox(tone: Tone.danger, icon: Icons.error_outline, title: 'Only ${b.integer('qty_on_hand')} on hand in this batch')
        else if (value > PharmacyService.adjustApprovalPaise)
          NoticeBox(
            tone: Tone.board,
            icon: Icons.verified_user_outlined,
            title: 'Needs board approval',
            lines: ['${formatMoney(value)} at cost is above ${formatMoney(PharmacyService.adjustApprovalPaise)}. Stock changes once it is approved.'],
          )
        else if (n > 0)
          Muted('Value ${formatMoney(value)} at cost. Applied straight away.'),
        Gap.v16,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton(
            onPressed: ok ? () => Navigator.pop(context, (b, delta, _reason.text.trim())) : null,
            child: Text(value > PharmacyService.adjustApprovalPaise ? 'Ask for approval' : 'Save adjustment'),
          ),
        ]),
      ],
    );
  }
}

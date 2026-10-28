import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'orders_screen.dart';
import 'pharmacy_widgets.dart';

class _OrderData {
  _OrderData(this.order, this.supplier, this.receipts, this.suppliers, this.stock);
  final Rec order;
  final Rec? supplier;
  final List<Rec> receipts;
  final List<Rec> suppliers;
  final Map<String, StockInfo> stock;
}

/// One purchase order: check a draft, send it, receive it or cancel it.
class OrderScreen extends StatelessWidget {
  const OrderScreen({super.key, required this.orderId});
  final String orderId;

  Future<_OrderData?> _load(ReadDb db) async {
    final o = await db.get(PCol.orders, orderId);
    if (o == null) return null;
    final ids = o.maps('items').map((i) => i['product_id'] as String?);
    final products = (await db.byIds(PCol.products, ids)).values.toList();
    final batches = await db.query(Query(PCol.batches).isIn('product_id', ids).where('qty_on_hand', Op.neq, 0).take(2000));
    return _OrderData(
      o,
      await db.get(PCol.suppliers, o.strOrNull('supplier_id')),
      await db.query(Query(PCol.receipts).eq('order_id', o.id).sort('received_at').take(20)),
      await db.query(const Query(PCol.suppliers).eq('active', true).sort('name').take(500)),
      PharmacyService.summarize(products, batches),
    );
  }

  @override
  Widget build(BuildContext context) => LiveBuilder<_OrderData?>(
        watch: const {PCol.orders, PCol.receipts},
        deps: [orderId],
        load: _load,
        builder: (context, d) => d == null
            ? const PageScaffold(title: 'Purchase order', body: EmptyState(icon: Icons.search_off, title: 'Order not found'))
            : _OrderPage(key: ValueKey('${d.order.id}:${d.order.version}'), d: d),
      );
}

class _OrderPage extends StatefulWidget {
  const _OrderPage({super.key, required this.d});
  final _OrderData d;

  @override
  State<_OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends State<_OrderPage> {
  late final _items = [for (final i in widget.d.order.maps('items')) {...i}];
  late String? _supplier = widget.d.order.strOrNull('supplier_id');
  bool _dirty = false;

  Rec get o => widget.d.order;
  bool get _draft => o.str('status') == PoStatus.draft;

  Future<void> _saveDraft() async {
    final app = context.app;
    await runGuarded(context, () async {
      if (_items.isEmpty) throw ValidationException('Keep at least one medicine, or cancel the order');
      await app.db.update(
          PCol.orders, o.id, {'items': _items, 'total_paise': PharmacyService.orderTotal(_items), 'supplier_id': _supplier},
          expectedVersion: o.version);
    }, success: 'Saved');
  }

  Future<void> _send() async {
    final app = context.app;
    if (_supplier == null) {
      app.nav.toast('Choose the supplier first', error: true);
      return;
    }
    await runGuarded(context, () async {
      var cur = o;
      if (_dirty) {
        cur = await app.db.update(
            PCol.orders, o.id, {'items': _items, 'total_paise': PharmacyService.orderTotal(_items), 'supplier_id': _supplier},
            expectedVersion: o.version);
      }
      final s = widget.d.suppliers.where((x) => x.id == _supplier).firstOrNull ?? widget.d.supplier;
      await PharmacyService.markOrdered(app.db, cur, leadDays: s?.integer('lead_days', 3) ?? 3);
    }, success: 'Marked as ordered. Copy the order to send it to the supplier.');
  }

  Future<void> _cancel() async {
    final app = context.app;
    final reason = await reasonDialog(context,
        title: 'Cancel ${o.str('number')}?',
        presets: const ['Supplier cannot supply', 'Ordered elsewhere', 'Raised by mistake', 'No longer needed'],
        confirmLabel: 'Cancel order',
        destructive: true);
    if (reason == null || !mounted) return;
    await runGuarded(context, () => PharmacyService.cancelOrder(app.db, o, reason), success: 'Order cancelled');
  }

  Future<void> _add() async {
    final p = await pickProduct(context, widget.d.stock, title: 'Add to the order');
    if (p == null || !mounted || _items.any((i) => i['product_id'] == p.id)) return;
    setState(() {
      _dirty = true;
      _items.add({
        'product_id': p.id,
        'name': p.str('name'),
        'qty': PharmacyService.suggestedQty(p, 0),
        'cost_paise': p.integer('purchase_price_paise'),
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final d = widget.d;
    final status = o.str('status');
    final supplier = d.suppliers.where((x) => x.id == _supplier).firstOrNull ?? d.supplier;
    final total = PharmacyService.orderTotal(_items);
    final text = PharmacyService.orderText(o.copyWith({'items': _items, 'total_paise': total}), supplier, app.settings.hospitalName);

    PageAction? primary;
    if (status == PoStatus.draft) {
      primary = PageAction('Mark as ordered', Icons.send_outlined, _send);
    } else if (status == PoStatus.ordered) {
      primary = PageAction('Receive', Icons.move_to_inbox_outlined, () => app.nav.open('pharmacy.receive', {'orderId': o.id}));
    }

    return PageScaffold(
      title: 'Purchase order ${o.str('number')}',
      subtitle: '${supplier?.str('name') ?? 'No supplier yet'} · ${plural(_items.length, 'medicine')} · ${formatMoney(total)}',
      maxWidth: 980,
      primaryAction: primary,
      actions: [
        IconButton(tooltip: 'Copy order for WhatsApp or email', onPressed: () => copyText(context, text, 'Order'), icon: const Icon(Icons.copy_all_outlined)),
        if (status == PoStatus.draft || status == PoStatus.ordered)
          IconButton(tooltip: 'Cancel order', onPressed: _cancel, icon: const Icon(Icons.cancel_outlined)),
      ],
      headerBottom: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        PoStatusChip(status),
        if (o.flag('from_proposal')) const StatusChip('Suggested by the low stock agent', tone: Tone.agent, icon: Icons.auto_awesome_outlined),
      ]),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status == PoStatus.cancelled)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
              child: NoticeBox(tone: Tone.danger, icon: Icons.cancel_outlined, title: 'Cancelled', lines: [o.str('cancel_reason')]),
            ),
          SectionCard(
            title: 'Details',
            child: InfoGrid([
              ('Supplier', supplier?.str('name') ?? ''),
              ('Phone', supplier?.str('phone') ?? ''),
              ('GSTIN', supplier?.str('gstin') ?? ''),
              ('Raised', formatDateTime(o.date('raised_at'))),
              ('Ordered', o.date('ordered_at') == null ? 'Not sent yet' : formatDateTime(o.date('ordered_at'))),
              ('Expected', o.date('expected_at') == null ? '—' : formatDate(o.date('expected_at'))),
              if (status == PoStatus.received) ('Received', formatDateTime(o.date('received_at'))),
              ('Notes', o.str('notes')),
            ], minItemWidth: 180),
          ),
          Gap.v16,
          SectionCard(
            title: 'Medicines',
            subtitle: _draft ? 'Change quantities before you send it' : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_draft) ...[
                  AppDropdown<String>(
                    label: 'Supplier',
                    value: _supplier,
                    items: [for (final s in d.suppliers) (s.id, s.str('name'))],
                    onChanged: (v) => setState(() {
                      _supplier = v;
                      _dirty = true;
                    }),
                  ),
                  Gap.v12,
                  for (final (i, it) in _items.indexed)
                    OrderItemRow(
                      item: {...it, 'on_hand': d.stock[it['product_id']]?.onHand ?? 0},
                      onQty: (v) => setState(() {
                        _items[i]['qty'] = v;
                        _dirty = true;
                      }),
                      onRemove: () => setState(() {
                        _items.removeAt(i);
                        _dirty = true;
                      }),
                    ),
                  Gap.v8,
                  Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                    OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add medicine')),
                    if (_dirty) FilledButton.tonal(onPressed: _saveDraft, child: const Text('Save changes')),
                  ]),
                ] else
                  for (final (i, it) in _items.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm + 2),
                      child: Row(children: [
                        Expanded(
                          child: TwoLine('${it['name']}',
                              '${it['qty']} × ${formatMoney((it['cost_paise'] as num?)?.toInt())} · ${d.stock[it['product_id']]?.onHand ?? 0} in stock now'),
                        ),
                        MoneyText(((it['qty'] as num?)?.toInt() ?? 0) * ((it['cost_paise'] as num?)?.toInt() ?? 0)),
                      ]),
                    ),
                  ],
                const Divider(height: Gap.xl),
                Row(children: [
                  const Expanded(child: Text('Estimated value')),
                  MoneyText(total, style: Theme.of(context).textTheme.titleMedium),
                ]),
              ],
            ),
          ),
          if (d.receipts.isNotEmpty) ...[
            Gap.v16,
            SectionCard(
              title: 'Received',
              child: Column(children: [
                for (final r in d.receipts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Row(children: [
                      Expanded(
                        child: TwoLine('${r.str('number')} · ${formatDateTime(r.date('received_at'))}',
                            '${plural(r.maps('items').length, 'batch', 'batches')} · supplier invoice ${r.str('supplier_invoice_no', '—')} · by ${r.str('received_by_name')}'),
                      ),
                      MoneyText(r.integer('total_paise')),
                    ]),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'pharmacy_widgets.dart';

enum _Filter { open, received, cancelled, all }

class _OrdersData {
  _OrdersData(this.orders, this.suppliers, this.proposals, this.receipts);
  final List<Rec> orders;
  final Map<String, Rec> suppliers;
  final List<Rec> proposals;
  final List<Rec> receipts;
}

/// Purchase orders to suppliers, the low stock agent's suggestions, and
/// recent goods receipts.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  _Filter _filter = _Filter.open;

  Future<_OrdersData> _load(ReadDb db) async {
    var q = const Query(PCol.orders).sort('raised_at', desc: true).take(200);
    q = switch (_filter) {
      _Filter.open => q.isIn('status', [PoStatus.draft, PoStatus.ordered]),
      _Filter.received => q.eq('status', PoStatus.received),
      _Filter.cancelled => q.eq('status', PoStatus.cancelled),
      _Filter.all => q,
    };
    final orders = await db.query(q);
    final proposals = await db.query(
        const Query(Col.proposals).eq('handler', 'pharmacy.create_po').eq('status', 'pending').sort('created_at').take(20));
    final receipts = await db.query(const Query(PCol.receipts).sort('received_at', desc: true).take(8));
    final suppliers = await db.byIds(PCol.suppliers, [...orders.map((o) => o.strOrNull('supplier_id')), ...receipts.map((r) => r.strOrNull('supplier_id'))]);
    return _OrdersData(orders, suppliers, proposals, receipts);
  }

  Future<void> _approve(Rec p) async {
    final app = context.app;
    Rec? done;
    final ok = await runGuarded(context, () async => done = await app.tower.approveProposal(p, note: 'Approved from purchase orders'));
    if (!ok || done == null || !mounted) return;
    if (done!.str('status') == 'failed') {
      app.nav.toast(done!.str('result'), error: true);
      return;
    }
    app.nav.toast('${done!.str('result')}. Check the quantities, then send it.');
    final number = done!.str('result').replaceFirst('Created ', '');
    final po = await app.readDb.first(Query(PCol.orders).eq('number', number));
    if (po != null) app.nav.open('pharmacy.order', {'id': po.id});
  }

  Future<void> _reject(Rec p) async {
    final app = context.app;
    final note = await reasonDialog(context,
        title: 'Not now?', message: 'The agent will suggest it again only if the list of medicines changes.',
        presets: const ['Enough stock in the store room', 'Ordering from another supplier', 'Medicine being discontinued'],
        confirmLabel: 'Dismiss suggestion');
    if (note == null || !mounted) return;
    await runGuarded(context, () => app.tower.rejectProposal(p, note: note), success: 'Suggestion dismissed');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PageScaffold(
      title: 'Purchase orders',
      subtitle: 'Orders to suppliers and goods received',
      primaryAction: PageAction('New order', Icons.add, () => newOrderSheet(context)),
      actions: [
        if (!context.isCompact)
          OutlinedButton.icon(
              onPressed: () => app.nav.open('pharmacy.receive'),
              icon: const Icon(Icons.move_to_inbox_outlined),
              label: const Text('Receive without PO'))
        else
          IconButton(
              tooltip: 'Receive stock',
              onPressed: () => app.nav.open('pharmacy.receive'),
              icon: const Icon(Icons.move_to_inbox_outlined)),
      ],
      headerBottom: FilterChips<_Filter>(
        options: const [(_Filter.open, 'Open'), (_Filter.received, 'Received'), (_Filter.cancelled, 'Cancelled'), (_Filter.all, 'All')],
        value: _filter,
        onChanged: (f) => setState(() => _filter = f),
      ),
      body: LiveBuilder<_OrdersData>(
        watch: const {PCol.orders, PCol.receipts, Col.proposals},
        deps: [_filter],
        load: _load,
        builder: (context, d) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (d.proposals.isNotEmpty) ...[
              SectionCard(
                title: 'Suggested by the low stock agent',
                subtitle: 'One tap makes a draft order you can still change',
                child: Column(children: [
                  for (final (i, p) in d.proposals.indexed) ...[
                    if (i > 0) const Divider(height: Gap.xl),
                    _Suggestion(proposal: p, onApprove: () => _approve(p), onReject: () => _reject(p)),
                  ],
                ]),
              ),
              Gap.v16,
            ],
            DataList<Rec>(
              items: d.orders,
              empty: Card(
                child: EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: _filter == _Filter.open ? 'No open orders' : 'No orders here',
                  message: 'Start one with New order, or approve a suggestion from the low stock agent.',
                ),
              ),
              onTap: (o) => app.nav.open('pharmacy.order', {'id': o.id}),
              title: (o) => '${o.str('number')} · ${d.suppliers[o.str('supplier_id')]?.str('name') ?? 'No supplier'}',
              subtitle: (o) => [
                plural(o.maps('items').length, 'medicine'),
                formatMoney(o.integer('total_paise')),
                _when(o),
              ].join(' · '),
              trailing: (o) => PoStatusChip(o.str('status')),
              columns: [
                ListColumn('Order', (o) => TwoLine(o.str('number'), o.flag('from_proposal') ? 'Suggested by agent' : o.str('notes')), flex: 3),
                ListColumn('Supplier', (o) => Text(d.suppliers[o.str('supplier_id')]?.str('name') ?? 'Choose supplier', overflow: TextOverflow.ellipsis), flex: 3),
                ListColumn('Medicines', (o) => TwoLine(plural(o.maps('items').length, 'medicine'), o.maps('items').map((i) => i['name']).take(3).join(', ')), flex: 4),
                ListColumn('Value', (o) => MoneyText(o.integer('total_paise')), numeric: true, flex: 2),
                ListColumn('Dates', (o) => Text(_when(o), overflow: TextOverflow.ellipsis), flex: 3),
                ListColumn('Status', (o) => PoStatusChip(o.str('status')), width: 110),
              ],
            ),
            Gap.v24,
            SectionCard(
              title: 'Recent goods receipts',
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: d.receipts.isEmpty
                  ? const Muted('Nothing received yet.')
                  : Column(children: [
                      for (final (i, r) in d.receipts.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: Gap.sm + 2),
                          child: Row(children: [
                            Expanded(
                              child: TwoLine(
                                '${r.str('number')} · ${d.suppliers[r.str('supplier_id')]?.str('name') ?? ''}',
                                '${formatDate(r.date('received_at'))} · ${plural(r.maps('items').length, 'line')}'
                                    '${r.str('supplier_invoice_no').isEmpty ? '' : ' · invoice ${r.str('supplier_invoice_no')}'}',
                              ),
                            ),
                            MoneyText(r.integer('total_paise')),
                          ]),
                        ),
                      ],
                    ]),
            ),
          ],
        ),
      ),
    );
  }

  static String _when(Rec o) => switch (o.str('status')) {
        PoStatus.draft => 'Drafted ${formatDate(o.date('raised_at'))}',
        PoStatus.ordered => 'Ordered ${formatDateShort(o.date('ordered_at') ?? o.createdAt)} · due ${formatDateShort(o.date('expected_at') ?? o.createdAt)}',
        PoStatus.received => 'Received ${formatDate(o.date('received_at'))}',
        _ => 'Cancelled',
      };
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.proposal, required this.onApprove, required this.onReject});
  final Rec proposal;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      for (final i in (proposal.map('payload')['items'] as List? ?? const []))
        if (i is Map) i.cast<String, Object?>()
    ];
    final total = PharmacyService.orderTotal(items);
    final can = context.can(proposal.str('required_permission', CorePerms.approvalsDecide));
    final buttons = Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
      FilledButton.icon(onPressed: can ? onApprove : null, icon: const Icon(Icons.check), label: const Text('Create draft')),
      TextButton(onPressed: can ? onReject : null, child: const Text('Not now')),
    ]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: ToneColors.of(context, Tone.agent).background, borderRadius: BorderRadius.circular(Radii.sm)),
            child: Icon(Icons.auto_awesome_outlined, size: 18, color: ToneColors.of(context, Tone.agent).foreground),
          ),
          Gap.h12,
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(proposal.str('title'), style: theme.textTheme.titleSmall),
              Gap.v4,
              Muted('About ${formatMoney(total)} · ${formatRelative(proposal.createdAt)}'),
            ]),
          ),
          if (!context.isCompact) buttons,
        ]),
        Gap.v8,
        Padding(
          padding: EdgeInsets.only(left: context.isCompact ? 0 : 42),
          child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final i in items)
              StatusChip('${i['name']}: ${i['on_hand'] ?? 0} left → order ${i['qty']}',
                  tone: ((i['on_hand'] as num?)?.toInt() ?? 0) <= 0 ? Tone.danger : Tone.warning),
          ]),
        ),
        if (context.isCompact) ...[Gap.v12, buttons],
      ],
    );
  }
}

/// New purchase order: choose a supplier and Kendra fills in what is at or
/// below its reorder level from that supplier.
Future<void> newOrderSheet(BuildContext context) =>
    showFormSheet<void>(context, title: 'New purchase order', width: 720, builder: (c) => const _NewOrderForm());

class _NewOrderForm extends StatefulWidget {
  const _NewOrderForm();

  @override
  State<_NewOrderForm> createState() => _NewOrderFormState();
}

class _NewOrderFormState extends State<_NewOrderForm> {
  List<Rec> _suppliers = const [];
  Map<String, StockInfo> _stock = const {};
  String? _supplier;
  final _items = <Map<String, Object?>>[];
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_suppliers.isEmpty) _load();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final s = await db.query(const Query(PCol.suppliers).eq('active', true).sort('name').take(500));
    final st = await PharmacyService.stock(db);
    if (mounted) {
      setState(() {
        _suppliers = s;
        _stock = st;
      });
    }
  }

  void _chooseSupplier(String? id) {
    setState(() {
      _supplier = id;
      _items
        ..clear()
        ..addAll([
          for (final s in _stock.values)
            if (s.atOrBelowReorder && s.product.str('preferred_supplier_id') == id)
              {
                'product_id': s.product.id,
                'name': s.product.str('name'),
                'qty': PharmacyService.suggestedQty(s.product, s.onHand),
                'cost_paise': s.product.integer('purchase_price_paise'),
                'on_hand': s.onHand,
              }
        ]);
    });
  }

  Future<void> _add() async {
    final p = await pickProduct(context, _stock, title: 'Add to the order');
    if (p == null || !mounted) return;
    if (_items.any((i) => i['product_id'] == p.id)) return;
    setState(() => _items.add({
          'product_id': p.id,
          'name': p.str('name'),
          'qty': PharmacyService.suggestedQty(p, _stock[p.id]?.onHand ?? 0),
          'cost_paise': p.integer('purchase_price_paise'),
          'on_hand': _stock[p.id]?.onHand ?? 0,
        }));
  }

  Future<void> _save() async {
    final app = context.app;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    Rec? po;
    final ok = await runGuarded(context, () async {
      po = await PharmacyService.createOrder(app.db, supplierId: _supplier, items: _items);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok || po == null) return;
    app.nav.toast('Draft ${po!.str('number')} saved');
    nav.pop();
    app.nav.open('pharmacy.order', {'id': po!.id});
  }

  @override
  Widget build(BuildContext context) {
    final total = PharmacyService.orderTotal(_items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDropdown<String>(
          label: 'Supplier',
          value: _supplier,
          items: [for (final s in _suppliers) (s.id, s.str('name'))],
          onChanged: _chooseSupplier,
          helper: 'Medicines from this supplier at or below their reorder level are added for you',
        ),
        Gap.v16,
        if (_supplier != null && _items.isEmpty) const Muted('Nothing from this supplier is low. Add medicines below.'),
        for (final (i, it) in _items.indexed)
          OrderItemRow(
            item: it,
            onQty: (v) => setState(() => _items[i]['qty'] = v),
            onRemove: () => setState(() => _items.removeAt(i)),
          ),
        Gap.v8,
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add medicine')),
        ),
        Gap.v16,
        Row(children: [
          Expanded(child: Muted('${plural(_items.length, 'medicine')} · about ${formatMoney(total)}')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton.icon(
            onPressed: _saving || _items.isEmpty ? null : _save,
            icon: const Icon(Icons.check),
            label: const Text('Save draft'),
          ),
        ]),
      ],
    );
  }
}

/// One medicine on an order, with an editable quantity.
class OrderItemRow extends StatelessWidget {
  const OrderItemRow({super.key, required this.item, required this.onQty, required this.onRemove});
  final Map<String, Object?> item;
  final ValueChanged<int> onQty;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final qty = (item['qty'] as num?)?.toInt() ?? 0;
    final cost = (item['cost_paise'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Gap.md,
        runSpacing: Gap.xs,
        children: [
          SizedBox(
            width: 240,
            child: TwoLine('${item['name']}',
                '${item['on_hand'] == null ? '' : '${item['on_hand']} in stock · '}${formatMoney(cost)} each = ${formatMoney(cost * qty)}'),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            QtyStepper(value: qty, min: 1, onChanged: onQty),
            IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.delete_outline)),
          ]),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'pharmacy_widgets.dart';

class _RLine {
  _RLine(this.product, {int qty = 0, int? cost, int? mrp})
      : qty = TextEditingController(text: qty > 0 ? '$qty' : ''),
        cost = TextEditingController(text: moneyInput(cost ?? product.integer('purchase_price_paise'))),
        mrp = TextEditingController(text: moneyInput(mrp ?? product.integer('mrp_paise')));
  final Rec product;
  final batch = TextEditingController();
  final expiry = TextEditingController();
  final TextEditingController qty;
  final TextEditingController cost;
  final TextEditingController mrp;

  int get amount => (int.tryParse(qty.text.trim()) ?? 0) * (parseMoney(cost.text) ?? 0);

  void dispose() {
    for (final c in [batch, expiry, qty, cost, mrp]) {
      c.dispose();
    }
  }
}

/// Goods receipt (GRN): what arrived, batch by batch, from the supplier's
/// invoice. Saving creates the batches and receipt movements, and marks the
/// purchase order received.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, this.orderId});
  final String? orderId;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _form = GlobalKey<FormState>();
  final _invoice = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  Rec? _order;
  List<Rec> _suppliers = const [];
  Map<String, StockInfo> _stock = const {};
  String? _supplier;
  final _lines = <_RLine>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final order = await db.get(PCol.orders, widget.orderId);
    final suppliers = await db.query(const Query(PCol.suppliers).eq('active', true).sort('name').take(500));
    final stock = await PharmacyService.stock(db);
    if (order != null) {
      final products = await db.byIds(PCol.products, order.maps('items').map((i) => i['product_id'] as String?));
      for (final it in order.maps('items')) {
        final p = products[it['product_id']];
        if (p == null) continue;
        _lines.add(_RLine(p, qty: (it['qty'] as num?)?.toInt() ?? 0, cost: (it['cost_paise'] as num?)?.toInt()));
      }
    }
    if (!mounted) return;
    setState(() {
      _order = order;
      _suppliers = suppliers;
      _stock = stock;
      _supplier = order?.strOrNull('supplier_id');
      _loading = false;
    });
  }

  @override
  void dispose() {
    _invoice.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    final p = await pickProduct(context, _stock, title: 'Add a medicine received');
    if (p == null || !mounted) return;
    setState(() => _lines.add(_RLine(p)));
  }

  Future<void> _save() async {
    final app = context.app;
    if (_supplier == null) {
      app.nav.toast('Choose the supplier', error: true);
      return;
    }
    if (_lines.isEmpty) {
      app.nav.toast('Add the medicines that arrived', error: true);
      return;
    }
    if (!_form.currentState!.validate()) return;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    Rec? grn;
    final ok = await runGuarded(context, () async {
      grn = await PharmacyService.receive(
        app.db,
        supplierId: _supplier!,
        orderId: _order?.id,
        supplierInvoiceNo: _invoice.text,
        byName: app.auth.session?.displayName ?? 'Pharmacist',
        lines: [
          for (final l in _lines)
            ReceiptLine(
              productId: l.product.id,
              name: l.product.str('name'),
              batchNo: l.batch.text,
              expiry: PharmacyService.parseExpiry(l.expiry.text)!,
              qty: int.parse(l.qty.text.trim()),
              costPaise: parseMoney(l.cost.text) ?? 0,
              mrpPaise: parseMoney(l.mrp.text) ?? 0,
            )
        ],
      );
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok || grn == null) return;
    app.nav.toast('Saved ${grn!.str('number')} · ${plural(_lines.length, 'batch', 'batches')} now in stock');
    nav.pop();
  }

  String? _expiryCheck(String? v) {
    final d = PharmacyService.parseExpiry(v ?? '');
    if (d == null) return 'MM/YY, e.g. 08/27';
    if (PharmacyService.isExpired(d, DateTime.now())) return 'Already expired';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    final theme = Theme.of(context);
    final total = _lines.fold<int>(0, (a, l) => a + l.amount);
    final now = DateTime.now();
    return PageScaffold(
      title: 'Receive stock',
      subtitle: _order == null ? 'Goods receipt from the supplier\'s invoice' : 'Against ${_order!.str('number')}',
      maxWidth: 1100,
      primaryAction: PageAction('Save receipt', Icons.check, _saving ? null : _save),
      body: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Supplier',
              child: FormGrid(children: [
                AppDropdown<String>(
                  label: 'Supplier',
                  value: _supplier,
                  items: [for (final s in _suppliers) (s.id, s.str('name'))],
                  onChanged: (v) => setState(() => _supplier = v),
                  validator: (v) => v == null ? 'Choose the supplier' : null,
                ),
                AppTextField(label: 'Supplier invoice number', controller: _invoice, hint: 'As printed on the bill'),
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Received'),
                  child: Text(formatDateTime(now), style: theme.textTheme.bodyLarge),
                ),
              ]),
            ),
            Gap.v16,
            if (_lines.isEmpty)
              Card(
                child: EmptyState(
                  icon: Icons.move_to_inbox_outlined,
                  title: 'What arrived?',
                  message: 'Add each medicine from the supplier\'s invoice with its batch number and expiry.',
                  action: FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add medicine')),
                ),
              ),
            for (final (i, l) in _lines.indexed) ...[
              Card(
                key: ObjectKey(l),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                          child: TwoLine(
                            '${i + 1}. ${l.product.str('name')}',
                            '${l.product.str('generic_name')} · ${_stock[l.product.id]?.onHand ?? 0} ${l.product.str('unit')} in stock now',
                          ),
                        ),
                        Muted(formatMoney(l.amount)),
                        IconButton(
                          tooltip: 'Remove line',
                          onPressed: () {
                            final gone = _lines.removeAt(i);
                            setState(() {});
                            WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                      Gap.v8,
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.sm),
                        child: FormGrid(minFieldWidth: 150, maxColumns: 5, children: [
                          AppTextField(
                            label: 'Batch no.',
                            controller: l.batch,
                            validator: Validators.required('Batch'),
                            inputFormatters: [_UpperCase()],
                          ),
                          AppTextField(
                            label: 'Expiry (MM/YY)',
                            controller: l.expiry,
                            hint: '08/27',
                            keyboardType: TextInputType.datetime,
                            validator: _expiryCheck,
                          ),
                          AppTextField(
                            label: 'Quantity (${l.product.str('unit')})',
                            controller: l.qty,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) <= 0 ? 'Enter the quantity' : null,
                            onChanged: (_) => setState(() {}),
                          ),
                          MoneyField(label: 'Cost per unit', controller: l.cost, required: true, onChanged: (_) => setState(() {})),
                          MoneyField(label: 'MRP per unit', controller: l.mrp, required: true),
                        ]),
                      ),
                    ],
                  ),
                ),
              ),
              Gap.v12,
            ],
            if (_lines.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add medicine')),
              ),
            Gap.v16,
            SectionCard(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${plural(_lines.length, 'line')} · ${formatMoney(total)} at cost', style: theme.textTheme.titleMedium),
                    const Muted('Each line becomes a batch on the shelf with a receipt movement.'),
                  ]),
                ),
                if (!context.isCompact) ...[
                  Gap.h12,
                  FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.check), label: const Text('Save receipt')),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

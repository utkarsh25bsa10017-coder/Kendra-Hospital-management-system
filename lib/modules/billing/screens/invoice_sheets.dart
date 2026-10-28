import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'billing_widgets.dart';

const discountReasons = ['Senior citizen', 'Staff or family', "Doctor's advice", 'Financial hardship', 'Package rate', 'Rounding off'];
const refundReasons = ['Service not given', 'Charged by mistake', 'Medicines returned', 'Paid twice', 'Patient complaint'];
const cancelReasons = ['Wrong patient', 'Wrong items', 'Duplicate bill', 'Patient left before the service', 'Insurance to be billed instead'];

/// Rupee input that can take focus and submit with Enter.
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.label,
    required this.controller,
    this.autofocus = false,
    this.helper,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.focusNode,
  });
  final String label;
  final TextEditingController controller;
  final bool autofocus;
  final String? helper;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        validator: validator ?? Validators.requiredMoney,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        onTap: () => controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length),
        decoration: InputDecoration(labelText: label, prefixText: '₹ ', helperText: helper),
      );
}

/// Mode chips: Cash, UPI, Card...
class ModeChips extends StatelessWidget {
  const ModeChips({super.key, required this.value, required this.onChanged, this.modes = paymentModes});
  final String value;
  final ValueChanged<String> onChanged;
  final List<(String, String)> modes;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          for (final (m, label) in modes)
            ChoiceChip(
              avatar: Icon(modeIcon(m), size: 18),
              label: Text(label),
              selected: m == value,
              showCheckmark: false,
              onSelected: (_) => onChanged(m),
            ),
        ],
      );
}

// ------------------------------------------------------------------ add item

class ItemPick {
  const ItemPick(this.service, this.quantity, this.unitPricePaise);
  final Rec service;
  final int quantity;
  final int unitPricePaise;
}

Future<ItemPick?> showAddItemDialog(BuildContext context) =>
    showDialog<ItemPick>(context: context, builder: (c) => const _AddItemDialog());

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();
  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final _search = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _rate = TextEditingController();
  final _qtyFocus = FocusNode();
  List<Rec>? _items;
  Rec? _picked;
  Timer? _t;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  @override
  void dispose() {
    _t?.cancel();
    _search.dispose();
    _qty.dispose();
    _rate.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final g = ++_gen;
    final r = await context.app.readDb
        .query(const Query(Col.services).eq('active', true).matching(_search.text).sort('name').take(40));
    if (mounted && g == _gen) setState(() => _items = r);
  }

  void _pick(Rec s) {
    setState(() {
      _picked = s;
      _qty.text = '1';
      _rate.text = moneyInput(s.integer('price_paise'));
    });
    _qtyFocus.requestFocus();
    _qty.selection = TextSelection(baseOffset: 0, extentOffset: _qty.text.length);
  }

  int get _qtyValue => int.tryParse(_qty.text.trim()) ?? 0;
  int? get _rateValue => parseMoney(_rate.text);

  void _submit() {
    final s = _picked;
    final rate = _rateValue;
    if (s == null || _qtyValue <= 0 || rate == null || rate < 0) return;
    Navigator.pop(context, ItemPick(s, _qtyValue, rate));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    final picked = _picked;
    final rate = _rateValue;
    final list = picked?.integer('price_paise');
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 580, maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: Text('Add item from the price list', style: theme.textTheme.titleLarge)),
                IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ]),
              Gap.v12,
              TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(hintText: 'Service name or code', prefixIcon: Icon(Icons.search), isDense: true),
                onChanged: (_) {
                  _t?.cancel();
                  _t = Timer(const Duration(milliseconds: 200), _load);
                },
                onSubmitted: (_) {
                  final first = _items?.firstOrNull;
                  if (first != null) _pick(first);
                },
              ),
              Gap.v8,
              Flexible(
                child: items == null
                    ? const LoadingView()
                    : items.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(Gap.xl),
                            child: Text('Nothing in the price list matches. Ask accounts to add it.', textAlign: TextAlign.center))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: items.length,
                            itemBuilder: (c, i) {
                              final s = items[i];
                              return ListTile(
                                dense: true,
                                selected: s.id == picked?.id,
                                title: Text(s.str('name'), maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text('${s.str('code')} · ${categoryLabel(s.strOrNull('category'))}'),
                                trailing: MoneyText(s.integer('price_paise')),
                                onTap: () => _pick(s),
                              );
                            },
                          ),
              ),
              if (picked != null) ...[
                const Divider(height: Gap.xl),
                Text(picked.str('name'), style: theme.textTheme.titleSmall),
                Gap.v12,
                LayoutBuilder(builder: (context, box) {
                  final qty = SizedBox(
                    width: 156,
                    child: Row(children: [
                      IconButton(
                        tooltip: 'One less',
                        onPressed: _qtyValue > 1 ? () => setState(() => _qty.text = '${_qtyValue - 1}') : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _qty,
                          focusNode: _qtyFocus,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'One more',
                        onPressed: () => setState(() => _qty.text = '${_qtyValue + 1}'),
                        icon: const Icon(Icons.add),
                      ),
                    ]),
                  );
                  final rateField = AmountField(
                    label: 'Rate',
                    controller: _rate,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    helper: rate != null && list != null && rate != list ? 'List price ${formatMoney(list)}. The change is checked.' : null,
                  );
                  if (box.maxWidth < 420) {
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [qty, Gap.v12, rateField]);
                  }
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [qty, Gap.h16, Expanded(child: rateField)]);
                }),
                Gap.v16,
                Row(children: [
                  Expanded(
                    child: Text(rate == null ? '' : 'Amount ${formatMoney(rate * _qtyValue)}', style: theme.textTheme.titleMedium),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  Gap.h8,
                  FilledButton.icon(
                    onPressed: _qtyValue > 0 && rate != null ? _submit : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ discount

Future<int?> showDiscountSheet(BuildContext context, {required int grossPaise, int currentPaise = 0}) => showFormSheet<int>(
      context,
      title: 'Request a discount',
      width: 500,
      builder: (c) => _DiscountForm(grossPaise: grossPaise, currentPaise: currentPaise),
    );

class _DiscountForm extends StatefulWidget {
  const _DiscountForm({required this.grossPaise, required this.currentPaise});
  final int grossPaise;
  final int currentPaise;
  @override
  State<_DiscountForm> createState() => _DiscountFormState();
}

class _DiscountFormState extends State<_DiscountForm> {
  bool _percent = false;
  late final _amount = TextEditingController(text: widget.currentPaise > 0 ? moneyInput(widget.currentPaise) : '');
  final _pct = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _pct.dispose();
    super.dispose();
  }

  int? get _value {
    if (_percent) {
      final p = double.tryParse(_pct.text.trim());
      if (p == null || p <= 0 || p > 100) return null;
      return (widget.grossPaise * p / 100).round();
    }
    final v = parseMoney(_amount.text);
    return v == null || v <= 0 ? null : v;
  }

  void _submit() {
    final v = _value;
    if (v == null || v > widget.grossPaise) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _value;
    final limit = context.session?.discountLimitPaise ?? 0;
    final tooMuch = v != null && v > widget.grossPaise;
    final roundOff = widget.grossPaise % 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Bill total ${formatMoney(widget.grossPaise)}', style: theme.textTheme.bodyLarge),
        Gap.v16,
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Amount (₹)')),
            ButtonSegment(value: true, label: Text('Percent (%)')),
          ],
          selected: {_percent},
          onSelectionChanged: (s) => setState(() => _percent = s.first),
        ),
        Gap.v16,
        if (_percent)
          TextField(
            controller: _pct,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Discount', suffixText: '%'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          )
        else
          AmountField(
            label: 'Discount',
            controller: _amount,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        Gap.v12,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final p in [5, 10, 15, 20])
            ActionChip(
              label: Text('$p%'),
              onPressed: () => setState(() {
                _percent = true;
                _pct.text = '$p';
              }),
            ),
          if (roundOff > 0)
            ActionChip(
              label: Text('Round off ${formatMoney(roundOff)}'),
              onPressed: () => setState(() {
                _percent = false;
                _amount.text = moneyInput(roundOff);
              }),
            ),
        ]),
        Gap.v16,
        if (v != null)
          NoticeBanner(
            tone: tooMuch ? Tone.danger : (v <= limit ? Tone.success : Tone.warning),
            icon: tooMuch ? Icons.error_outline : (v <= limit ? Icons.check_circle_outline : Icons.how_to_reg_outlined),
            title: tooMuch
                ? 'More than the bill'
                : 'Patient pays ${formatMoney(widget.grossPaise - v)} (${formatMoney(v)} off)',
            message: tooMuch
                ? null
                : v <= limit
                    ? 'Within your limit of ${formatMoney(limit)}: applies straight away.'
                    : 'Above your limit of ${formatMoney(limit)}: the board approves it first.',
          ),
        Gap.v8,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton(onPressed: v == null || tooMuch ? null : _submit, child: const Text('Next: reason')),
        ]),
      ],
    );
  }
}

// ------------------------------------------------------------------ finalise

enum FinaliseChoice { only, andPay }

Future<FinaliseChoice?> showFinaliseDialog(BuildContext context, Rec invoice, {required bool canPay}) {
  final net = invoice.integer('net_paise');
  final pay = canPay && net > 0;
  return showDialog<FinaliseChoice>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Finalise bill for ${formatMoney(net)}?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text('${invoice.str('patient_name')}. The bill gets its number and cannot be changed after this. '
            'Any correction is made with a refund or a credit note.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Back')),
        if (pay) OutlinedButton(onPressed: () => Navigator.pop(c, FinaliseChoice.only), child: const Text('Finalise only')),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(c, pay ? FinaliseChoice.andPay : FinaliseChoice.only),
          child: Text(pay ? 'Finalise and take payment' : 'Finalise'),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------ payment

Future<List<PaymentEntry>?> showPaymentSheet(BuildContext context, Rec invoice) => showFormSheet<List<PaymentEntry>>(
      context,
      title: 'Take payment',
      width: 560,
      builder: (c) => _PaymentForm(invoice: invoice),
    );

class _Part {
  _Part(this.mode, int amount) : amount = TextEditingController(text: moneyInput(amount));
  String mode;
  final TextEditingController amount;
  final reference = TextEditingController();
  void dispose() {
    amount.dispose();
    reference.dispose();
  }
}

String referenceLabel(String mode) => switch (mode) {
      'upi' => 'UPI transaction ID',
      'card' => 'Card approval code',
      'cheque' => 'Cheque number and bank',
      'insurance' => 'Claim or authorisation no. (optional)',
      _ => 'Reference (optional)',
    };

class _PaymentForm extends StatefulWidget {
  const _PaymentForm({required this.invoice});
  final Rec invoice;
  @override
  State<_PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<_PaymentForm> {
  final _form = GlobalKey<FormState>();
  late final List<_Part> _parts = [_Part('cash', widget.invoice.integer('balance_paise'))];

  int get _due => widget.invoice.integer('balance_paise');
  int get _total => _parts.fold<int>(0, (a, p) => a + (parseMoney(p.amount.text) ?? 0));

  @override
  void dispose() {
    for (final p in _parts) {
      p.dispose();
    }
    super.dispose();
  }

  void _split() {
    final rest = _due - _total;
    if (rest <= 0) return;
    setState(() => _parts.add(_Part(_parts.last.mode == 'cash' ? 'upi' : 'cash', rest)));
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    if (_total <= 0 || _total > _due) return;
    Navigator.pop(context, [
      for (final p in _parts)
        if ((parseMoney(p.amount.text) ?? 0) > 0)
          PaymentEntry(p.mode, parseMoney(p.amount.text)!, reference: p.reference.text.trim()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _total;
    final rest = _due - total;
    final over = total > _due;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MutedText('${widget.invoice.str('number')} · ${widget.invoice.str('patient_name')}'),
                Gap.v4,
                Text('${formatMoney(_due)} due', style: theme.textTheme.headlineSmall),
              ]),
            ),
          ]),
          for (final (i, p) in _parts.indexed) ...[
            Gap.v16,
            if (_parts.length > 1)
              Row(children: [
                Expanded(child: SubHeading('Part ${i + 1}')),
                IconButton(
                  tooltip: 'Remove this part',
                  onPressed: () {
                    final gone = _parts[i];
                    setState(() => _parts.removeAt(i));
                    WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                  },
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
            ModeChips(value: p.mode, onChanged: (m) => setState(() => p.mode = m)),
            Gap.v12,
            FormGrid(minFieldWidth: 200, maxColumns: 2, children: [
              AmountField(
                label: 'Amount',
                controller: p.amount,
                autofocus: i == _parts.length - 1,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
              if (modesNeedingReference.contains(p.mode) || p.mode == 'insurance')
                AppTextField(
                  label: referenceLabel(p.mode),
                  controller: p.reference,
                  onSubmitted: (_) => _submit(),
                  validator: modesNeedingReference.contains(p.mode) ? Validators.required('The reference') : null,
                ),
            ]),
          ],
          Gap.v12,
          Row(children: [
            Expanded(
              child: Text(
                over
                    ? '${formatMoney(total - _due)} more than is due'
                    : rest > 0
                        ? '${formatMoney(rest)} will still be due'
                        : 'Pays the bill in full',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: over
                        ? theme.colorScheme.error
                        : rest > 0
                            ? ToneColors.of(context, Tone.warning).foreground
                            : ToneColors.of(context, Tone.success).foreground),
              ),
            ),
            if (rest > 0 && !over)
              TextButton.icon(onPressed: _split, icon: const Icon(Icons.call_split, size: 18), label: const Text('Split')),
          ]),
          Gap.v16,
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            Gap.h8,
            FilledButton.icon(
              onPressed: total <= 0 || over ? null : _submit,
              icon: const Icon(Icons.check),
              label: Text('Record ${formatMoney(total)}'),
            ),
          ]),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ refund

Future<(int, String)?> showRefundSheet(BuildContext context, {required int maxPaise, required String defaultMode}) =>
    showFormSheet<(int, String)>(
      context,
      title: 'Refund',
      width: 500,
      builder: (c) => _RefundForm(maxPaise: maxPaise, defaultMode: defaultMode),
    );

class _RefundForm extends StatefulWidget {
  const _RefundForm({required this.maxPaise, required this.defaultMode});
  final int maxPaise;
  final String defaultMode;
  @override
  State<_RefundForm> createState() => _RefundFormState();
}

class _RefundFormState extends State<_RefundForm> {
  late final _amount = TextEditingController(text: moneyInput(widget.maxPaise));
  late String _mode = widget.defaultMode == 'insurance' ? 'cash' : widget.defaultMode;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int? get _value => parseMoney(_amount.text);

  void _submit() {
    final v = _value;
    if (v == null || v <= 0 || v > widget.maxPaise) return;
    Navigator.pop(context, (v, _mode));
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final bad = v == null || v <= 0 || v > widget.maxPaise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MutedText('Up to ${formatMoney(widget.maxPaise)} can be refunded on this bill.'),
        Gap.v16,
        AmountField(
          label: 'Amount to refund',
          controller: _amount,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          validator: (s) => (parseMoney(s ?? '') ?? 0) > widget.maxPaise ? 'At most ${formatMoney(widget.maxPaise)}' : null,
        ),
        Gap.v16,
        const SubHeading('Refund by'),
        ModeChips(
          value: _mode,
          onChanged: (m) => setState(() => _mode = m),
          modes: paymentModes.where((m) => m.$1 != 'insurance').toList(),
        ),
        Gap.v24,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton(onPressed: bad ? null : _submit, child: const Text('Next: reason')),
        ]),
      ],
    );
  }
}

/// Asks for the payment and records it. Returns true when money was taken.
Future<bool> takePaymentFlow(BuildContext context, Rec bill) async {
  final entries = await showPaymentSheet(context, bill);
  if (entries == null || !context.mounted) return false;
  final app = context.app;
  List<Rec> made = const [];
  final ok = await runGuarded(context, () async {
    made = await BillingService.takePayment(app.db, bill.id, entries);
  });
  if (!ok) return false;
  final total = made.fold<int>(0, (a, p) => a + p.integer('amount_paise'));
  final left = bill.integer('balance_paise') - total;
  app.nav.toast(left > 0
      ? '${formatMoney(total)} received. ${formatMoney(left)} still due.'
      : '${formatMoney(total)} received · ${made.map((p) => p.str('number')).join(', ')}');
  return true;
}

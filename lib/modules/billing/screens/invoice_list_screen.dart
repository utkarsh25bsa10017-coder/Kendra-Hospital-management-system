import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import 'billing_widgets.dart';

enum _Status { all, drafts, unpaid, paid, cancelled, creditNotes }

enum _Range { today, week, month, all }

class _ListData {
  _ListData(this.bills, this.count, this.net, this.paid, this.balance);
  final List<Rec> bills;
  final int count;
  final int net;
  final int paid;
  final int balance;
}

/// Every bill, with filters and totals.
class InvoiceListScreen extends StatefulWidget {
  const InvoiceListScreen({super.key});

  @override
  State<InvoiceListScreen> createState() => _InvoiceListScreenState();
}

class _InvoiceListScreenState extends State<InvoiceListScreen> {
  String _search = '';
  _Status _status = _Status.all;
  _Range _range = _Range.week;
  String _payer = 'all';

  Query _query() {
    var q = const Query(BillCol.invoices);
    q = switch (_status) {
      _Status.all => q,
      _Status.drafts => q.eq('status', InvoiceStatus.draft),
      _Status.unpaid => q.eq('kind', InvoiceKind.invoice).eq('status', InvoiceStatus.finalised).gt('balance_paise', 0),
      _Status.paid => q.eq('kind', InvoiceKind.invoice).eq('status', InvoiceStatus.finalised).lte('balance_paise', 0),
      _Status.cancelled => q.eq('status', InvoiceStatus.cancelled),
      _Status.creditNotes => q.eq('kind', InvoiceKind.creditNote),
    };
    final now = DateTime.now();
    final from = switch (_range) {
      _Range.today => startOfDay(now),
      _Range.week => startOfDay(now).subtract(const Duration(days: 6)),
      _Range.month => startOfMonth(now),
      _Range.all => null,
    };
    if (from != null) q = q.gte('bill_date', from);
    if (_payer != 'all') q = q.eq('payer_type', _payer);
    return q;
  }

  Future<_ListData> _load(ReadDb db) async {
    final q = _query();
    final bills = await db.query(q.matching(_search).sort('bill_date', desc: true).take(200));
    // Drafts are not billed yet, so they only count when asked for.
    final counted = _status == _Status.drafts ? q : q.neq('status', InvoiceStatus.draft);
    if (_search.trim().isNotEmpty) {
      final rows = _status == _Status.drafts ? bills : bills.where((b) => b.str('status') != InvoiceStatus.draft).toList();
      int sum(String f) => rows.fold<int>(0, (a, b) => a + b.integer(f));
      return _ListData(bills, rows.length, sum('net_paise'), sum('paid_paise'), sum('balance_paise'));
    }
    final agg = await db.aggregate(AggQuery.of(counted, sums: ['net_paise', 'paid_paise', 'balance_paise']));
    final row = agg.isEmpty ? null : agg.first;
    return _ListData(bills, row?.count ?? 0, (row?.sum('net_paise') ?? 0).toInt(), (row?.sum('paid_paise') ?? 0).toInt(),
        (row?.sum('balance_paise') ?? 0).toInt());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canBill = context.can(BillingPerms.invoice);
    return PageScaffold(
      title: 'Bills',
      subtitle: 'Every bill and credit note. Final bills are never edited.',
      primaryAction: canBill
          ? PageAction('New bill', Icons.add, () async {
              final p = await pickPatient(context, title: 'Bill which patient?');
              if (p != null && context.mounted) await openBillForPatient(context, p.id);
            })
          : null,
      headerBottom: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SearchField(hint: 'Bill number, patient name or UHID', onChanged: (v) => setState(() => _search = v)),
        Gap.v12,
        FilterChips<_Status>(
          options: const [
            (_Status.all, 'All'),
            (_Status.unpaid, 'Money due'),
            (_Status.paid, 'Paid'),
            (_Status.drafts, 'Drafts'),
            (_Status.cancelled, 'Cancelled'),
            (_Status.creditNotes, 'Credit notes'),
          ],
          value: _status,
          onChanged: (v) => setState(() => _status = v),
        ),
        Gap.v8,
        Wrap(spacing: Gap.lg, runSpacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterChips<_Range>(
            options: const [(_Range.today, 'Today'), (_Range.week, 'Last 7 days'), (_Range.month, 'This month'), (_Range.all, 'All time')],
            value: _range,
            onChanged: (v) => setState(() => _range = v),
          ),
          FilterChips<String>(
            options: const [('all', 'All payers'), ('self', 'Self pay'), ('insurance', 'Insurance'), ('corporate', 'Corporate')],
            value: _payer,
            onChanged: (v) => setState(() => _payer = v),
          ),
        ]),
      ]),
      body: LiveBuilder<_ListData>(
        watch: const {BillCol.invoices},
        deps: [_search, _status, _range, _payer],
        load: _load,
        builder: (context, d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _TotalsBar(data: d),
          Gap.v12,
          DataList<Rec>(
            items: d.bills,
            empty: Card(
              child: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: _search.isEmpty ? 'No bills match these filters' : 'No bill matches "$_search"',
                message: 'Try a longer date range or another filter.',
              ),
            ),
            onTap: (b) => app.nav.open('billing.invoice', {'id': b.id}),
            title: (b) => '${b.str('patient_name')} · ${b.str('number')}',
            subtitle: (b) => '${formatDate(b.date('bill_date'))} · ${payerLabel(b.strOrNull('payer_type'))} · '
                'net ${formatMoney(b.integer('net_paise'))}'
                '${b.integer('balance_paise') > 0 ? ' · ${formatMoney(b.integer('balance_paise'))} due' : ''}',
            trailing: (b) => InvoiceStatusChip(b),
            columns: [
              ListColumn('Bill', (b) => TwoLine(b.str('number'), formatDateTime(b.date('bill_date'))), flex: 3),
              ListColumn('Patient', (b) => TwoLine(b.str('patient_name'), b.str('patient_uhid')), flex: 4),
              ListColumn('Payer', (b) => Text(payerLabel(b.strOrNull('payer_type'))), flex: 2),
              ListColumn('Status', (b) => InvoiceStatusChip(b), width: 140),
              ListColumn('Net', (b) => MoneyText(b.integer('net_paise')), width: 116, numeric: true),
              ListColumn('Received', (b) => MoneyText(b.integer('paid_paise')), width: 116, numeric: true),
              ListColumn('Balance', (b) {
                final v = b.integer('balance_paise');
                return MoneyText(v,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: v > 0 ? FontWeight.w700 : null),
                    color: v > 0 ? ToneColors.of(context, Tone.warning).foreground : null);
              }, width: 116, numeric: true),
            ],
          ),
          if (d.bills.length < d.count)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: MutedText('Showing the latest ${d.bills.length} of ${d.count}. Narrow the filters to see others.'),
            ),
        ]),
      ),
    );
  }
}

class _TotalsBar extends StatelessWidget {
  const _TotalsBar({required this.data});
  final _ListData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Text(value,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: color, fontWeight: FontWeight.w600)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs, horizontal: Gap.xs),
        child: Wrap(spacing: Gap.md, runSpacing: 0, children: [
          cell('Bills', formatNumber(data.count)),
          cell('Net billed', formatMoney(data.net)),
          cell('Received', formatMoney(data.paid)),
          cell('Balance due', formatMoney(data.balance),
              color: data.balance > 0 ? ToneColors.of(context, Tone.warning).foreground : null),
        ]),
      ),
    );
  }
}

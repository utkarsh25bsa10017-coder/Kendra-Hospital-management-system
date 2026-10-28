import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'billing_widgets.dart';
import 'invoice_sheets.dart';

enum _Day { today, yesterday, week }

class _Staff {
  _Staff(this.name);
  final String name;
  int count = 0;
  int refunds = 0;
  final byMode = <String, int>{};
  int get net => byMode.values.fold<int>(0, (a, b) => a + b);
}

class _CollData {
  _CollData({
    required this.payments,
    required this.outstanding,
    required this.outstandingCount,
    required this.outstandingTotal,
    required this.closings,
  });
  final List<Rec> payments;
  final List<Rec> outstanding;
  final int outstandingCount;
  final int outstandingTotal;
  final List<Rec> closings;

  List<Rec> get received => payments.where((p) => p.str('kind') != PaymentKind.refund).toList();
  List<Rec> get refunds => payments.where((p) => p.str('kind') == PaymentKind.refund).toList();
  int get receivedTotal => received.fold<int>(0, (a, p) => a + p.integer('amount_paise'));
  int get refundTotal => refunds.fold<int>(0, (a, p) => a + p.integer('amount_paise'));

  Map<String, int> get byMode {
    final out = <String, int>{};
    for (final p in payments) {
      final sign = p.str('kind') == PaymentKind.refund ? -1 : 1;
      out[p.str('mode')] = (out[p.str('mode')] ?? 0) + sign * p.integer('amount_paise');
    }
    return out;
  }

  Map<String, _Staff> get byStaff {
    final out = <String, _Staff>{};
    for (final p in payments) {
      final s = out.putIfAbsent(p.str('received_by'), () => _Staff(p.str('received_by_name', 'Unknown')));
      final refund = p.str('kind') == PaymentKind.refund;
      if (refund) {
        s.refunds += p.integer('amount_paise');
      } else {
        s.count++;
      }
      s.byMode[p.str('mode')] = (s.byMode[p.str('mode')] ?? 0) + (refund ? -1 : 1) * p.integer('amount_paise');
    }
    return out;
  }
}

/// Money in and out by mode and by counter, and the end-of-day cash count.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key});

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  _Day _day = _Day.today;

  (DateTime, DateTime) get _range {
    final today = startOfDay(DateTime.now());
    return switch (_day) {
      _Day.today => (today, endOfDay(today)),
      _Day.yesterday => (today.subtract(const Duration(days: 1)), today),
      _Day.week => (today.subtract(const Duration(days: 6)), endOfDay(today)),
    };
  }

  Future<_CollData> _load(ReadDb db) async {
    final (from, to) = _range;
    final dueQ = const Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .eq('status', InvoiceStatus.finalised)
        .gt('balance_paise', 0);
    final agg = await db.aggregate(AggQuery.of(dueQ, sums: ['balance_paise']));
    return _CollData(
      payments: await db.query(Query(BillCol.payments).between('received_at', from, to).sort('received_at', desc: true).take(5000)),
      outstanding: await db.query(dueQ.sort('balance_paise', desc: true).take(10)),
      outstandingCount: agg.isEmpty ? 0 : agg.first.count,
      outstandingTotal: agg.isEmpty ? 0 : agg.first.sum('balance_paise').toInt(),
      closings: await db.query(Query(BillCol.closings)
          .gte('closed_at', startOfDay(DateTime.now()).subtract(const Duration(days: 7)))
          .sort('closed_at', desc: true)
          .take(60)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canClose = context.can(BillingPerms.closeDay) && context.can(BillingPerms.payment);
    final dayLabel = switch (_day) { _Day.today => 'today', _Day.yesterday => 'yesterday', _Day.week => 'in the last 7 days' };
    return PageScaffold(
      title: 'Collections',
      subtitle: 'Money taken at every counter, and the end-of-day cash count',
      primaryAction: canClose ? PageAction('Close my day', Icons.lock_clock_outlined, () => closeMyDay(context), tourAnchor: 'billing.close_day') : null,
      headerBottom: FilterChips<_Day>(
        options: const [(_Day.today, 'Today'), (_Day.yesterday, 'Yesterday'), (_Day.week, 'Last 7 days')],
        value: _day,
        onChanged: (d) => setState(() => _day = d),
      ),
      body: LiveBuilder<_CollData>(
        watch: const {BillCol.payments, BillCol.invoices, BillCol.closings},
        deps: [_day],
        load: _load,
        builder: (context, d) {
          String whole(int p) => formatMoney(p, alwaysDecimals: false);
          final modes = d.byMode.entries.where((e) => e.value != 0).toList()..sort((a, b) => b.value.compareTo(a.value));
          final staff = d.byStaff.entries.toList()..sort((a, b) => b.value.net.compareTo(a.value.net));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minWidth: 170, spacing: Gap.md, children: [
              KpiTile(label: 'Received', value: whole(d.receivedTotal), caption: plural(d.received.length, 'payment'),
                  icon: Icons.south_west, tone: Tone.success),
              KpiTile(label: 'Refunded', value: whole(d.refundTotal), caption: plural(d.refunds.length, 'refund'),
                  icon: Icons.north_east, tone: d.refunds.isEmpty ? Tone.neutral : Tone.danger),
              KpiTile(label: 'Net collection', value: whole(d.receivedTotal - d.refundTotal), caption: 'Received minus refunds',
                  icon: Icons.account_balance_wallet_outlined, tone: Tone.info),
              KpiTile(
                label: 'Outstanding',
                value: whole(d.outstandingTotal),
                caption: '${plural(d.outstandingCount, 'bill')} with money due',
                icon: Icons.hourglass_bottom,
                tone: d.outstandingCount == 0 ? Tone.neutral : Tone.warning,
                onTap: () => context.app.nav.open('billing.invoices'),
              ),
            ]),
            Gap.v16,
            ResponsiveGrid(minWidth: 380, maxColumns: 2, children: [
              SectionCard(
                title: 'By mode',
                subtitle: 'Net of refunds, $dayLabel',
                child: modes.isEmpty
                    ? const Padding(padding: EdgeInsets.symmetric(vertical: Gap.lg), child: MutedText('Nothing received yet'))
                    : ShareBars(
                        items: [for (final e in modes) (modeLabel(e.key), e.value)],
                        format: (v) => formatMoney(v.toInt()),
                      ),
              ),
              SectionCard(
                title: 'By staff member',
                subtitle: 'Who took the money, $dayLabel',
                child: staff.isEmpty
                    ? const Padding(padding: EdgeInsets.symmetric(vertical: Gap.lg), child: MutedText('Nothing received yet'))
                    : Column(children: [
                        for (final (i, e) in staff.indexed) ...[
                          if (i > 0) const Divider(height: Gap.lg),
                          _StaffRow(staff: e.value, closing: _latestClosing(d.closings, e.key)),
                        ],
                      ]),
              ),
            ]),
            if (d.refunds.isNotEmpty) ...[
              Gap.v16,
              SectionCard(
                title: 'Refunds',
                subtitle: 'Money paid back $dayLabel. Each one was approved or within the cashier\'s limit.',
                child: Column(children: [
                  for (final (i, p) in d.refunds.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    PaymentTile(p, showBill: true, onTap: () => context.app.nav.open('billing.invoice', {'id': p.str('invoice_id')})),
                  ],
                ]),
              ),
            ],
            Gap.v24,
            BillSectionHeader('Outstanding bills',
                subtitle: d.outstandingCount > d.outstanding.length
                    ? 'The ${d.outstanding.length} largest of ${d.outstandingCount}'
                    : 'Final bills with money still due'),
            DataList<Rec>(
              items: d.outstanding,
              empty: const Card(child: EmptyState(icon: Icons.task_alt, title: 'No money due', message: 'Every final bill is paid.')),
              onTap: (b) => context.app.nav.open('billing.invoice', {'id': b.id}),
              title: (b) => b.str('patient_name'),
              subtitle: (b) => '${b.str('number')} · ${formatDate(b.date('finalised_at'))} · ${payerLabel(b.strOrNull('payer_type'))}',
              trailing: (b) => MoneyText(b.integer('balance_paise'), style: Theme.of(context).textTheme.titleSmall),
              columns: [
                ListColumn('Bill', (b) => TwoLine(b.str('number'), formatDate(b.date('finalised_at'))), flex: 3),
                ListColumn('Patient', (b) => TwoLine(b.str('patient_name'), b.str('patient_uhid')), flex: 4),
                ListColumn('Payer', (b) => Text(payerLabel(b.strOrNull('payer_type'))), flex: 2),
                ListColumn('Age', (b) => Text(waitingLabel(b.date('finalised_at') ?? b.createdAt)), width: 90),
                ListColumn('Net', (b) => MoneyText(b.integer('net_paise')), width: 116, numeric: true),
                ListColumn('Due', (b) => MoneyText(b.integer('balance_paise'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)), width: 116, numeric: true),
              ],
            ),
            Gap.v24,
            const BillSectionHeader('Day closings', subtitle: 'Cash counted at the end of each day against what the system expected'),
            DataList<Rec>(
              items: d.closings,
              empty: const Card(child: EmptyState(icon: Icons.lock_clock_outlined, title: 'No day closings this week')),
              title: (c) => '${c.str('user_name')} · ${_dateOf(c)}',
              subtitle: (c) => 'Expected ${formatMoney(c.integer('expected_cash_paise'))} · counted '
                  '${formatMoney(c.integer('counted_cash_paise'))}${c.str('notes').isEmpty ? '' : ' · ${c.str('notes')}'}',
              trailing: (c) => _VarianceChip(c.integer('variance_paise')),
              columns: [
                ListColumn('Day', (c) => TwoLine(_dateOf(c), 'Closed ${formatTime(c.date('closed_at'))}'), flex: 2),
                ListColumn('Staff', (c) => Text(c.str('user_name')), flex: 3),
                ListColumn('Expected cash', (c) => MoneyText(c.integer('expected_cash_paise')), width: 130, numeric: true),
                ListColumn('Counted', (c) => MoneyText(c.integer('counted_cash_paise')), width: 120, numeric: true),
                ListColumn('Difference', (c) => _VarianceChip(c.integer('variance_paise')), width: 140, numeric: true),
                ListColumn('Note', (c) => Text(c.str('notes', '—'), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 3),
              ],
            ),
          ]);
        },
      ),
    );
  }

  static String _dateOf(Rec c) {
    final d = DateTime.tryParse(c.str('closing_date'));
    return d == null ? c.str('closing_date') : '${formatWeekday(d)} ${formatDateShort(d)}';
  }

  static Rec? _latestClosing(List<Rec> closings, String userId) {
    final today = dayKey(DateTime.now());
    return closings.where((c) => c.str('user_id') == userId && c.str('closing_date') == today).firstOrNull;
  }
}

class _StaffRow extends StatelessWidget {
  const _StaffRow({required this.staff, this.closing});
  final _Staff staff;
  final Rec? closing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modes = staff.byMode.entries.where((e) => e.value != 0).map((e) => '${modeLabel(e.key)} ${formatMoney(e.value)}').join(' · ');
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Avatar(staff.name, size: 32),
      Gap.h12,
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(staff.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          MutedText('${plural(staff.count, 'payment')}${staff.refunds > 0 ? ' · refunds ${formatMoney(staff.refunds)}' : ''}', maxLines: 1),
          MutedText(modes, maxLines: 2),
          if (closing != null) ...[Gap.v4, _VarianceChip(closing!.integer('variance_paise'), prefix: 'Closed · ')],
        ]),
      ),
      Gap.h8,
      MoneyText(staff.net, style: theme.textTheme.titleSmall),
    ]);
  }
}

class _VarianceChip extends StatelessWidget {
  const _VarianceChip(this.variance, {this.prefix = ''});
  final int variance;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    if (variance == 0) return StatusChip('${prefix}Matches', icon: Icons.check, tone: Tone.success);
    final big = variance.abs() > 10000;
    return StatusChip(
      '$prefix${variance < 0 ? 'Short' : 'Over'} ${formatMoney(variance.abs(), alwaysDecimals: false)}',
      tone: big ? (variance < 0 ? Tone.danger : Tone.warning) : Tone.neutral,
    );
  }
}

/// The cashier counts the drawer at the end of the day.
Future<void> closeMyDay(BuildContext context) async {
  final app = context.app;
  final s = app.auth.session;
  if (s == null) return;
  final now = DateTime.now();
  final expected = await BillingService.expectedByMode(app.readDb, s.userId, now);
  final existing = await app.readDb.first(Query(BillCol.closings)
      .eq('user_id', s.userId)
      .eq('closing_date', dayKey(now))
      .sort('closed_at', desc: true));
  if (!context.mounted) return;
  final out = await showFormSheet<(int, String)>(
    context,
    title: 'Close my day',
    width: 520,
    builder: (c) => _CloseDayForm(expected: expected, existing: existing),
  );
  if (out == null || !context.mounted) return;
  final variance = out.$1 - (expected['cash'] ?? 0);
  await runGuarded(
    context,
    () => BillingService.closeDay(app.db,
        userId: s.userId, userName: s.displayName, day: now, countedCashPaise: out.$1, notes: out.$2),
    success: variance == 0
        ? 'Day closed. The cash matches.'
        : 'Day closed. ${variance < 0 ? 'Short' : 'Over'} by ${formatMoney(variance.abs())}, recorded.',
  );
}

class _CloseDayForm extends StatefulWidget {
  const _CloseDayForm({required this.expected, this.existing});
  final Map<String, int> expected;
  final Rec? existing;
  @override
  State<_CloseDayForm> createState() => _CloseDayFormState();
}

class _CloseDayFormState extends State<_CloseDayForm> {
  final _form = GlobalKey<FormState>();
  final _counted = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _cash => widget.expected['cash'] ?? 0;
  int? get _variance {
    final c = parseMoney(_counted.text);
    return c == null ? null : c - _cash;
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, (parseMoney(_counted.text)!, _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _variance;
    final modes = widget.expected.entries.where((e) => e.value != 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final ex = widget.existing;
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (ex != null)
          NoticeBanner(
            tone: Tone.info,
            icon: Icons.info_outline,
            title: 'You already closed today at ${formatTime(ex.date('closed_at'))}',
            message: 'Counting again adds a new record; the latest count is the one that stands.',
          ),
        Text('What you took today', style: theme.textTheme.titleSmall),
        Gap.v8,
        if (modes.isEmpty) const MutedText('No payments taken today'),
        for (final e in modes)
          AmountLine(modeLabel(e.key), e.value),
        const Divider(height: Gap.xl),
        AmountLine('Cash that should be in the drawer', _cash, large: true),
        Gap.v12,
        AmountField(
          label: 'Cash counted',
          controller: _counted,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        Gap.v12,
        if (v != null)
          NoticeBanner(
            tone: v == 0 ? Tone.success : (v.abs() > 10000 ? Tone.danger : Tone.warning),
            icon: v == 0 ? Icons.check_circle_outline : Icons.error_outline,
            title: v == 0 ? 'The cash matches' : '${v < 0 ? 'Short' : 'Over'} by ${formatMoney(v.abs())}',
            message: v.abs() > 10000 ? 'Differences above ₹100 go to the board. Say what happened below.' : null,
          ),
        AppTextField(
          label: 'Note',
          controller: _note,
          maxLines: 2,
          hint: 'e.g. ₹500 given as change from my own pocket',
          validator: (s) => (v ?? 0).abs() > 10000 && (s ?? '').trim().isEmpty ? 'Explain the difference' : null,
        ),
        Gap.v16,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton.icon(onPressed: v == null ? null : _submit, icon: const Icon(Icons.lock_outline), label: const Text('Close day')),
        ]),
      ]),
    );
  }
}

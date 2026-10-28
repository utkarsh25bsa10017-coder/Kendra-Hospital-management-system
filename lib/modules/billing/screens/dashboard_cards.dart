import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';

const _watch = {BillCol.invoices, BillCol.payments};

String _whole(num p) => formatMoney(p.toInt(), alwaysDecimals: false);

/// Net of everything finalised today (credit notes count against it).
class RevenueTodayCard extends StatelessWidget {
  const RevenueTodayCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, int, int)>(
        watch: _watch,
        load: (db) async {
          final rows = await db.aggregate(AggQuery.of(
              Query(BillCol.invoices).gte('finalised_at', startOfDay(DateTime.now())),
              sums: ['net_paise', 'discount_paise']));
          final count = await db.count(Query(BillCol.invoices)
              .eq('kind', InvoiceKind.invoice)
              .gte('finalised_at', startOfDay(DateTime.now())));
          final r = rows.isEmpty ? null : rows.first;
          return ((r?.sum('net_paise') ?? 0).toInt(), count, (r?.sum('discount_paise') ?? 0).toInt());
        },
        builder: (context, v) => KpiTile(
          label: 'Revenue today',
          value: _whole(v.$1),
          caption: '${plural(v.$2, 'bill')}${v.$3 > 0 ? ' · ${_whole(v.$3)} discount' : ''}',
          icon: Icons.receipt_long_outlined,
          tone: Tone.info,
          onTap: () => context.app.nav.open('billing.invoices'),
        ),
      );
}

/// Money received today, by mode.
class CollectionsTodayCard extends StatelessWidget {
  const CollectionsTodayCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<Map<String, int>>(
        watch: _watch,
        load: (db) async {
          final out = <String, int>{};
          for (final p in await db.query(Query(BillCol.payments).gte('received_at', startOfDay(DateTime.now())).take(5000))) {
            final sign = p.str('kind') == PaymentKind.refund ? -1 : 1;
            out[p.str('mode')] = (out[p.str('mode')] ?? 0) + sign * p.integer('amount_paise');
          }
          return out;
        },
        builder: (context, byMode) {
          final total = byMode.values.fold<int>(0, (a, b) => a + b);
          final items = byMode.entries.where((e) => e.value != 0).toList()..sort((a, b) => b.value.compareTo(a.value));
          return SectionCard(
            title: 'Collections today',
            subtitle: 'Net of refunds',
            trailing: Text(_whole(total), style: Theme.of(context).textTheme.titleLarge),
            child: items.isEmpty
                ? const Text('Nothing received yet today')
                : ShareBars(items: [for (final e in items) (modeLabel(e.key), e.value)], format: (v) => formatMoney(v.toInt())),
          );
        },
      );
}

/// Money still due on final bills.
class OutstandingCard extends StatelessWidget {
  const OutstandingCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, int, int)>(
        watch: _watch,
        load: (db) async {
          final due = const Query(BillCol.invoices)
              .eq('kind', InvoiceKind.invoice)
              .eq('status', InvoiceStatus.finalised)
              .gt('balance_paise', 0);
          final all = await db.aggregate(AggQuery.of(due, sums: ['balance_paise']));
          final old = await db.count(due.lt('finalised_at', DateTime.now().subtract(const Duration(days: 7))));
          final r = all.isEmpty ? null : all.first;
          return ((r?.sum('balance_paise') ?? 0).toInt(), r?.count ?? 0, old);
        },
        builder: (context, v) => KpiTile(
          label: 'Outstanding',
          value: _whole(v.$1),
          caption: '${plural(v.$2, 'bill')}${v.$3 > 0 ? ', ${v.$3} over a week old' : ''}',
          icon: Icons.hourglass_bottom,
          tone: v.$3 > 0 ? Tone.warning : Tone.neutral,
          onTap: () => context.app.nav.open('billing.invoices'),
        ),
      );
}

/// Discounts given and refunds paid this month.
class DiscountsRefundsCard extends StatelessWidget {
  const DiscountsRefundsCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, int)>(
        watch: _watch,
        load: (db) async {
          final from = startOfMonth(DateTime.now());
          final d = await db.sum(
              Query(BillCol.invoices)
                  .eq('kind', InvoiceKind.invoice)
                  .isIn('status', [InvoiceStatus.finalised, InvoiceStatus.cancelled])
                  .gte('finalised_at', from),
              'discount_paise');
          final r = await db.sum(
              Query(BillCol.payments).eq('kind', PaymentKind.refund).gte('received_at', from), 'amount_paise');
          return (d.toInt(), r.toInt());
        },
        builder: (context, v) => KpiTile(
          label: 'Discounts & refunds this month',
          value: _whole(v.$1 + v.$2),
          caption: 'Discounts ${_whole(v.$1)} · refunds ${_whole(v.$2)}',
          icon: Icons.percent,
          tone: Tone.board,
          onTap: () => context.app.nav.open('billing.collections'),
        ),
      );
}

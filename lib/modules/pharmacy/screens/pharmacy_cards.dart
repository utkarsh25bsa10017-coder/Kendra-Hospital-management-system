import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';

/// Dashboard tiles. Each loads its own numbers and keeps them live.

class PharmacySalesCard extends StatelessWidget {
  const PharmacySalesCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, int)>(
        watch: const {PCol.dispenses},
        load: (db) async {
          final rows = await db.aggregate(AggQuery.of(
              Query(PCol.dispenses).gte('dispensed_at', startOfDay(DateTime.now())),
              sums: ['total_paise']));
          final n = await db.count(Query(PCol.dispenses)
              .gte('dispensed_at', startOfDay(DateTime.now()))
              .neq('kind', DispenseKind.returned));
          return (rows.isEmpty ? 0 : rows.first.sum('total_paise').toInt(), n);
        },
        builder: (context, v) => KpiTile(
          label: 'Pharmacy sales today',
          value: formatMoneyShort(v.$1),
          caption: '${plural(v.$2, 'dispense')} at MRP',
          icon: Icons.medication_outlined,
          onTap: () => context.app.nav.open('pharmacy.dispense'),
        ),
      );
}

class StockValueCard extends StatelessWidget {
  const StockValueCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<Map<String, StockInfo>>(
        watch: const {PCol.batches},
        load: (db) => PharmacyService.stock(db),
        builder: (context, s) => KpiTile(
          label: 'Stock value',
          value: formatMoneyShort(s.values.fold<int>(0, (a, x) => a + x.valuePaise)),
          caption: '${plural(s.values.where((x) => !x.out).length, 'medicine')} in stock, at cost',
          icon: Icons.inventory_2_outlined,
          onTap: () => context.app.nav.open('pharmacy.stock'),
        ),
      );
}

class ExpiringCard extends StatelessWidget {
  const ExpiringCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<Map<String, StockInfo>>(
        watch: const {PCol.batches},
        load: (db) => PharmacyService.stock(db),
        builder: (context, s) {
          final value = s.values.fold<int>(0, (a, x) => a + x.nearExpiryValuePaise);
          final expired = s.values.fold<int>(0, (a, x) => a + x.expiredValuePaise);
          final n = s.values.where((x) => x.nearExpiry).length;
          return KpiTile(
            label: 'Expiring in 60 days',
            value: formatMoneyShort(value),
            caption: expired > 0
                ? '${plural(n, 'medicine')} · ${formatMoneyShort(expired)} already expired'
                : '${plural(n, 'medicine')} at risk',
            icon: Icons.schedule,
            tone: expired > 0 ? Tone.danger : (value > 0 ? Tone.warning : Tone.success),
            onTap: () => context.app.nav.open('pharmacy.stock'),
          );
        },
      );
}

class LowStockCard extends StatelessWidget {
  const LowStockCard({super.key});

  @override
  Widget build(BuildContext context) => LiveBuilder<Map<String, StockInfo>>(
        watch: const {PCol.batches, PCol.products},
        load: (db) => PharmacyService.stock(db),
        builder: (context, s) {
          final low = s.values.where((x) => x.atOrBelowReorder).toList();
          final out = low.where((x) => x.out).length;
          return KpiTile(
            label: 'Low stock',
            value: '${low.length}',
            caption: low.isEmpty ? 'Everything above reorder level' : '$out out of stock · ${low.take(2).map((x) => x.product.str('name')).join(', ')}',
            icon: Icons.trending_down,
            tone: out > 0 ? Tone.danger : (low.isNotEmpty ? Tone.warning : Tone.success),
            onTap: () => context.app.nav.open('pharmacy.stock'),
          );
        },
      );
}

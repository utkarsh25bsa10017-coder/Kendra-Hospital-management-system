import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'pharmacy_widgets.dart';

enum StockFilter { all, low, out, near, expired }

/// Every product with what is on the shelf, its value and nearest expiry.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  String _search = '';
  StockFilter _filter = StockFilter.all;

  bool _keep(StockInfo s) {
    if (_search.isNotEmpty) {
      final p = s.product;
      final text = '${p.str('name')} ${p.str('generic_name')} ${p.str('sku')} ${p.str('rack')}'.toLowerCase();
      if (!_search.toLowerCase().split(RegExp(r'\s+')).every(text.contains)) return false;
    }
    return switch (_filter) {
      StockFilter.all => true,
      StockFilter.low => s.low,
      StockFilter.out => s.out,
      StockFilter.near => s.nearExpiry,
      StockFilter.expired => s.expired,
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return LiveBuilder<Map<String, StockInfo>>(
      watch: const {PCol.batches, PCol.products},
      load: (db) => PharmacyService.stock(db),
      builder: (context, stock) {
        final all = stock.values.toList();
        final value = all.fold<int>(0, (a, s) => a + s.valuePaise);
        final low = all.where((s) => s.low).length;
        final out = all.where((s) => s.out).length;
        final nearValue = all.fold<int>(0, (a, s) => a + s.nearExpiryValuePaise);
        final near = all.where((s) => s.nearExpiry).length;
        final expiredValue = all.fold<int>(0, (a, s) => a + s.expiredValuePaise);
        final expired = all.where((s) => s.expired).length;
        final list = all.where(_keep).toList();

        return PageScaffold(
          title: 'Stock',
          subtitle: '${plural(all.length, 'medicine')} · ${formatMoney(value)} at cost',
          primaryAction: context.can(PharmacyPerms.purchase)
              ? PageAction('Receive stock', Icons.move_to_inbox_outlined, () => app.nav.open('pharmacy.receive'))
              : null,
          headerBottom: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchField(hint: 'Medicine, generic, SKU or rack', onChanged: (v) => setState(() => _search = v)),
              Gap.v12,
              TourAnchor(
                id: 'pharmacy.stock_filters',
                child: FilterChips<StockFilter>(
                  options: [
                    (StockFilter.all, 'All'),
                    (StockFilter.low, 'Low ($low)'),
                    (StockFilter.out, 'Out ($out)'),
                    (StockFilter.near, 'Near expiry ($near)'),
                    (StockFilter.expired, 'Expired ($expired)'),
                  ],
                  value: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                ),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ResponsiveGrid(minWidth: 220, children: [
                KpiTile(label: 'Stock value', value: formatMoneyShort(value), caption: 'Usable stock at cost', icon: Icons.inventory_2_outlined),
                KpiTile(
                  label: 'Low or out',
                  value: '${low + out}',
                  caption: '$out out of stock',
                  icon: Icons.trending_down,
                  tone: low + out > 0 ? Tone.warning : Tone.success,
                  onTap: () => setState(() => _filter = out > 0 ? StockFilter.out : StockFilter.low),
                ),
                KpiTile(
                  label: 'Expiring in 60 days',
                  value: formatMoneyShort(nearValue),
                  caption: '${plural(near, 'medicine')} to use first',
                  icon: Icons.schedule,
                  tone: near > 0 ? Tone.warning : Tone.success,
                  onTap: () => setState(() => _filter = StockFilter.near),
                ),
                KpiTile(
                  label: 'Expired on shelf',
                  value: formatMoneyShort(expiredValue),
                  caption: expired == 0 ? 'Nothing to write off' : '${plural(expired, 'medicine')} to write off',
                  icon: Icons.event_busy,
                  tone: expired > 0 ? Tone.danger : Tone.success,
                  onTap: () => setState(() => _filter = StockFilter.expired),
                ),
              ]),
              Gap.v16,
              DataList<StockInfo>(
                items: list,
                empty: Card(
                  child: EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: _search.isEmpty ? 'Nothing here' : 'No medicine matches "$_search"',
                    message: _filter == StockFilter.all ? null : 'Nothing is ${switch (_filter) {
                        StockFilter.low => 'running low',
                        StockFilter.out => 'out of stock',
                        StockFilter.near => 'close to expiry',
                        _ => 'expired on the shelf',
                      }} right now.',
                  ),
                ),
                onTap: (s) => app.nav.open('pharmacy.product', {'id': s.product.id}),
                title: (s) => s.product.str('name'),
                subtitle: (s) => [
                  qtyLabel(s.onHand, s.product.str('unit')),
                  formatMoney(s.valuePaise),
                  if (s.nearestExpiry != null) 'exp ${PharmacyService.expiryLabel(s.nearestExpiry)}',
                  if (s.product.str('rack').isNotEmpty) 'rack ${s.product.str('rack')}',
                ].join(' · '),
                trailing: (s) => StockChips(s, showOk: false),
                columns: [
                  ListColumn('Medicine', (s) => TwoLine(s.product.str('name'), s.product.str('generic_name')), flex: 5),
                  ListColumn('Rack', (s) => Text(s.product.str('rack', '—')), width: 64),
                  ListColumn('On hand', (s) => TwoLine(qtyLabel(s.onHand, s.product.str('unit')), 'reorder at ${s.reorderLevel}'),
                      flex: 3),
                  ListColumn('Value', (s) => MoneyText(s.valuePaise), numeric: true, flex: 2),
                  ListColumn('Nearest expiry', (s) => s.nearestExpiry == null ? const Text('—') : ExpiryChip(s.nearestExpiry, prefix: ''),
                      flex: 3),
                  ListColumn('Status', (s) => StockChips(s), flex: 3),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';

/// Watches stock against reorder levels and drafts one purchase order per
/// supplier. Nothing is ordered until a person approves the suggestion.
class LowStockAgent extends HmsAgent {
  @override
  String get id => 'pharmacy.low_stock';
  @override
  String get name => 'Low stock';
  @override
  String get description => 'Suggests purchase orders before medicines run out, one per supplier.';
  @override
  Set<String> get watches => const {PCol.batches, PCol.products, PCol.orders};
  @override
  Duration get interval => const Duration(hours: 2);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final db = ctx.db;
    final stock = await PharmacyService.stock(db, now: ctx.now);
    final open = await db.query(
        const Query(PCol.orders).isIn('status', [PoStatus.draft, PoStatus.ordered]).take(1000));
    final covered = {for (final o in open) for (final i in o.maps('items')) i['product_id']};
    final suppliers = {
      for (final s in await db.query(const Query(PCol.suppliers).take(1000))) s.id: s,
    };
    final lastOrder = <String, String>{};
    for (final o in await db.query(const Query(PCol.orders).sort('raised_at', desc: true).take(3000))) {
      lastOrder.putIfAbsent(o.str('supplier_id'), () => o.id);
    }

    final groups = <String, List<StockInfo>>{};
    for (final s in stock.values) {
      if (!s.atOrBelowReorder || covered.contains(s.product.id)) continue;
      // Preferred supplier, else whoever supplied the latest batch.
      var sid = s.product.str('preferred_supplier_id');
      if (sid.isEmpty && s.batches.isNotEmpty) sid = s.batches.last.str('supplier_id');
      groups.putIfAbsent(sid, () => []).add(s);
    }

    final proposals = <ProposalDraft>[];
    for (final e in groups.entries) {
      final list = e.value..sort((a, b) => a.onHand.compareTo(b.onHand));
      final supplier = suppliers[e.key];
      final who = supplier?.str('name') ?? 'a supplier';
      final items = [
        for (final s in list)
          {
            'product_id': s.product.id,
            'name': s.product.str('name'),
            'qty': PharmacyService.suggestedQty(s.product, s.onHand),
            'cost_paise': s.product.integer('purchase_price_paise'),
            'on_hand': s.onHand,
            'reorder_level': s.reorderLevel,
          }
      ];
      final total = PharmacyService.orderTotal(items);
      final out = list.where((s) => s.out).length;
      final names = [
        for (final s in list.take(4)) '${s.product.str('name')} (${s.onHand} left, reorder at ${s.reorderLevel})'
      ].join(', ');
      proposals.add(ProposalDraft(
        key: 'po:${e.key}:${PharmacyService.hashOf([for (final s in list) s.product.id, lastOrder[e.key] ?? ''])}',
        title: 'Reorder ${plural(list.length, 'medicine')} from $who',
        summary: '$names${list.length > 4 ? ' and ${list.length - 4} more' : ''}. '
            '${out > 0 ? '${plural(out, 'medicine is', 'medicines are')} already out of stock. ' : ''}'
            'Approving creates a draft purchase order of about ${formatMoney(total)} to check and send.',
        handler: 'pharmacy.create_po',
        payload: {'supplier_id': supplier?.id, 'supplier_name': supplier?.str('name'), 'items': items},
        severity: out > 0 ? Severity.medium : Severity.low,
        requiredPermission: PharmacyPerms.purchase,
      ));
    }
    return AgentReport(proposals: proposals);
  }
}

/// Carries out an approved reorder suggestion: a draft PO to check and send.
Future<String> createPoFromProposal(ModuleContext ctx, Rec proposal, Db db) async {
  final payload = proposal.map('payload');
  final items = [
    for (final i in (payload['items'] as List? ?? const []))
      if (i is Map) i.cast<String, Object?>()
  ];
  final po = await PharmacyService.createOrder(
    db,
    supplierId: payload['supplier_id'] as String?,
    items: items,
    fromProposal: true,
    notes: 'Suggested by the low stock agent',
  );
  return 'Created ${po.str('number')}';
}

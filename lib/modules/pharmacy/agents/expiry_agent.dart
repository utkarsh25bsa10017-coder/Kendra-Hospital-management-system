import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';

/// Flags stock that is about to expire (so it is used or returned in time)
/// and expired stock still counted on the shelf, and proposes writing it off.
class ExpiryAgent extends HmsAgent {
  @override
  String get id => 'pharmacy.expiry';
  @override
  String get name => 'Medicine expiry';
  @override
  String get description =>
      'Warns about batches expiring within 60 days and expired stock still on the shelf, and suggests the write-off.';
  @override
  Set<String> get watches => const {PCol.batches};
  @override
  Duration get interval => const Duration(hours: 6);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final db = ctx.db;
    final now = ctx.now;
    final cutoff = startOfDay(now).add(const Duration(days: PharmacyService.nearExpiryDays + 1));
    final batches = await db.query(Query(PCol.batches)
        .gt('qty_on_hand', 0)
        .lt('expiry_date', cutoff)
        .sort('expiry_date')
        .take(5000));
    final products = await db.byIds(PCol.products, batches.map((b) => b.str('product_id')));

    final findings = <FindingDraft>[];
    final expired = <Rec>[];
    var expiredValue = 0;
    for (final b in batches) {
      final p = products[b.str('product_id')];
      final name = p?.str('name') ?? 'Medicine';
      final qty = b.integer('qty_on_hand');
      final value = qty * b.integer('cost_paise');
      final exp = b.date('expiry_date');
      final unit = p?.str('unit', 'unit') ?? 'unit';
      final evidence = [
        Evidence('$name · batch ${b.str('batch_no')}',
            collection: PCol.batches, id: b.id, routeId: 'pharmacy.product', routeArgs: {'id': b.str('product_id')}),
      ];
      if (PharmacyService.isExpired(exp, now)) {
        expired.add(b);
        expiredValue += value;
        findings.add(FindingDraft(
          key: 'expired:${b.id}',
          subjectKey: 'batch:${b.id}',
          title: 'Expired stock on the shelf: $name',
          summary: 'Batch ${b.str('batch_no')} expired in ${PharmacyService.expiryLabel(exp)} and '
              '${plural(qty, unit)} (${formatMoney(value)} at cost) are still counted as stock. '
              'Take it off the shelf so it cannot be dispensed, then write it off.',
          severity: Severity.high,
          category: 'stock',
          amountAtRiskPaise: value,
          evidence: evidence,
        ));
      } else {
        final days = exp == null ? 0 : startOfDay(exp).difference(startOfDay(now)).inDays;
        findings.add(FindingDraft(
          key: 'near:${b.id}',
          subjectKey: 'batch:${b.id}',
          title: 'Expiring in $days days: $name',
          summary: 'Batch ${b.str('batch_no')} expires ${formatDate(exp)} with ${plural(qty, unit)} '
              '(${formatMoney(value)} at cost) left. Dispensing already uses it first; '
              'ask the supplier about a return if it will not sell in time.',
          severity: Severity.medium,
          category: 'stock',
          amountAtRiskPaise: value,
          evidence: evidence,
        ));
      }
    }

    final proposals = <ProposalDraft>[];
    if (expired.isNotEmpty) {
      final names = [
        for (final b in expired.take(4))
          '${products[b.str('product_id')]?.str('name') ?? 'Medicine'} ${b.str('batch_no')} (${b.integer('qty_on_hand')})'
      ].join(', ');
      proposals.add(ProposalDraft(
        key: 'writeoff:${PharmacyService.hashOf(expired.map((b) => b.id))}',
        title: 'Write off ${plural(expired.length, 'expired batch', 'expired batches')} (${formatMoney(expiredValue)})',
        summary: '$names${expired.length > 4 ? ' and ${expired.length - 4} more' : ''}. '
            'Approving posts an expiry write-off for each batch so stock and its value are correct.',
        handler: 'pharmacy.writeoff_expired',
        payload: {'batch_ids': [for (final b in expired) b.id], 'value_paise': expiredValue},
        severity: Severity.medium,
      ));
    }
    return AgentReport(findings: findings, proposals: proposals);
  }
}

Future<String> writeOffFromProposal(ModuleContext ctx, Rec proposal, Db db) {
  final ids = [for (final i in (proposal.map('payload')['batch_ids'] as List? ?? const [])) '$i'];
  return PharmacyService.writeOffExpired(db, ids, byName: db.actor.name, reason: 'Expired (agent suggestion approved)');
}

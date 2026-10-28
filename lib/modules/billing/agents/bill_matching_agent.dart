import 'dart:math' as math;

import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';

/// The parity check from the control-tower design, in both directions:
///
/// * BILLS: every line of a recent final bill must have a real service
///   behind it, at the list price, with a discount someone authorised.
/// * SERVICES: every charge, lab result and dispensed prescription must
///   end up on a bill.
class BillMatchingAgent extends HmsAgent {
  @override
  String get id => 'billing.bill_matching';
  @override
  String get name => 'Bill matching';
  @override
  String get description => 'Checks every bill line against the service delivered, the price list and approved '
      'discounts, and finds work that was done but never billed.';
  @override
  Set<String> get watches => const {BillCol.invoices, BillCol.lines, Col.charges, Col.serviceOrders, Col.prescriptions};
  @override
  Duration get interval => const Duration(hours: 1);

  /// Manual lines in these categories need a delivered service behind them.
  static const _deliverable = {Vals.lab, Vals.radiology, Vals.pharmacy, Vals.bed, Vals.procedure};
  static const _deliveredOrder = {Vals.collected, Vals.inProgress, Vals.resulted, Vals.verified, 'completed', 'done'};
  static const _grace = Duration(hours: 2);

  static Future<List<Rec>> _chunked(ReadDb db, Query base, String field, List<String> values, {int each = 5000}) async {
    final out = <Rec>[];
    for (var i = 0; i < values.length; i += 400) {
      out.addAll(await db.query(base.isIn(field, values.sublist(i, math.min(i + 400, values.length))).take(each)));
    }
    return out;
  }

  static Evidence _bill(Rec inv) => Evidence('${inv.str('number')} · ${inv.str('patient_name')}',
      collection: BillCol.invoices, id: inv.id, routeId: 'billing.invoice', routeArgs: {'id': inv.id});

  static Evidence _patient(String id, String name) =>
      Evidence(name.isEmpty ? 'Patient' : name, collection: Col.patients, id: id, routeId: 'patients.profile', routeArgs: {'id': id});

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final findings = <FindingDraft>[];
    await _checkBills(ctx, findings);
    await _checkServices(ctx, findings);
    return AgentReport(findings: findings);
  }

  // ------------------------------------------------------------------ bills

  Future<void> _checkBills(AgentContext ctx, List<FindingDraft> out) async {
    final db = ctx.db;
    final since = ctx.now.subtract(const Duration(days: 30));
    final bills = await db.query(Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .eq('status', InvoiceStatus.finalised)
        .gte('finalised_at', since)
        .sort('finalised_at', desc: true)
        .take(3000));
    if (bills.isEmpty) return;
    final byId = {for (final b in bills) b.id: b};
    final lines = await _chunked(db, const Query(BillCol.lines), 'invoice_id', byId.keys.toList(), each: 20000);
    final prices = {
      for (final s in await db.query(const Query(Col.services).withArchived().take(5000))) s.str('code'): s.integer('price_paise'),
    };

    // Discounts someone authorised, per bill (the largest applied approval).
    final approved = <String, int>{};
    for (final a in await db.query(Query(Col.approvals)
        .eq('type', BillingApprovals.discount)
        .eq('status', 'applied')
        .gte('created_at', since.subtract(const Duration(days: 30)))
        .take(5000))) {
      final inv = (a.map('payload')['invoice_id'] as String?) ?? a.str('subject_id');
      approved[inv] = math.max(approved[inv] ?? 0, a.integer('amount_paise'));
    }

    // What was actually delivered, for hand-added lines.
    final manual = lines.where((l) => l.str('source') == 'manual' && _deliverable.contains(l.str('category'))).toList();
    final patientIds = {for (final l in manual) byId[l.str('invoice_id')]?.str('patient_id')}.whereType<String>().toList();
    final from = since.subtract(const Duration(days: 30));
    final orders = patientIds.isEmpty
        ? <Rec>[]
        : await _chunked(db, Query(Col.serviceOrders).gte('ordered_at', from), 'patient_id', patientIds);
    final charges = patientIds.isEmpty
        ? <Rec>[]
        : await _chunked(db, Query(Col.charges).gte('service_date', from), 'patient_id', patientIds, each: 10000);
    final rxs = patientIds.isEmpty
        ? <Rec>[]
        : await _chunked(db, Query(Col.prescriptions).isIn('status', [Vals.dispensed, Vals.partiallyDispensed]),
            'patient_id', patientIds, each: 2000);

    bool within(DateTime? d, DateTime billAt) =>
        d != null && d.isAfter(billAt.subtract(const Duration(days: 30))) && d.isBefore(billAt.add(const Duration(days: 1)));

    for (final l in lines) {
      final inv = byId[l.str('invoice_id')];
      if (inv == null) continue;
      final billAt = inv.date('finalised_at') ?? inv.createdAt;
      final pid = inv.str('patient_id');
      final pname = inv.str('patient_name');
      final code = l.strOrNull('service_code');
      final qty = l.integer('quantity', 1);

      // (a) Charged with no record of the service.
      if (l.str('source') == 'manual' && _deliverable.contains(l.str('category'))) {
        final cat = l.str('category');
        final delivered = orders.any((o) =>
                o.str('patient_id') == pid &&
                code != null &&
                o.strOrNull('service_code') == code &&
                _deliveredOrder.contains(o.str('status')) &&
                within(o.date('ordered_at'), billAt)) ||
            charges.any((c) =>
                c.str('patient_id') == pid &&
                c.str('status') != Vals.cancelled &&
                ((code != null && c.strOrNull('service_code') == code) ||
                    ((cat == Vals.bed || cat == Vals.pharmacy) && c.str('category') == cat)) &&
                within(c.date('service_date'), billAt)) ||
            (cat == Vals.pharmacy &&
                rxs.any((r) => r.str('patient_id') == pid && within(r.date('dispensed_at') ?? r.createdAt, billAt)));
        if (!delivered) {
          out.add(FindingDraft(
            key: 'line:${l.id}',
            title: 'Possible overbilling: ${l.str('description')}',
            summary: '${l.str('description')} (${formatMoney(l.integer('net_paise'))}) was added by hand to '
                '${inv.str('number')} for $pname, but there is no ${categoryLabel(cat).toLowerCase()} record '
                'showing it was done.',
            severity: Severity.medium,
            category: 'billing',
            amountAtRiskPaise: l.integer('net_paise'),
            patientId: pid,
            evidence: [_bill(inv), _patient(pid, pname)],
            data: {'invoice_id': inv.id, 'line_id': l.id, 'service_code': code},
          ));
        }
      }

      // (b) Wrong rate for the code.
      // Doctors charge their own fees, so a consultation is only compared
      // with the fee captured when the line was made.
      final feeBased = l.str('category') == Vals.consultation && l.str('source') == 'charge';
      final listPrice = l.intOrNull('list_price_paise') ?? (code == null || feeBased ? null : prices[code]);
      final unit = l.integer('unit_price_paise');
      if (listPrice != null && listPrice > 0 && unit != listPrice) {
        final diff = unit - listPrice;
        final total = diff.abs() * (qty.abs() > 1 ? qty.abs() : 1);
        final big = total >= 50000 || diff.abs() * 4 >= listPrice;
        out.add(FindingDraft(
          key: 'line:${l.id}:price',
          title: 'Price deviation: ${l.str('description')}',
          summary: 'Charged ${formatMoney(unit)} against the list price of ${formatMoney(listPrice)} on '
              '${inv.str('number')} for $pname: ${formatMoney(diff.abs())} ${diff < 0 ? 'less' : 'more'}'
              '${qty.abs() > 1 ? ' × $qty = ${formatMoney(total)}' : ''}.',
          severity: big ? Severity.medium : Severity.low,
          category: 'billing',
          amountAtRiskPaise: total,
          patientId: pid,
          evidence: [_bill(inv), _patient(pid, pname)],
          data: {'invoice_id': inv.id, 'line_id': l.id, 'unit_price_paise': unit, 'list_price_paise': listPrice},
        ));
      }
    }

    // (c) Discount nobody authorised (or more than was authorised).
    for (final inv in bills) {
      final discount = inv.integer('discount_paise');
      if (discount <= 0) continue;
      final covered = approved[inv.id] ?? 0;
      if (discount <= covered) continue;
      final by = inv.str('discount_by_name', 'someone');
      out.add(FindingDraft(
        key: 'invoice:${inv.id}:discount',
        title: 'Unauthorised discount on ${inv.str('number')}',
        summary: covered == 0
            ? '${formatMoney(discount)} discount for ${inv.str('patient_name')} with no approval on record '
                '(given by $by).'
            : '${formatMoney(discount)} discount for ${inv.str('patient_name')} is ${formatMoney(discount - covered)} '
                'more than the ${formatMoney(covered)} that was approved (given by $by).',
        severity: Severity.high,
        category: 'discounts',
        amountAtRiskPaise: discount - covered,
        patientId: inv.str('patient_id'),
        evidence: [_bill(inv), _patient(inv.str('patient_id'), inv.str('patient_name'))],
        data: {'invoice_id': inv.id, 'discount_paise': discount, 'approved_paise': covered},
      ));
    }
  }

  // ------------------------------------------------------------------ services

  Future<void> _checkServices(AgentContext ctx, List<FindingDraft> out) async {
    final db = ctx.db;
    final now = ctx.now;
    final prices = {
      for (final s in await db.query(const Query(Col.services).withArchived().take(5000))) s.str('code'): s.integer('price_paise'),
    };

    // Charges still waiting a day after the work, on a closed visit.
    final pending = await db.query(Query(Col.charges)
        .eq('status', Vals.pending)
        .gte('service_date', now.subtract(const Duration(days: 90)))
        .lt('service_date', now.subtract(const Duration(hours: 24)))
        .sort('service_date')
        .take(5000));
    final encounters = await db.byIds(Col.encounters, pending.map((c) => c.strOrNull('encounter_id')));
    final drafts = await db.byIds(BillCol.invoices, pending.map((c) => c.strOrNull('invoice_id')));

    // Results and dispensed prescriptions with no charge.
    final orders = await db.query(Query(Col.serviceOrders)
        .isIn('status', [Vals.resulted, Vals.verified])
        .gte('ordered_at', now.subtract(const Duration(days: 60)))
        .take(5000));
    final uncharged = orders.where((o) => (o.strOrNull('charge_id') ?? '').isEmpty).toList();
    final bySource = <String>{
      for (final c in await _chunked(db, const Query(Col.charges), 'source_id', uncharged.map((o) => o.id).toList()))
        if (c.str('status') != Vals.cancelled) c.str('source_id'),
    };
    final rxs = await db.query(Query(Col.prescriptions)
        .eq('status', Vals.dispensed)
        .gte('updated_at', now.subtract(const Duration(days: 60)))
        .take(3000));
    final rxPatients = rxs.map((r) => r.str('patient_id')).toSet().toList();
    final pharmacyCharges = await _chunked(
        db,
        Query(Col.charges).eq('category', Vals.pharmacy).gte('service_date', now.subtract(const Duration(days: 75))),
        'patient_id',
        rxPatients,
        each: 10000);

    final patients = await db.byIds(Col.patients, [
      ...pending.map((c) => c.str('patient_id')),
      ...uncharged.map((o) => o.str('patient_id')),
      ...rxs.map((r) => r.str('patient_id')),
    ]);
    String nameOf(String id) => patients[id]?.str('full_name') ?? 'a patient';

    for (final c in pending) {
      final encId = c.strOrNull('encounter_id');
      final enc = encId == null ? null : encounters[encId];
      if (enc != null && enc.str('status') != Vals.closed) continue;
      final pid = c.str('patient_id');
      final amount = c.integer('amount_paise');
      if (amount <= 0) continue;
      final when = c.date('service_date') ?? c.createdAt;
      final draft = drafts[c.strOrNull('invoice_id')];
      out.add(FindingDraft(
        key: 'charge:${c.id}',
        title: 'Leakage: ${c.str('description')} never billed',
        summary: 'Work done but never billed: ${nameOf(pid)} had ${c.str('description')} '
            '(${formatMoney(amount)}, ${sourceLabel(c.strOrNull('source_module'))}) on ${formatDate(when)}. '
            '${enc == null ? 'There is no open visit' : 'The visit is closed'}'
            '${draft != null && !draft.archived ? ' and the charge is sitting on ${draft.str('number')}, never finalised' : ' and it is on no bill'}.',
        severity: amount >= 100000 ? Severity.medium : Severity.low,
        category: 'leakage',
        amountAtRiskPaise: amount,
        patientId: pid,
        evidence: [
          _patient(pid, nameOf(pid)),
          if (draft != null && !draft.archived) _bill(draft),
          Evidence(c.str('description'), collection: Col.charges, id: c.id),
        ],
        data: {'charge_id': c.id, 'encounter_id': encId},
      ));
    }

    for (final o in uncharged) {
      if (bySource.contains(o.id)) continue;
      final done = o.date('resulted_at') ?? o.date('verified_at') ?? o.date('ordered_at') ?? o.createdAt;
      if (now.difference(done) < _grace) continue;
      final pid = o.str('patient_id');
      final price = prices[o.strOrNull('service_code')];
      out.add(FindingDraft(
        key: 'order:${o.id}',
        title: 'Leakage: ${o.str('name')} never charged',
        summary: 'Work done but never billed: ${o.str('name')} for ${nameOf(pid)} was ${o.str('status')} on '
            '${formatDate(done)}, but no charge was posted for it.',
        severity: (price ?? 0) >= 100000 ? Severity.medium : Severity.low,
        category: 'leakage',
        amountAtRiskPaise: price,
        patientId: pid,
        evidence: [
          _patient(pid, nameOf(pid)),
          Evidence(o.str('name'),
              collection: Col.serviceOrders,
              id: o.id,
              routeId: o.str('order_type') == Vals.lab ? 'lab.order' : null,
              routeArgs: {'id': o.id}),
        ],
        data: {'order_id': o.id, 'service_code': o.strOrNull('service_code')},
      ));
    }

    for (final r in rxs) {
      final at = r.date('dispensed_at') ?? r.updatedAt;
      if (now.difference(at) < _grace) continue;
      final pid = r.str('patient_id');
      final enc = r.strOrNull('encounter_id');
      final charged = pharmacyCharges.any((c) =>
          c.str('patient_id') == pid &&
          c.str('status') != Vals.cancelled &&
          ((enc != null && c.strOrNull('encounter_id') == enc) ||
              c.str('source_id').startsWith(r.id) ||
              ((c.date('service_date') ?? c.createdAt).difference(at).inHours.abs() <= 24)));
      if (charged) continue;
      final items = r.maps('items');
      out.add(FindingDraft(
        key: 'rx:${r.id}',
        title: 'Leakage: medicines dispensed for ${nameOf(pid)} never charged',
        summary: 'Work done but never billed: a prescription with ${plural(items.length, 'medicine')} was dispensed '
            'on ${formatDate(at)}, but there is no pharmacy charge for it.',
        severity: Severity.medium,
        category: 'leakage',
        patientId: pid,
        evidence: [_patient(pid, nameOf(pid)), Evidence('Prescription', collection: Col.prescriptions, id: r.id)],
        data: {'prescription_id': r.id, 'encounter_id': enc},
      ));
    }
  }
}

import 'dart:math' as math;

import 'package:kendra_hms/core/core.dart';

import 'billing_schema.dart';

/// One part of a payment at the counter (split payments are several entries).
class PaymentEntry {
  const PaymentEntry(this.mode, this.amountPaise, {this.reference, this.notes});
  final String mode;
  final int amountPaise;
  final String? reference;
  final String? notes;
}

/// The money on one bill.
///
/// * net = gross - discount
/// * paid = payments - refunds (money we hold for this bill)
/// * adjusted = the part of the refunds that reduced what the patient owes
///   (a refund for a service not given), as opposed to returning excess
/// * balance = net - adjusted - paid; below zero means we owe the patient
class BillTotals {
  const BillTotals({
    required this.gross,
    required this.discount,
    required this.paymentsIn,
    required this.refunds,
    this.adjusted = 0,
  });

  /// Totals from line amounts, the bill discount and the money moved so far.
  factory BillTotals.compute({
    required Iterable<int> lineAmounts,
    int discount = 0,
    Iterable<(String, int)> money = const [],
    int adjusted = 0,
  }) {
    final gross = lineAmounts.fold<int>(0, (a, b) => a + b);
    var paidIn = 0;
    var out = 0;
    for (final (kind, amount) in money) {
      if (kind == PaymentKind.refund) {
        out += amount;
      } else {
        paidIn += amount;
      }
    }
    return BillTotals(
      gross: gross,
      discount: discount.clamp(0, math.max(0, gross)),
      paymentsIn: paidIn,
      refunds: out,
      adjusted: adjusted,
    );
  }

  final int gross;
  final int discount;
  final int paymentsIn;
  final int refunds;
  final int adjusted;

  int get net => gross - discount;
  int get paid => paymentsIn - refunds;
  int get balance => net - adjusted - paid;

  Map<String, Object?> fields({bool cancelled = false}) => {
        'gross_paise': gross,
        'discount_paise': discount,
        'net_paise': net,
        'paid_paise': paid,
        'refunded_paise': refunds,
        'adjusted_paise': adjusted,
        'balance_paise': cancelled ? 0 : balance,
      };
}

/// What happened to a discount, refund or cancellation request.
/// (Core's `ApprovalOutcome` is not exported to modules.)
class ApprovalResult {
  const ApprovalResult(this.approval, {required this.applied});
  final Rec approval;

  /// True when it was within the requester's limit and is already done.
  final bool applied;

  bool get failed => approval.str('status') == 'failed';
}

/// A patient waiting at the counter: charges other departments posted that
/// are not on any bill yet.
class ReadyToBill {
  ReadyToBill(this.patient, this.charges, {this.inWard = false});
  final Rec patient;
  final List<Rec> charges;

  /// Every charge belongs to a stay that is still open: usually billed at
  /// discharge, not at the counter.
  final bool inWard;

  int get total => charges.fold<int>(0, (a, c) => a + c.integer('amount_paise'));
  DateTime get oldest => charges
      .map((c) => c.date('service_date') ?? c.createdAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  List<String> get categories {
    final seen = <String>{};
    for (final c in charges) {
      seen.add(categoryLabel(c.strOrNull('category')));
    }
    return seen.toList();
  }
}

/// Billing rules shared by the screens, the approval handlers and the demo.
abstract final class BillingService {
  static String _yy(DateTime d) => (d.year % 100).toString().padLeft(2, '0');

  /// INV-26-000123, RCPT-26-000045... Numbers never repeat, even across devices.
  static Future<String> nextNumber(Db db, String sequence, String prefix, [DateTime? at]) async {
    final n = await db.nextSequence(sequence);
    return '$prefix-${_yy(at ?? DateTime.now())}-${n.toString().padLeft(6, '0')}';
  }

  // ------------------------------------------------------------------ reads

  static Query unbilledCharges() => const Query(Col.charges).eq('status', Vals.pending).isNull('invoice_id');

  static Future<List<Rec>> unbilledFor(ReadDb db, String patientId) =>
      db.query(unbilledCharges().eq('patient_id', patientId).sort('service_date').take(500));

  static Future<List<Rec>> linesOf(ReadDb db, String invoiceId) =>
      db.query(Query(BillCol.lines).eq('invoice_id', invoiceId).sort('position').take(500));

  static Future<List<Rec>> paymentsOf(ReadDb db, String invoiceId) =>
      db.query(Query(BillCol.payments).eq('invoice_id', invoiceId).sort('received_at').take(500));

  static Future<List<Rec>> pendingApprovals(ReadDb db, String invoiceId) => db.query(
      Query(Col.approvals).eq('subject_id', invoiceId).eq('status', 'pending').sort('created_at').take(20));

  /// Patients with charges waiting to be billed, oldest first.
  static Future<List<ReadyToBill>> readyToBill(ReadDb db, {int limit = 200}) async {
    final charges = await db.query(unbilledCharges().sort('service_date').take(3000));
    final byPatient = <String, List<Rec>>{};
    for (final c in charges) {
      byPatient.putIfAbsent(c.str('patient_id'), () => []).add(c);
    }
    final patients = await db.byIds(Col.patients, byPatient.keys);
    final encounters = await db.byIds(Col.encounters, charges.map((c) => c.strOrNull('encounter_id')));
    bool ward(Rec c) {
      final e = encounters[c.strOrNull('encounter_id')];
      return e != null && e.str('type') == Vals.ipd && e.str('status') == Vals.open;
    }

    final out = [
      for (final e in byPatient.entries)
        if (patients[e.key] != null) ReadyToBill(patients[e.key]!, e.value, inWard: e.value.every(ward)),
    ]..sort((a, b) => a.inWard != b.inWard ? (a.inWard ? 1 : -1) : a.oldest.compareTo(b.oldest));
    return out.take(limit).toList();
  }

  /// Price-list prices by service code.
  static Future<Map<String, int>> listPrices(ReadDb db, Iterable<String?> codes) async {
    final wanted = codes.whereType<String>().where((c) => c.isNotEmpty).toSet().toList();
    final out = <String, int>{};
    for (var i = 0; i < wanted.length; i += 400) {
      final chunk = wanted.sublist(i, math.min(i + 400, wanted.length));
      for (final s in await db.query(Query(Col.services).isIn('code', chunk).withArchived().take(chunk.length))) {
        out[s.str('code')] = s.integer('price_paise');
      }
    }
    return out;
  }

  /// The price each charge should have been, keyed by charge id: the
  /// doctor's own fee for a consultation, otherwise the price list.
  static Future<Map<String, int>> referencePrices(ReadDb db, List<Rec> charges) async {
    final prices = await listPrices(db, charges.map((c) => c.strOrNull('service_code')));
    bool consult(Rec c) => c.str('category') == Vals.consultation && (c.strOrNull('service_code') ?? 'CONSULT') == 'CONSULT';
    final doctors = await db.byIds(Col.users, charges.where(consult).map((c) => c.strOrNull('ordered_by')));
    final out = <String, int>{};
    for (final c in charges) {
      final fee = consult(c) ? doctors[c.strOrNull('ordered_by')]?.intOrNull('consultation_fee_paise') : null;
      final p = fee ?? prices[c.strOrNull('service_code')];
      if (p != null) out[c.id] = p;
    }
    return out;
  }

  /// How much can still be refunded on [invoice].
  static int refundable(Rec invoice) {
    if (invoice.str('status') != InvoiceStatus.finalised || invoice.str('kind') != InvoiceKind.invoice) return 0;
    final held = math.max(0, invoice.integer('paid_paise'));
    final owedToPatient = math.max(0, -(invoice.integer('net_paise') - invoice.integer('adjusted_paise')));
    return held + owedToPatient;
  }

  /// Money received in total (payments, before refunds).
  static int received(Rec invoice) => invoice.integer('paid_paise') + invoice.integer('refunded_paise');

  // ------------------------------------------------------------------ discount spread

  /// Spreads a bill discount over the lines in proportion to their amounts,
  /// so line nets always add up to the bill net. Negative lines (returns)
  /// get none.
  static List<int> allocate(int discount, List<int> amounts) {
    final out = List<int>.filled(amounts.length, 0);
    final base = amounts.fold<int>(0, (a, b) => a + (b > 0 ? b : 0));
    if (discount <= 0 || base <= 0) return out;
    var given = 0;
    for (var i = 0; i < amounts.length; i++) {
      if (amounts[i] <= 0) continue;
      out[i] = discount * amounts[i] ~/ base;
      given += out[i];
    }
    final order = [for (var i = 0; i < amounts.length; i++) if (amounts[i] > 0) i]
      ..sort((a, b) => amounts[b].compareTo(amounts[a]));
    for (var k = 0; given < discount && order.isNotEmpty; k++) {
      out[order[k % order.length]]++;
      given++;
    }
    return out;
  }

  /// Writes that bring a draft's lines and totals in step: [keep] are the
  /// existing lines that stay, [added] new line records to insert.
  static List<WriteOp> _draftOps(
    Rec invoice, {
    required List<Rec> keep,
    List<Map<String, Object?>> added = const [],
    int? discount,
    Map<String, Object?> extra = const {},
  }) {
    final amounts = [
      for (final l in keep) l.integer('amount_paise'),
      for (final a in added) (a['amount_paise'] as int?) ?? 0,
    ];
    final totals =
        BillTotals.compute(lineAmounts: amounts, discount: discount ?? invoice.integer('discount_paise'));
    final shares = allocate(totals.discount, amounts);
    final ops = <WriteOp>[];
    for (var i = 0; i < keep.length; i++) {
      final l = keep[i];
      final net = amounts[i] - shares[i];
      if (l.integer('discount_paise') != shares[i] || l.integer('net_paise') != net) {
        ops.add(UpdateOp(BillCol.lines, l.id, {'discount_paise': shares[i], 'net_paise': net}));
      }
    }
    for (var j = 0; j < added.length; j++) {
      final i = keep.length + j;
      ops.add(InsertOp(BillCol.lines, {...added[j], 'discount_paise': shares[i], 'net_paise': amounts[i] - shares[i]}));
    }
    ops.add(UpdateOp(BillCol.invoices, invoice.id, {...totals.fields(), ...extra}, expectedVersion: invoice.version));
    return ops;
  }

  static Map<String, Object?> lineFromCharge(Rec c, {required String invoiceId, required int position, int? listPrice}) {
    final qty = c.intOrNull('quantity') ?? 1;
    final amount = c.integer('amount_paise');
    final unit = c.intOrNull('unit_price_paise') ?? (qty == 0 ? amount : amount ~/ qty);
    return {
      'invoice_id': invoiceId,
      'patient_id': c.str('patient_id'),
      'position': position,
      'charge_id': c.id,
      'source': 'charge',
      'source_module': c.strOrNull('source_module'),
      'service_code': c.strOrNull('service_code'),
      'description': c.str('description'),
      'category': c.str('category', Vals.other),
      'quantity': qty,
      'unit_price_paise': unit,
      'list_price_paise': listPrice,
      'amount_paise': amount,
      'service_date': c.date('service_date') ?? c.createdAt,
    };
  }

  static Future<Rec> _invoice(ReadDb db, String id) async {
    final inv = await db.get(BillCol.invoices, id);
    if (inv == null || inv.archived) throw ValidationException('This bill no longer exists');
    return inv;
  }

  static Rec _draft(Rec inv) {
    if (inv.str('status') != InvoiceStatus.draft) {
      throw ValidationException('${inv.str('number')} is final and cannot be changed. Use a refund or cancel it.');
    }
    return inv;
  }

  static Future<void> _write(Db db, List<WriteOp> ops, {String? conflict}) async {
    try {
      await db.batch(ops);
    } on ConflictException {
      throw ConflictException(conflict ?? 'Someone else changed this bill just now. It has been reloaded; try again.');
    }
  }

  /// Fresh copies of [charges], checked to be free for a bill of [patientId].
  static Future<List<Rec>> _freeCharges(ReadDb db, List<Rec> charges, String patientId) async {
    final fresh = await db.byIds(Col.charges, charges.map((c) => c.id));
    return [
      for (final c in charges)
        () {
          final f = fresh[c.id];
          if (f == null || f.archived) throw ValidationException('A charge on this bill no longer exists');
          final what = f.str('description');
          if (f.str('patient_id') != patientId) throw ValidationException('$what belongs to another patient');
          if (f.str('status') != Vals.pending) throw ValidationException('$what is already ${f.str('status')}');
          if (f.strOrNull('invoice_id') != null) throw ValidationException('$what is already on another bill');
          return f;
        }(),
    ];
  }

  // ------------------------------------------------------------------ drafts

  /// Starts a draft bill for [patientId] from [charges] (by default every
  /// charge of theirs that is not on a bill yet). The charges stay pending
  /// but are linked to the draft, so no other bill can take them.
  static Future<Rec> createDraft(Db db, String patientId, {List<Rec>? charges, DateTime? at, String? notes}) async {
    final patient = await db.get(Col.patients, patientId);
    if (patient == null) throw ValidationException('Patient not found');
    final wanted = await _freeCharges(db, charges ?? await unbilledFor(db, patientId), patientId);
    final id = db.newId();
    final n = await db.nextSequence('invoice_draft');
    final prices = await referencePrices(db, wanted);
    final lines = [
      for (final (i, c) in wanted.indexed) lineFromCharge(c, invoiceId: id, position: i + 1, listPrice: prices[c.id]),
    ];
    final encounters = wanted.map((c) => c.strOrNull('encounter_id')).whereType<String>().toSet();
    final totals = BillTotals.compute(lineAmounts: lines.map((l) => l['amount_paise'] as int));
    await _write(db, [
      InsertOp(BillCol.invoices, {
        'number': 'DRAFT-$n',
        'kind': InvoiceKind.invoice,
        'patient_id': patientId,
        'patient_name': patient.str('full_name'),
        'patient_uhid': patient.str('uhid'),
        'encounter_id': encounters.length == 1 ? encounters.first : null,
        'payer_type': patient.str('payer_type', 'self'),
        'status': InvoiceStatus.draft,
        'bill_date': at ?? DateTime.now(),
        'notes': notes,
        ...totals.fields(),
      }, id: id),
      for (final c in wanted) UpdateOp(Col.charges, c.id, {'invoice_id': id}, expectedVersion: c.version),
      for (final l in lines) InsertOp(BillCol.lines, {...l, 'discount_paise': 0, 'net_paise': l['amount_paise']}),
    ], conflict: 'Another bill took some of these charges just now. Refresh and try again.');
    return _invoice(db, id);
  }

  /// Adds more pending charges of the same patient to a draft.
  static Future<void> addCharges(Db db, String invoiceId, List<Rec> charges) async {
    if (charges.isEmpty) return;
    final inv = _draft(await _invoice(db, invoiceId));
    final wanted = await _freeCharges(db, charges, inv.str('patient_id'));
    final lines = await linesOf(db, inv.id);
    final prices = await referencePrices(db, wanted);
    var pos = lines.fold<int>(0, (a, l) => math.max(a, l.integer('position')));
    await _write(db, [
      for (final c in wanted) UpdateOp(Col.charges, c.id, {'invoice_id': inv.id}, expectedVersion: c.version),
      ..._draftOps(inv, keep: lines, added: [
        for (final c in wanted)
          lineFromCharge(c, invoiceId: inv.id, position: ++pos, listPrice: prices[c.id]),
      ]),
    ], conflict: 'Another bill took some of these charges just now. Refresh and try again.');
  }

  /// Adds an item from the price list that no department posted (for
  /// example a dressing done at the counter). [unitPricePaise] defaults to
  /// the list price; a different rate is allowed but the agents check it.
  static Future<void> addManualLine(Db db, String invoiceId,
      {required Rec service, int quantity = 1, int? unitPricePaise, String? description, DateTime? at}) async {
    if (quantity <= 0) throw ValidationException('Quantity must be at least 1');
    final unit = unitPricePaise ?? service.integer('price_paise');
    if (unit < 0) throw ValidationException('Rate cannot be negative');
    final inv = _draft(await _invoice(db, invoiceId));
    final lines = await linesOf(db, inv.id);
    final pos = lines.fold<int>(0, (a, l) => math.max(a, l.integer('position'))) + 1;
    await _write(db, _draftOps(inv, keep: lines, added: [
      {
        'invoice_id': inv.id,
        'patient_id': inv.str('patient_id'),
        'position': pos,
        'source': 'manual',
        'source_module': 'billing',
        'service_code': service.str('code'),
        'description': (description ?? '').trim().isEmpty ? service.str('name') : description!.trim(),
        'category': service.str('category', Vals.other),
        'quantity': quantity,
        'unit_price_paise': unit,
        'list_price_paise': service.integer('price_paise'),
        'amount_paise': unit * quantity,
        'service_date': at ?? DateTime.now(),
      },
    ]));
  }

  /// Takes a line off a draft. A charge goes back to "ready to bill".
  static Future<void> removeLine(Db db, String invoiceId, String lineId) async {
    final inv = _draft(await _invoice(db, invoiceId));
    final lines = await linesOf(db, inv.id);
    final line = lines.where((l) => l.id == lineId).firstOrNull;
    if (line == null) throw ValidationException('That line is no longer on the bill');
    final ops = <WriteOp>[ArchiveOp(BillCol.lines, line.id, reason: 'Removed from draft')];
    final chargeId = line.strOrNull('charge_id');
    if (chargeId != null) {
      final c = await db.get(Col.charges, chargeId);
      if (c != null && c.strOrNull('invoice_id') == inv.id && c.str('status') == Vals.pending) {
        ops.add(UpdateOp(Col.charges, c.id, {'invoice_id': null}, expectedVersion: c.version));
      }
    }
    ops.addAll(_draftOps(inv, keep: [for (final l in lines) if (l.id != lineId) l]));
    await _write(db, ops);
  }

  /// Charge lines whose charge was cancelled or changed by the department
  /// after the draft was made.
  static Future<List<(Rec line, Rec? charge)>> staleLines(ReadDb db, List<Rec> lines) async {
    final ids = lines.map((l) => l.strOrNull('charge_id')).whereType<String>();
    final charges = await db.byIds(Col.charges, ids);
    final out = <(Rec, Rec?)>[];
    for (final l in lines) {
      final id = l.strOrNull('charge_id');
      if (id == null) continue;
      final c = charges[id];
      if (c == null || c.str('status') == Vals.cancelled || c.integer('amount_paise') != l.integer('amount_paise')) {
        out.add((l, c));
      }
    }
    return out;
  }

  /// Brings changed charge lines up to date and drops cancelled ones.
  static Future<int> syncWithCharges(Db db, String invoiceId) async {
    final inv = _draft(await _invoice(db, invoiceId));
    final lines = await linesOf(db, inv.id);
    final stale = await staleLines(db, lines);
    if (stale.isEmpty) return 0;
    final ops = <WriteOp>[];
    final drop = <String>{};
    final keep = <Rec>[];
    final staleById = {for (final (l, c) in stale) l.id: c};
    for (final l in lines) {
      if (!staleById.containsKey(l.id)) {
        keep.add(l);
        continue;
      }
      final c = staleById[l.id];
      if (c == null || c.str('status') == Vals.cancelled) {
        drop.add(l.id);
        ops.add(ArchiveOp(BillCol.lines, l.id, reason: 'Charge cancelled by the department'));
        continue;
      }
      final fresh = lineFromCharge(c, invoiceId: inv.id, position: l.integer('position'), listPrice: l.intOrNull('list_price_paise'));
      ops.add(UpdateOp(BillCol.lines, l.id, {
        for (final k in ['description', 'quantity', 'unit_price_paise', 'amount_paise']) k: fresh[k],
      }));
      keep.add(l.copyWith({
        'amount_paise': fresh['amount_paise'],
        // Forces the discount share to be rewritten for this line.
        'net_paise': -1,
      }));
    }
    ops.addAll(_draftOps(inv, keep: keep));
    await _write(db, ops);
    return stale.length;
  }

  /// Throws the draft away. Its charges go back to "ready to bill".
  static Future<void> discardDraft(Db db, String invoiceId) async {
    final inv = _draft(await _invoice(db, invoiceId));
    final lines = await linesOf(db, inv.id);
    final charges = await db.byIds(Col.charges, lines.map((l) => l.strOrNull('charge_id')));
    await _write(db, [
      for (final l in lines) ArchiveOp(BillCol.lines, l.id, reason: 'Draft discarded'),
      for (final c in charges.values)
        if (c.strOrNull('invoice_id') == inv.id && c.str('status') == Vals.pending)
          UpdateOp(Col.charges, c.id, {'invoice_id': null}, expectedVersion: c.version),
      ArchiveOp(BillCol.invoices, inv.id, reason: 'Draft discarded'),
    ]);
  }

  // ------------------------------------------------------------------ finalise

  /// Turns a draft into a numbered bill. Its charges become "billed".
  /// From here on the bill is never edited.
  static Future<Rec> finalise(Db db, String invoiceId, {DateTime? at, String? byId, String? byName}) async {
    final inv = _draft(await _invoice(db, invoiceId));
    final lines = await linesOf(db, inv.id);
    if (lines.isEmpty) throw ValidationException('Add at least one item before finalising');
    final waiting = (await pendingApprovals(db, inv.id)).where((a) => a.str('type') == BillingApprovals.discount);
    if (waiting.isNotEmpty) {
      throw ValidationException('A discount on this bill is waiting for approval. Wait for it, or withdraw it to finalise now.');
    }
    final charges = await db.byIds(Col.charges, lines.map((l) => l.strOrNull('charge_id')));
    final ops = <WriteOp>[];
    for (final l in lines) {
      final id = l.strOrNull('charge_id');
      if (id == null) continue;
      final c = charges[id];
      final what = l.str('description');
      if (c == null || c.str('status') == Vals.cancelled) {
        throw ValidationException('$what was cancelled by ${sourceLabel(l.strOrNull('source_module'))}. Remove it first.');
      }
      if (c.strOrNull('invoice_id') != inv.id || c.str('status') != Vals.pending) {
        throw ValidationException('$what is no longer linked to this bill. Remove it and add it again.');
      }
      if (c.integer('amount_paise') != l.integer('amount_paise')) {
        throw ValidationException('$what changed since this draft was made. Update the lines first.');
      }
      ops.add(UpdateOp(Col.charges, c.id, {'status': Vals.billed, 'invoice_id': inv.id}, expectedVersion: c.version));
    }
    final when = at ?? DateTime.now();
    final number = await nextNumber(db, 'invoice', 'INV', when);
    await _write(db, [
      ..._draftOps(inv, keep: lines, extra: {
        'number': number,
        'status': InvoiceStatus.finalised,
        'finalised_at': when,
        'finalised_by': byId ?? db.actor.id,
        'finalised_by_name': byName ?? db.actor.name,
        'bill_date': when,
      }),
      ...ops,
    ]);
    return _invoice(db, inv.id);
  }

  // ------------------------------------------------------------------ payments

  /// Records money received for a final bill. Several entries = a split
  /// payment (e.g. part cash, part UPI). Never more than the balance.
  static Future<List<Rec>> takePayment(Db db, String invoiceId, List<PaymentEntry> entries,
      {DateTime? at, String? byId, String? byName}) async {
    final inv = await _invoice(db, invoiceId);
    if (inv.str('status') != InvoiceStatus.finalised || inv.str('kind') != InvoiceKind.invoice) {
      throw ValidationException(inv.str('status') == InvoiceStatus.draft
          ? 'Finalise the bill before taking payment'
          : 'Payments cannot be taken on this bill');
    }
    final parts = entries.where((e) => e.amountPaise != 0).toList();
    if (parts.isEmpty) throw ValidationException('Enter the amount received');
    var total = 0;
    for (final e in parts) {
      if (e.amountPaise < 0) throw ValidationException('Amounts must be above zero');
      if (!paymentModes.any((m) => m.$1 == e.mode)) throw ValidationException('Choose how the patient paid');
      if (modesNeedingReference.contains(e.mode) && (e.reference ?? '').trim().isEmpty) {
        throw ValidationException('Enter the ${modeLabel(e.mode)} reference number');
      }
      total += e.amountPaise;
    }
    final balance = inv.integer('balance_paise');
    if (balance <= 0) throw ValidationException('Nothing is due on this bill');
    if (total > balance) {
      throw ValidationException('That is ${formatMoney(total - balance)} more than the ${formatMoney(balance)} due');
    }
    final when = at ?? DateTime.now();
    final ops = <WriteOp>[];
    for (final e in parts) {
      ops.add(InsertOp(BillCol.payments, {
        'number': await nextNumber(db, 'receipt', 'RCPT', when),
        'invoice_id': inv.id,
        'invoice_number': inv.str('number'),
        'patient_id': inv.str('patient_id'),
        'patient_name': inv.str('patient_name'),
        'kind': PaymentKind.payment,
        'mode': e.mode,
        'amount_paise': e.amountPaise,
        'reference': (e.reference ?? '').trim().isEmpty ? null : e.reference!.trim(),
        'received_by': byId ?? db.actor.id,
        'received_by_name': byName ?? db.actor.name,
        'received_at': when,
        'notes': e.notes,
      }));
    }
    final paid = inv.integer('paid_paise') + total;
    ops.add(UpdateOp(BillCol.invoices, inv.id, {
      'paid_paise': paid,
      'balance_paise': inv.integer('net_paise') - inv.integer('adjusted_paise') - paid,
    }, expectedVersion: inv.version));
    final out = await db.batch(ops);
    return out.where((r) => r.collection == BillCol.payments).toList();
  }

  // ------------------------------------------------------------------ approvals

  static Future<ApprovalResult> requestDiscount(AppServices app, String invoiceId, int amountPaise, String reason) async {
    final inv = _draft(await _invoice(app.readDb, invoiceId));
    if (amountPaise <= 0) throw ValidationException('Enter a discount above zero');
    final lines = await linesOf(app.readDb, inv.id);
    final base = lines.fold<int>(0, (a, l) => a + math.max(0, l.integer('amount_paise')));
    if (amountPaise > base) throw ValidationException('The discount cannot be more than the bill (${formatMoney(base)})');
    if ((await pendingApprovals(app.readDb, inv.id)).any((a) => a.str('type') == BillingApprovals.discount)) {
      throw ValidationException('A discount for this bill is already waiting for approval');
    }
    final out = await app.approvals.request(
      type: BillingApprovals.discount,
      title: 'Discount of ${formatMoney(amountPaise)} on ${inv.str('number')} · ${inv.str('patient_name')}',
      amountPaise: amountPaise,
      reason: reason,
      subjectCollection: BillCol.invoices,
      subjectId: inv.id,
      patientId: inv.str('patient_id'),
      payload: {'invoice_id': inv.id, 'amount_paise': amountPaise},
    );
    return ApprovalResult(out.approval, applied: out.applied);
  }

  static Future<ApprovalResult> requestRefund(
      AppServices app, String invoiceId, int amountPaise, String mode, String reason) async {
    final inv = await _invoice(app.readDb, invoiceId);
    final max = refundable(inv);
    if (amountPaise <= 0) throw ValidationException('Enter the amount to refund');
    if (max <= 0) throw ValidationException('There is nothing to refund on this bill');
    if (amountPaise > max) throw ValidationException('At most ${formatMoney(max)} can be refunded');
    if ((await pendingApprovals(app.readDb, inv.id)).any((a) => a.str('type') == BillingApprovals.refund)) {
      throw ValidationException('A refund for this bill is already waiting for approval');
    }
    final out = await app.approvals.request(
      type: BillingApprovals.refund,
      title: 'Refund ${formatMoney(amountPaise)} (${modeLabel(mode)}) on ${inv.str('number')} · ${inv.str('patient_name')}',
      amountPaise: amountPaise,
      reason: reason,
      subjectCollection: BillCol.invoices,
      subjectId: inv.id,
      patientId: inv.str('patient_id'),
      payload: {'invoice_id': inv.id, 'amount_paise': amountPaise, 'mode': mode},
    );
    return ApprovalResult(out.approval, applied: out.applied);
  }

  static Future<ApprovalResult> requestCancel(AppServices app, String invoiceId, String reason) async {
    final inv = await _invoice(app.readDb, invoiceId);
    if (inv.str('kind') != InvoiceKind.invoice || inv.str('status') != InvoiceStatus.finalised) {
      throw ValidationException('Only a final bill can be cancelled');
    }
    if ((await pendingApprovals(app.readDb, inv.id)).any((a) => a.str('type') == BillingApprovals.cancel)) {
      throw ValidationException('Cancelling this bill is already waiting for approval');
    }
    final out = await app.approvals.request(
      type: BillingApprovals.cancel,
      title: 'Cancel ${inv.str('number')} (${formatMoney(inv.integer('net_paise'))}) · ${inv.str('patient_name')}',
      amountPaise: math.max(0, inv.integer('net_paise')),
      reason: reason,
      subjectCollection: BillCol.invoices,
      subjectId: inv.id,
      patientId: inv.str('patient_id'),
      payload: {'invoice_id': inv.id},
    );
    return ApprovalResult(out.approval, applied: out.applied);
  }

  static String _invoiceIdOf(Rec approval) =>
      (approval.map('payload')['invoice_id'] as String?) ?? approval.str('subject_id');

  /// Approval handler for `billing.discount`: sets the bill discount.
  static Future<String> applyDiscount(Db db, Rec approval, {DateTime? at}) async {
    final inv = await _invoice(db, _invoiceIdOf(approval));
    if (inv.str('status') != InvoiceStatus.draft) {
      throw ValidationException('${inv.str('number')} was finalised first; a discount can only go on a draft');
    }
    final amount = approval.integer('amount_paise');
    final lines = await linesOf(db, inv.id);
    final base = lines.fold<int>(0, (a, l) => a + math.max(0, l.integer('amount_paise')));
    if (amount > base) throw ValidationException('The discount is more than the bill now is');
    await _write(db, _draftOps(inv, keep: lines, discount: amount, extra: {
      'discount_reason': approval.strOrNull('reason'),
      'discount_by': approval.str('requested_by'),
      'discount_by_name': approval.str('requested_by_name'),
      'discount_at': at ?? approval.createdAt,
      'discount_approval_id': approval.id,
    }));
    return 'Discount of ${formatMoney(amount)} applied to ${inv.str('number')}';
  }

  /// Approval handler for `billing.refund`: pays money back as a new record.
  static Future<String> applyRefund(Db db, Rec approval, {DateTime? at}) async {
    final inv = await _invoice(db, _invoiceIdOf(approval));
    final payload = approval.map('payload');
    final amount = approval.integer('amount_paise');
    final mode = (payload['mode'] as String?) ?? 'cash';
    if (amount > refundable(inv)) {
      throw ValidationException('Only ${formatMoney(refundable(inv))} can be refunded on ${inv.str('number')} now');
    }
    // Returning money the patient paid beyond the bill does not change what
    // the bill is worth; anything more is a reduction of the bill.
    final excess = math.max(0, -inv.integer('balance_paise'));
    final adjust = math.max(0, amount - excess);
    final when = at ?? DateTime.now();
    final number = await nextNumber(db, 'refund', 'RFND', when);
    final paid = inv.integer('paid_paise') - amount;
    final adjusted = inv.integer('adjusted_paise') + adjust;
    await _write(db, [
      InsertOp(BillCol.payments, {
        'number': number,
        'invoice_id': inv.id,
        'invoice_number': inv.str('number'),
        'patient_id': inv.str('patient_id'),
        'patient_name': inv.str('patient_name'),
        'kind': PaymentKind.refund,
        'mode': mode,
        'amount_paise': amount,
        'received_by': approval.str('requested_by'),
        'received_by_name': approval.str('requested_by_name'),
        'received_at': when,
        'approval_id': approval.id,
        'notes': approval.strOrNull('reason'),
      }),
      UpdateOp(BillCol.invoices, inv.id, {
        'paid_paise': paid,
        'refunded_paise': inv.integer('refunded_paise') + amount,
        'adjusted_paise': adjusted,
        'balance_paise': inv.integer('net_paise') - adjusted - paid,
      }, expectedVersion: inv.version),
    ]);
    return 'Refunded ${formatMoney(amount)} by ${modeLabel(mode)} on ${inv.str('number')} ($number)';
  }

  /// Approval handler for `billing.cancel`: the original is marked cancelled
  /// (never edited otherwise), a credit note mirrors its lines with negative
  /// amounts, money received is refunded and the charges go back to
  /// "ready to bill" so they can be billed correctly.
  static Future<String> applyCancel(Db db, Rec approval, {DateTime? at}) async {
    final inv = await _invoice(db, _invoiceIdOf(approval));
    if (inv.str('kind') != InvoiceKind.invoice || inv.str('status') != InvoiceStatus.finalised) {
      throw ValidationException('${inv.str('number')} is not a final bill');
    }
    final when = at ?? DateTime.now();
    final lines = await linesOf(db, inv.id);
    final payments = await paymentsOf(db, inv.id);
    final charges = await db.byIds(Col.charges, lines.map((l) => l.strOrNull('charge_id')));
    final reason = approval.strOrNull('reason');

    // Money still held, refunded the way it came in.
    final heldByMode = <String, int>{};
    for (final p in payments) {
      final sign = p.str('kind') == PaymentKind.refund ? -1 : 1;
      heldByMode[p.str('mode')] = (heldByMode[p.str('mode')] ?? 0) + sign * p.integer('amount_paise');
    }
    var toRefund = math.max(0, inv.integer('paid_paise'));
    final refunds = <(String, int)>[];
    for (final e in heldByMode.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      if (toRefund <= 0 || e.value <= 0) break;
      final r = math.min(toRefund, e.value);
      refunds.add((e.key, r));
      toRefund -= r;
    }
    final refunded = refunds.fold<int>(0, (a, r) => a + r.$2);

    final cnId = db.newId();
    final cnNumber = await nextNumber(db, 'credit_note', 'CN', when);
    final ops = <WriteOp>[
      InsertOp(BillCol.invoices, {
        'number': cnNumber,
        'kind': InvoiceKind.creditNote,
        'credit_note_for': inv.id,
        'patient_id': inv.str('patient_id'),
        'patient_name': inv.str('patient_name'),
        'patient_uhid': inv.str('patient_uhid'),
        'encounter_id': inv.strOrNull('encounter_id'),
        'payer_type': inv.strOrNull('payer_type'),
        'status': InvoiceStatus.finalised,
        'gross_paise': -inv.integer('gross_paise'),
        'discount_paise': -inv.integer('discount_paise'),
        'net_paise': -inv.integer('net_paise'),
        'paid_paise': 0,
        'refunded_paise': 0,
        'adjusted_paise': 0,
        'balance_paise': 0,
        'bill_date': when,
        'finalised_at': when,
        'finalised_by': db.actor.id,
        'finalised_by_name': db.actor.name,
        'cancel_reason': reason,
        'cancel_approval_id': approval.id,
        'notes': 'Cancels ${inv.str('number')}',
      }, id: cnId),
      for (final l in lines)
        InsertOp(BillCol.lines, {
          for (final k in ['patient_id', 'position', 'charge_id', 'source', 'source_module', 'service_code', 'description', 'category', 'quantity', 'unit_price_paise', 'list_price_paise', 'service_date'])
            k: l[k],
          'invoice_id': cnId,
          'amount_paise': -l.integer('amount_paise'),
          'discount_paise': -l.integer('discount_paise'),
          'net_paise': -l.integer('net_paise'),
        }),
    ];
    for (final (mode, amount) in refunds) {
      ops.add(InsertOp(BillCol.payments, {
        'number': await nextNumber(db, 'refund', 'RFND', when),
        'invoice_id': inv.id,
        'invoice_number': inv.str('number'),
        'patient_id': inv.str('patient_id'),
        'patient_name': inv.str('patient_name'),
        'kind': PaymentKind.refund,
        'mode': mode,
        'amount_paise': amount,
        'received_by': approval.str('requested_by'),
        'received_by_name': approval.str('requested_by_name'),
        'received_at': when,
        'approval_id': approval.id,
        'notes': 'Bill cancelled${reason == null ? '' : ': $reason'}',
      }));
    }
    ops.add(UpdateOp(BillCol.invoices, inv.id, {
      'status': InvoiceStatus.cancelled,
      'cancelled_at': when,
      'cancel_reason': reason,
      'cancel_approval_id': approval.id,
      'paid_paise': inv.integer('paid_paise') - refunded,
      'refunded_paise': inv.integer('refunded_paise') + refunded,
      'balance_paise': 0,
    }, expectedVersion: inv.version));
    for (final c in charges.values) {
      if (c.strOrNull('invoice_id') == inv.id && c.str('status') == Vals.billed) {
        ops.add(UpdateOp(Col.charges, c.id, {'status': Vals.pending, 'invoice_id': null}, expectedVersion: c.version));
      }
    }
    await _write(db, ops);
    return 'Cancelled ${inv.str('number')}; credit note $cnNumber issued'
        '${refunded > 0 ? ' and ${formatMoney(refunded)} refunded' : ''}';
  }

  // ------------------------------------------------------------------ day closing

  /// Money a cashier handled on [day], by mode (payments minus refunds).
  static Future<Map<String, int>> expectedByMode(ReadDb db, String userId, DateTime day) async {
    final rows = await db.query(Query(BillCol.payments)
        .eq('received_by', userId)
        .between('received_at', startOfDay(day), endOfDay(day))
        .take(5000));
    final out = <String, int>{};
    for (final p in rows) {
      final sign = p.str('kind') == PaymentKind.refund ? -1 : 1;
      out[p.str('mode')] = (out[p.str('mode')] ?? 0) + sign * p.integer('amount_paise');
    }
    return out;
  }

  /// The cashier counts the drawer. Expected cash comes from the payments
  /// they took; the difference is recorded, never hidden.
  static Future<Rec> closeDay(Db db,
      {required String userId,
      required String userName,
      required DateTime day,
      required int countedCashPaise,
      String? notes,
      DateTime? at}) async {
    if (countedCashPaise < 0) throw ValidationException('Counted cash cannot be negative');
    final expected = await expectedByMode(db, userId, day);
    final cash = expected['cash'] ?? 0;
    final variance = countedCashPaise - cash;
    if (variance.abs() > 10000 && (notes ?? '').trim().isEmpty) {
      throw ValidationException('Explain the difference of ${formatMoney(variance.abs())} in the note');
    }
    return db.insert(BillCol.closings, {
      'closing_date': dayKey(day),
      'user_id': userId,
      'user_name': userName,
      'expected': expected,
      'expected_cash_paise': cash,
      'counted_cash_paise': countedCashPaise,
      'variance_paise': variance,
      'notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
      'closed_at': at ?? DateTime.now(),
    });
  }
}

/// "Rupees One Thousand Two Hundred and Fifty only" for receipts.
String amountInWords(int paise) {
  const ones = [
    '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', //
    'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen',
  ];
  const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  String two(int n) => n < 20 ? ones[n] : '${tens[n ~/ 10]}${n % 10 == 0 ? '' : ' ${ones[n % 10]}'}';
  String three(int n) {
    final h = n ~/ 100;
    final r = n % 100;
    return [if (h > 0) '${ones[h]} Hundred', if (r > 0) two(r)].join(' ');
  }

  final neg = paise < 0;
  var rupees = paise.abs() ~/ 100;
  final p = paise.abs() % 100;
  if (rupees == 0 && p == 0) return 'Rupees Zero only';
  final parts = <String>[];
  final crore = rupees ~/ 10000000;
  rupees %= 10000000;
  final lakh = rupees ~/ 100000;
  rupees %= 100000;
  final thousand = rupees ~/ 1000;
  rupees %= 1000;
  if (crore > 0) parts.add('${crore >= 100 ? three(crore) : two(crore)} Crore');
  if (lakh > 0) parts.add('${two(lakh)} Lakh');
  if (thousand > 0) parts.add('${two(thousand)} Thousand');
  if (rupees > 0) parts.add(three(rupees));
  final words = parts.join(' ');
  final paiseWords = p > 0 ? '${words.isEmpty ? '' : ' and '}${two(p)} Paise' : '';
  return '${neg ? 'Minus ' : ''}${words.isEmpty ? '' : 'Rupees $words'}$paiseWords only';
}

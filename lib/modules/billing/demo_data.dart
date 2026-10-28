import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:kendra_hms/core/core.dart';

import 'billing_schema.dart';
import 'billing_service.dart';

/// General services every hospital charges for. Lab ('LAB-…') and IPD
/// ('BED-…', 'NURSING-…') add their own.
const defaultServices = <(String, String, String, int, String)>[
  ('CONSULT', 'Consultation', Vals.consultation, 50000, 'OPD'),
  ('CONSULT-FU', 'Follow-up consultation', Vals.consultation, 30000, 'OPD'),
  ('REG', 'Registration', Vals.other, 10000, 'Front desk'),
  ('PROC-DRESS', 'Dressing', Vals.procedure, 25000, 'Procedure room'),
  ('PROC-INJ', 'Injection (administration)', Vals.procedure, 10000, 'Procedure room'),
  ('PROC-NEB', 'Nebulisation', Vals.procedure, 20000, 'Procedure room'),
  ('PROC-ECG', 'ECG', Vals.procedure, 30000, 'Cardiology'),
  ('PROC-SUTURE', 'Suturing (minor)', Vals.procedure, 80000, 'Procedure room'),
  ('RAD-XRAY-CHEST', 'X-ray chest PA view', Vals.radiology, 45000, 'Radiology'),
  ('RAD-USG-ABD', 'Ultrasound abdomen', Vals.radiology, 120000, 'Radiology'),
  ('MISC-AMB', 'Ambulance (within city)', Vals.other, 150000, 'Transport'),
];

Future<void> seedPriceList(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final have = {
    for (final s in await db.query(Query(Col.services)
        .isIn('code', [for (final s in defaultServices) s.$1])
        .withArchived()
        .take(defaultServices.length)))
      s.str('code'),
  };
  await db.batch([
    for (final (code, name, category, price, dept) in defaultServices)
      if (!have.contains(code))
        InsertOp(Col.services, {
          'code': code,
          'name': name,
          'category': category,
          'price_paise': price,
          'department': dept,
          'active': true,
        }),
  ]);
}

Future<void> seedBillingDemo(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final users = {for (final u in await db.query(const Query(Col.users).take(200))) u.str('username'): u};
  final cashier = users['billing'];
  final reception = users['reception'];
  if (cashier == null || reception == null) return;
  final settings = ctx.services.settings;
  if (settings.str(SettingKeys.hospitalGstin).isEmpty) {
    await settings.set(db, SettingKeys.hospitalGstin, '27AAHCS4821K1Z6');
  }
  await _Seeder(ctx, db, DateTime.now(), cashier, reception, users['board']).run();
}

// ------------------------------------------------------------------ own charges

/// Things departments charge for, used only when no clinical module posted
/// any charges (e.g. Billing installed on its own).
const _extras = <(String?, String, String, int, String)>[
  ('LAB-CBC', 'Complete blood count (CBC)', Vals.lab, 35000, 'lab'),
  ('PROC-NEB', 'Nebulisation', Vals.procedure, 20000, 'opd'),
  (null, 'Medicines: Paracetamol 650 mg × 10, Pantoprazole 40 mg × 10', Vals.pharmacy, 18600, 'pharmacy'),
  ('RAD-XRAY-CHEST', 'X-ray chest PA view', Vals.radiology, 45000, 'opd'),
  ('LAB-RBS', 'Blood sugar (random)', Vals.lab, 15000, 'lab'),
  ('PROC-INJ', 'Injection (administration)', Vals.procedure, 10000, 'opd'),
  ('PROC-ECG', 'ECG', Vals.procedure, 30000, 'opd'),
  (null, 'Medicines: Amoxicillin 500 mg × 15', Vals.pharmacy, 21000, 'pharmacy'),
  ('PROC-DRESS', 'Dressing', Vals.procedure, 25000, 'opd'),
  ('LAB-LFT', 'Liver function test', Vals.lab, 65000, 'lab'),
  ('RAD-USG-ABD', 'Ultrasound abdomen', Vals.radiology, 120000, 'opd'),
];

Future<void> _seedOwnVisits(Db db, DateTime now, List<DateTime> visits, {int patientOffset = 0, bool closeAll = false}) async {
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(40));
  final doctors = await db.query(const Query(Col.users).eq('is_clinician', true).sort('username').take(10));
  if (patients.isEmpty) return;
  final ops = <WriteOp>[];
  final registered = <String>{};
  for (final (i, at) in visits.indexed) {
    final p = patients[(i + patientOffset) % patients.length];
    final doctor = doctors.isEmpty ? null : doctors[i % doctors.length];
    final encId = db.newId();
    final today = !at.isBefore(startOfDay(now));
    final open = !closeAll && (today || i == 7);
    ops.add(InsertOp(Col.encounters, {
      'patient_id': p.id,
      'type': Vals.opd,
      'status': open ? Vals.open : Vals.closed,
      'doctor_id': doctor?.id,
      'department': doctor?.strOrNull('department') ?? 'General Medicine',
      'started_at': at,
      'ended_at': open ? null : at.add(const Duration(minutes: 40)),
      'queue_status': Vals.done,
      'summary': 'Out-patient visit',
    }, id: encId));
    void charge(String? code, String desc, String cat, int price, String source, {Duration after = Duration.zero}) {
      final when = at.add(after);
      ops.add(InsertOp(Col.charges, {
        'patient_id': p.id,
        'encounter_id': encId,
        'service_code': code,
        'description': desc,
        'category': cat,
        'quantity': 1,
        'unit_price_paise': price,
        'amount_paise': price,
        'source_module': source,
        'source_collection': 'demo',
        'source_id': '$encId:${ops.length}',
        'status': Vals.pending,
        'service_date': when.isAfter(now) ? now.subtract(const Duration(minutes: 1)) : when,
        'ordered_by': doctor?.id,
      }));
    }

    if (registered.add(p.id) && i % 3 == 0) charge('REG', 'Registration', Vals.other, 10000, 'patients');
    if (i % 4 == 3) {
      charge('CONSULT-FU', 'Follow-up consultation', Vals.consultation, 30000, 'opd', after: const Duration(minutes: 10));
    } else {
      charge('CONSULT', 'Consultation — ${doctor?.str('display_name') ?? 'Duty doctor'}', Vals.consultation,
          doctor?.intOrNull('consultation_fee_paise') ?? 50000, 'opd', after: const Duration(minutes: 10));
    }
    final extras = i % 3 + (i % 5 == 0 ? 1 : 0);
    for (var k = 0; k < extras; k++) {
      final e = _extras[(i * 3 + k) % _extras.length];
      charge(e.$1, e.$2, e.$3, e.$4, e.$5, after: Duration(minutes: 25 + 15 * k));
    }
  }
  await db.batch(ops);
}

// ------------------------------------------------------------------ billing history

class _Group {
  _Group(this.charges, this.encounter);
  final List<Rec> charges;
  final Rec? encounter;
  String get patientId => charges.first.str('patient_id');
  DateTime get latest =>
      charges.map((c) => c.date('service_date') ?? c.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
  int get gross => charges.fold<int>(0, (a, c) => a + c.integer('amount_paise'));
}

class _Plan {
  (String, int)? manual; // service code, rate
  int discount = 0;
  String discountKind = 'approved'; // approved | unauthorised
  String discountReason = 'Senior citizen';
  Rec? cashier;
  DateTime? at;
  double payShare = 1;
  (int, bool)? refund; // amount, needs board
  String? mode;
}

class _Seeder {
  _Seeder(this.ctx, this.db, this.now, this.cashier, this.reception, this.board);
  final ModuleContext ctx;
  final Db db;
  final DateTime now;
  final Rec cashier;
  final Rec reception;
  final Rec? board;
  final rnd = Random(31);
  late final Map<String, Rec> services;
  late final Map<String, Rec> patients;

  DateTime get today => startOfDay(now);
  int ageDays(_Group g) => today.difference(startOfDay(g.latest)).inDays;

  Future<void> run() async {
    if (await db.count(const Query(Col.charges)) == 0) {
      await _seedOwnVisits(db, now, [
        for (final m in [230, 170, 125, 80, 40, 15]) now.subtract(Duration(minutes: m)),
        for (final (d, h, mi) in const [
          (1, 10, 10), (1, 16, 40), (2, 11, 25), (3, 10, 50), (3, 12, 35), (4, 11, 5), (5, 15, 25), (6, 10, 35), //
          (8, 12, 5), (9, 17, 20), (10, 11, 45), (13, 10, 20), (16, 16, 55), (20, 11, 30), (27, 12, 15), (34, 10, 40),
          (45, 11, 10), (58, 15, 0),
        ])
          today.subtract(Duration(days: d)).add(Duration(hours: h, minutes: mi)),
      ]);
    }
    services = {for (final s in await db.query(const Query(Col.services).take(2000))) s.str('code'): s};

    final pending = await db.query(BillingService.unbilledCharges().sort('service_date').take(5000));
    final encounters = await db.byIds(Col.encounters, pending.map((c) => c.strOrNull('encounter_id')));
    patients = await db.byIds(Col.patients, pending.map((c) => c.str('patient_id')));

    // One group per visit, split into what happened before today and today.
    final older = <String, List<Rec>>{};
    final todays = <String, List<Rec>>{};
    for (final c in pending) {
      if (!patients.containsKey(c.str('patient_id'))) continue;
      final enc = encounters[c.strOrNull('encounter_id')];
      // Patients still in the ward are billed at discharge.
      if (enc != null && enc.str('type') == Vals.ipd && enc.str('status') == Vals.open) continue;
      final when = c.date('service_date') ?? c.createdAt;
      final key = c.strOrNull('encounter_id') ?? '${c.str('patient_id')}|${dayKey(when)}';
      (when.isBefore(today) ? older : todays).putIfAbsent(key, () => []).add(c);
    }
    _Group group(List<Rec> cs) => _Group(cs, encounters[cs.first.strOrNull('encounter_id')]);
    final past = [for (final cs in older.values) group(cs)]..sort((a, b) => a.latest.compareTo(b.latest));
    final current = [for (final cs in todays.values) group(cs)]..sort((a, b) => a.latest.compareTo(b.latest));

    // Left unbilled on purpose: a closed visit from about 3 days ago (the
    // bill-matching agent reports it as leakage) and one visit still open.
    final used = <_Group>{};
    final leak = _pick(past, 3, used, tolerance: 3, where: (g) => g.encounter?.str('status') == Vals.closed && ageDays(g) >= 2);
    if (leak == null) {
      await _seedOwnVisits(db, now, [today.subtract(const Duration(days: 3)).add(const Duration(hours: 11, minutes: 15))],
          patientOffset: 17, closeAll: true);
    }
    _pick(past, 1, used, tolerance: 2, where: (g) => g.encounter?.str('status') == Vals.open);

    // Stories the agents and screens should show.
    final plans = <_Group, _Plan>{};
    _Plan plan(_Group g) => plans.putIfAbsent(g, _Plan.new);
    void at(int days, void Function(_Plan p, _Group g) f, {int tolerance = 3, bool Function(_Group)? where}) {
      final g = _pick(past, days, used, tolerance: tolerance, where: where);
      if (g != null) f(plan(g), g);
    }

    bool paidOnly(_Group g) => (patients[g.patientId]?.str('payer_type', 'self') ?? 'self') == 'self';
    at(6, (p, g) => p.manual = ('PROC-DRESS', 15000)); // dressing at ₹150 instead of ₹250
    at(8, (p, g) => p.manual = ('RAD-XRAY-CHEST', 45000)); // an X-ray nobody ordered
    at(4, (p, g) {
      p.discount = 30000;
      p.discountKind = 'unauthorised';
      p.discountReason = 'Known to staff';
      p.cashier = reception;
      final night = DateTime(g.latest.year, g.latest.month, g.latest.day, 22, 40);
      if (night.isAfter(g.latest) && night.isBefore(now)) p.at = night;
    });
    at(10, (p, g) => p.payShare = 0.4, where: paidOnly);
    // Vikram's discounts: small ones now and then, then a busy week.
    for (final (days, amount, reason) in const [
      (1, 50000, 'Senior citizen'),
      (3, 40000, 'Rounding off'),
      (5, 120000, 'Financial hardship'),
      (12, 20000, 'Senior citizen'),
      (19, 15000, 'Rounding off'),
      (26, 25000, 'Staff or family'),
      (33, 10000, 'Rounding off'),
      (40, 20000, 'Senior citizen'),
      (54, 100000, "Doctor's advice"),
    ]) {
      at(days, (p, g) {
        p.discount = amount;
        p.discountReason = reason;
        p.cashier = cashier;
      }, tolerance: 2, where: (g) => g.gross >= 30000);
    }
    // Refunds can sit on any fully paid bill, including discounted ones.
    final leftAlone = {for (final g in used) if (!plans.containsKey(g)) g};
    bool ordinary(_Group g) =>
        paidOnly(g) &&
        !leftAlone.contains(g) &&
        (plans[g]?.payShare ?? 1) >= 1 &&
        plans[g]?.discountKind != 'unauthorised' &&
        plans[g]?.refund == null;
    _Group? near(int days, bool Function(_Group) ok) {
      _Group? best;
      for (final g in past.where(ok)) {
        if (best == null || (ageDays(g) - days).abs() < (ageDays(best) - days).abs()) best = g;
      }
      return best;
    }

    final small = near(5, ordinary);
    if (small != null) {
      plan(small)
        ..refund = (20000, false)
        ..cashier = cashier;
    }
    final large = near(2, ordinary);
    if (large != null) {
      plan(large)
        ..refund = (80000, true)
        ..cashier = reception;
    }
    // A recent bill paid in cash at the main counter, so the day-end count
    // has real cash to be short of.
    final cashBill = near(3, (g) => ordinary(g) && ageDays(g) >= 1 && ageDays(g) <= 6 && plans[g]?.cashier != reception);
    if (cashBill != null) {
      plan(cashBill)
        ..cashier = cashier
        ..mode = 'cash';
    }

    for (final (i, g) in past.indexed) {
      if (used.contains(g) && !plans.containsKey(g)) continue; // left pending on purpose
      await _guard(() => _bill(g, plans[g] ?? _Plan(), i));
    }

    // Today: a few bills done this morning, the rest waiting at the counter,
    // and one draft whose discount waits for the board.
    final waitingCount = min(current.length, 4);
    final billNow = current.take(current.length - waitingCount).take(4).toList();
    for (final (i, g) in billNow.indexed) {
      if (now.difference(g.latest) < const Duration(minutes: 30)) continue;
      final p = _Plan()..payShare = i == billNow.length - 1 ? 0 : 1;
      await _guard(() => _bill(g, p, i));
    }
    final waiting = current.skip(billNow.length).toList();
    if (waiting.length >= 2) {
      final g = waiting.reduce((a, b) => a.gross >= b.gross ? a : b);
      await _guard(() => _pendingDiscountDraft(g));
    }

    await _guard(_closings);
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e, st) {
      debugPrint('billing demo: $e\n$st');
    }
  }

  _Group? _pick(List<_Group> list, int days, Set<_Group> used, {int tolerance = 3, bool Function(_Group)? where}) {
    _Group? best;
    var bestD = 1 << 30;
    for (final g in list) {
      if (used.contains(g) || !(where?.call(g) ?? true)) continue;
      final d = (ageDays(g) - days).abs();
      if (d < bestD) {
        best = g;
        bestD = d;
      }
    }
    if (best == null || bestD > tolerance) return null;
    used.add(best);
    return best;
  }

  String _ref(String mode) => switch (mode) {
        'upi' => '${400000000000 + rnd.nextInt(99999999)}',
        'card' => 'APPR ${100000 + rnd.nextInt(899999)}',
        'cheque' => 'CHQ ${200000 + rnd.nextInt(799999)} · HDFC Bank',
        'insurance' => 'CLM-${2600000 + rnd.nextInt(99999)}',
        _ => '',
      };

  Future<Rec> _approval({
    required String type,
    required String title,
    required int amount,
    required Rec requester,
    required bool needsBoard,
    required Rec inv,
    required String reason,
    required DateTime at,
    required Map<String, Object?> payload,
    String status = 'approved',
  }) =>
      db.insert(Col.approvals, {
        'type': type,
        'status': status,
        'title': title,
        'amount_paise': amount,
        'requested_by': requester.id,
        'requested_by_name': requester.str('display_name'),
        'reason': reason,
        'subject_collection': BillCol.invoices,
        'subject_id': inv.id,
        'patient_id': inv.str('patient_id'),
        'payload': payload,
        'required_approvals': needsBoard ? 1 : 0,
        'approvers': [
          if (needsBoard && board != null && status != 'pending')
            {'user_id': board!.id, 'name': board!.str('display_name'), 'at': at.toIso8601String(), 'note': 'Approved'},
        ],
        'auto_approved': !needsBoard,
        if (status != 'pending') 'decided_at': at,
      });

  Future<void> _bill(_Group g, _Plan plan, int index) async {
    final by = plan.cashier ?? (index % 5 < 3 ? cashier : reception);
    var at = plan.at ?? g.latest.add(Duration(minutes: 15 + rnd.nextInt(50)));
    if (at.isAfter(now)) at = now.subtract(const Duration(minutes: 2));
    final draft = await BillingService.createDraft(db, g.patientId, charges: g.charges, at: at.subtract(const Duration(minutes: 6)));
    final manual = plan.manual;
    if (manual != null && services[manual.$1] != null) {
      await BillingService.addManualLine(db, draft.id,
          service: services[manual.$1]!, unitPricePaise: manual.$2, at: at.subtract(const Duration(minutes: 4)));
    }
    if (plan.discount > 0) {
      final inv = (await db.get(BillCol.invoices, draft.id))!;
      final cap = (inv.integer('gross_paise') * 0.35).floor() ~/ 1000 * 1000;
      final amount = min(plan.discount, cap);
      final givenAt = at.subtract(const Duration(minutes: 3));
      if (amount >= 5000 && plan.discountKind == 'unauthorised') {
        // Typed straight onto the bill, with no approval behind it.
        await db.update(BillCol.invoices, inv.id, {
          'discount_paise': amount,
          'discount_by': by.id,
          'discount_by_name': by.str('display_name'),
          'discount_at': givenAt,
          'discount_reason': plan.discountReason,
        });
      } else if (amount >= 5000) {
        final needsBoard = amount > by.integer('discount_limit_paise');
        final a = await _approval(
          type: BillingApprovals.discount,
          title: 'Discount of ${formatMoney(amount)} on ${inv.str('number')} · ${inv.str('patient_name')}',
          amount: amount,
          requester: by,
          needsBoard: needsBoard,
          inv: inv,
          reason: plan.discountReason,
          at: givenAt,
          payload: {'invoice_id': inv.id, 'amount_paise': amount},
        );
        final result = await BillingService.applyDiscount(db, a, at: givenAt);
        await db.update(Col.approvals, a.id, {'status': 'applied', 'result': result});
      }
    }
    final fin = await BillingService.finalise(db, draft.id, at: at, byId: by.id, byName: by.str('display_name'));
    final due = fin.integer('balance_paise');
    final payer = patients[g.patientId]?.str('payer_type', 'self') ?? 'self';
    final payAt = at.add(Duration(minutes: 1 + rnd.nextInt(4)));
    var paidBy = 'cash';
    if (due > 0 && plan.payShare > 0) {
      // Insurance and company bills are often settled later.
      final credit = payer != 'self' && rnd.nextInt(3) == 0;
      if (!credit) {
        final amount = plan.payShare >= 1 ? due : (due * plan.payShare).round() ~/ 10000 * 10000;
        const mix = ['cash', 'upi', 'cash', 'card', 'upi', 'cash', 'upi'];
        final mode = plan.mode ??
            switch (payer) {
              'insurance' => 'insurance',
              'corporate' => 'cheque',
              _ => mix[index % mix.length],
            };
        final entries = payer == 'self' && plan.mode == null && index % 9 == 4 && amount >= 40000
            ? [
                PaymentEntry('cash', amount ~/ 20000 * 10000),
                PaymentEntry('upi', amount - amount ~/ 20000 * 10000, reference: _ref('upi')),
              ]
            : [PaymentEntry(mode, amount, reference: _ref(mode))];
        if (amount > 0) {
          await BillingService.takePayment(db, fin.id, entries, at: payAt, byId: by.id, byName: by.str('display_name'));
          paidBy = entries.last.mode;
        }
      }
    }
    final refund = plan.refund;
    if (refund != null) {
      final inv = (await db.get(BillCol.invoices, fin.id))!;
      final amount = min(refund.$1, BillingService.refundable(inv));
      if (amount > 0) {
        var when = payAt.add(const Duration(hours: 3));
        if (when.isAfter(now)) when = now.subtract(const Duration(minutes: 1));
        final reason = refund.$2 ? 'Service not given' : 'Medicines returned';
        final a = await _approval(
          type: BillingApprovals.refund,
          title: 'Refund ${formatMoney(amount)} (${modeLabel(paidBy)}) on ${inv.str('number')} · ${inv.str('patient_name')}',
          amount: amount,
          requester: by,
          needsBoard: refund.$2,
          inv: inv,
          reason: reason,
          at: when,
          payload: {'invoice_id': inv.id, 'amount_paise': amount, 'mode': paidBy},
        );
        final result = await BillingService.applyRefund(db, a, at: when);
        await db.update(Col.approvals, a.id, {'status': 'applied', 'result': result});
      }
    }
  }

  Future<void> _pendingDiscountDraft(_Group g) async {
    final draft = await BillingService.createDraft(db, g.patientId,
        charges: g.charges, at: now.subtract(const Duration(minutes: 18)));
    final gross = draft.integer('gross_paise');
    final amount = max(10000, (gross * 0.25).floor() ~/ 1000 * 1000);
    if (amount > gross) return;
    final by = amount > cashier.integer('discount_limit_paise') ? cashier : reception;
    final title = 'Discount of ${formatMoney(amount)} on ${draft.str('number')} · ${draft.str('patient_name')}';
    final a = await _approval(
      type: BillingApprovals.discount,
      title: title,
      amount: amount,
      requester: by,
      needsBoard: true,
      inv: draft,
      reason: 'Financial hardship',
      at: now,
      payload: {'invoice_id': draft.id, 'amount_paise': amount},
      status: 'pending',
    );
    await ctx.services.notifications.notifyPermission(
      db,
      permission: CorePerms.approvalsDecide,
      title: 'Approval needed: $title',
      body: '${by.str('display_name')} asked. Financial hardship',
      severity: 'medium',
      kind: 'approval',
      routeId: 'tower.approvals',
      routeArgs: {'id': a.id},
      exceptUserId: by.id,
    );
  }

  /// A week of end-of-day cash counts; one came up ₹600 short.
  Future<void> _closings() async {
    final days = [for (var d = 1; d <= 7; d++) today.subtract(Duration(days: d))];
    final counts = <(Rec, DateTime, int)>[];
    for (final day in days) {
      for (final u in [cashier, reception]) {
        final expected = await BillingService.expectedByMode(db, u.id, day);
        if (expected.isEmpty && u.id != cashier.id) continue;
        // A counter that paid out more cash than it took kept no drawer.
        if ((expected['cash'] ?? 0) < 0) continue;
        counts.add((u, day, expected['cash'] ?? 0));
      }
    }
    if (counts.isEmpty) return;
    // The short day is the busiest cash day at the main counter.
    var short = 0;
    for (var i = 1; i < counts.length; i++) {
      final a = counts[short];
      final b = counts[i];
      final aMain = a.$1.id == cashier.id;
      final bMain = b.$1.id == cashier.id;
      if ((bMain && !aMain) || (bMain == aMain && b.$3 > a.$3)) short = i;
    }
    for (final (i, c) in counts.indexed) {
      final (u, day, cash) = c;
      var variance = 0;
      String? note;
      if (i == short && cash >= 60000) {
        variance = -60000;
        note = 'Counted twice, ₹600 short. Could not trace it.';
      } else if (u.id == reception.id && i % 4 == 1 && cash > 0) {
        variance = 5000;
        note = 'Extra ₹50 — change probably not given back';
      }
      await _guard(() => BillingService.closeDay(db,
          userId: u.id,
          userName: u.str('display_name'),
          day: day,
          countedCashPaise: cash + variance,
          notes: note,
          at: day.add(Duration(hours: 19, minutes: 5 + i * 3))));
    }
  }
}

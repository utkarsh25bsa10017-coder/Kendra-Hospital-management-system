import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/billing/agents/bill_matching_agent.dart';
import 'package:kendra_hms/modules/billing/agents/cash_variance_agent.dart';
import 'package:kendra_hms/modules/billing/agents/discount_patterns_agent.dart';
import 'package:kendra_hms/modules/billing/agents/unpaid_bills_agent.dart';
import 'package:kendra_hms/modules/billing/billing_module.dart';
import 'package:kendra_hms/modules/billing/billing_schema.dart';
import 'package:kendra_hms/modules/billing/billing_service.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

Future<Rec> _patient(AppServices app, String name) => app.systemDb
    .insert(Col.patients, {'uhid': 'TH-${name.toUpperCase()}', 'first_name': name, 'full_name': name, 'payer_type': 'self'});

Future<Rec> _encounter(AppServices app, Rec p, {required bool closed, required DateTime at}) =>
    app.systemDb.insert(Col.encounters, {
      'patient_id': p.id,
      'type': Vals.opd,
      'status': closed ? Vals.closed : Vals.open,
      'started_at': at,
    });

Future<Rec> _charge(AppServices app, Rec p, String desc, int amount,
        {String? code, String category = Vals.lab, String? encounterId, DateTime? at}) =>
    app.systemDb.insert(Col.charges, {
      'patient_id': p.id,
      'encounter_id': encounterId,
      'service_code': code,
      'description': desc,
      'category': category,
      'quantity': 1,
      'unit_price_paise': amount,
      'amount_paise': amount,
      'status': Vals.pending,
      'source_module': 'opd',
      'service_date': at ?? DateTime.now(),
    });

Future<List<FindingDraft>> _run(AppServices app, HmsAgent agent, {DateTime? now}) async =>
    (await agent.run(AgentContext(db: app.readDb, settings: app.settings, now: now))).findings;

void main() {
  test('bill matching flags price deviation, overbilling and unauthorised discounts', () async {
    final app = await bootTestHospital([PatientsModule(), BillingModule()]);
    await addUser(app, 'cashier', [Roles.billing], extra: {'discount_limit_paise': 50000});
    await signIn(app, 'cashier');
    final dressing = (await app.readDb.first(const Query(Col.services).eq('code', 'PROC-DRESS')))!;
    final xray = (await app.readDb.first(const Query(Col.services).eq('code', 'RAD-XRAY-CHEST')))!;

    // A dressing at ₹150 instead of ₹250, and an X-ray nobody did.
    final p = await _patient(app, 'Meena');
    await _charge(app, p, 'Consultation', 50000, code: 'CONSULT', category: Vals.consultation);
    final d = await BillingService.createDraft(app.db, p.id);
    await BillingService.addManualLine(app.db, d.id, service: dressing, unitPricePaise: 15000);
    await BillingService.addManualLine(app.db, d.id, service: xray);
    final bill = await BillingService.finalise(app.db, d.id);
    final lines = await BillingService.linesOf(app.readDb, bill.id);
    final dressLine = lines.firstWhere((l) => l.str('service_code') == 'PROC-DRESS');
    final xrayLine = lines.firstWhere((l) => l.str('service_code') == 'RAD-XRAY-CHEST');

    // A discount typed onto the bill with no approval, next to a properly approved one.
    final q = await _patient(app, 'Deepak');
    await _charge(app, q, 'Consultation', 50000, code: 'CONSULT', category: Vals.consultation);
    final d2 = await BillingService.createDraft(app.db, q.id);
    await app.systemDb.update(BillCol.invoices, d2.id, {'discount_paise': 20000, 'discount_by_name': 'Priya Sharma'});
    final sneaky = await BillingService.finalise(app.db, d2.id);
    final r = await _patient(app, 'Karthik');
    await _charge(app, r, 'Consultation', 50000, code: 'CONSULT', category: Vals.consultation);
    final d3 = await BillingService.createDraft(app.db, r.id);
    await BillingService.requestDiscount(app, d3.id, 10000, 'Senior citizen');
    final honest = await BillingService.finalise(app.db, d3.id);

    var found = {for (final f in await _run(app, BillMatchingAgent())) f.key: f};
    final price = found['line:${dressLine.id}:price'];
    expect(price, isNotNull);
    expect(price!.amountAtRiskPaise, 10000);
    expect(price.severity, Severity.medium, reason: '40% below the list price');
    expect(price.evidence.first.routeId, 'billing.invoice');
    expect(found['line:${xrayLine.id}'], isNotNull, reason: 'X-ray with no order or charge behind it');
    expect(found['line:${xrayLine.id}']!.title, startsWith('Possible overbilling'));
    expect(found['line:${dressLine.id}'], isNotNull, reason: 'the dressing has no record either');
    final unauth = found['invoice:${sneaky.id}:discount'];
    expect(unauth, isNotNull);
    expect(unauth!.severity, Severity.high);
    expect(unauth.amountAtRiskPaise, 20000);
    expect(found.containsKey('invoice:${honest.id}:discount'), isFalse);
    expect(found.keys.where((k) => k.startsWith('line:') && k.endsWith(':price')), hasLength(1),
        reason: 'lines at the list price are fine');

    // Once the X-ray turns up in the radiology records, it stops being flagged.
    await app.systemDb.insert(Col.serviceOrders, {
      'patient_id': p.id,
      'order_type': Vals.radiology,
      'service_code': 'RAD-XRAY-CHEST',
      'name': 'X-ray chest',
      'status': Vals.verified,
      'ordered_at': DateTime.now().subtract(const Duration(hours: 1)),
      'charge_id': 'external',
    });
    found = {for (final f in await _run(app, BillMatchingAgent())) f.key: f};
    expect(found.containsKey('line:${xrayLine.id}'), isFalse);
    await app.close();
  });

  test('bill matching finds work that was done but never billed', () async {
    final app = await bootTestHospital([PatientsModule(), BillingModule()]);
    final now = DateTime.now();
    final p = await _patient(app, 'Sunita');
    final closed = await _encounter(app, p, closed: true, at: now.subtract(const Duration(days: 3)));
    final open = await _encounter(app, p, closed: false, at: now.subtract(const Duration(days: 3)));
    final leaked = await _charge(app, p, 'ECG', 30000,
        code: 'PROC-ECG', category: Vals.procedure, encounterId: closed.id, at: now.subtract(const Duration(days: 3)));
    final stillOpen = await _charge(app, p, 'Dressing', 25000,
        encounterId: open.id, category: Vals.procedure, at: now.subtract(const Duration(days: 3)));
    final fresh = await _charge(app, p, 'CBC', 35000, encounterId: closed.id, at: now.subtract(const Duration(hours: 3)));
    final orphan = await _charge(app, p, 'Ambulance', 150000, category: Vals.other, at: now.subtract(const Duration(days: 2)));
    final order = await app.systemDb.insert(Col.serviceOrders, {
      'patient_id': p.id,
      'encounter_id': closed.id,
      'order_type': Vals.lab,
      'service_code': 'LAB-TSH',
      'name': 'Thyroid profile',
      'status': Vals.resulted,
      'ordered_at': now.subtract(const Duration(days: 1)),
      'resulted_at': now.subtract(const Duration(hours: 20)),
    });
    final rx = await app.systemDb.insert(Col.prescriptions, {
      'patient_id': p.id,
      'encounter_id': closed.id,
      'items': [
        {'drug_name': 'Dolo 650', 'quantity': 10},
      ],
      'status': Vals.dispensed,
      'dispensed_at': now.subtract(const Duration(days: 1)),
    });

    final found = {for (final f in await _run(app, BillMatchingAgent())) f.key: f};
    final leak = found['charge:${leaked.id}'];
    expect(leak, isNotNull);
    expect(leak!.amountAtRiskPaise, 30000);
    expect(leak.summary, contains('never billed'));
    expect(found['charge:${orphan.id}'], isNotNull, reason: 'no visit at all, two days later');
    expect(found['charge:${orphan.id}']!.severity, Severity.medium);
    expect(found.containsKey('charge:${stillOpen.id}'), isFalse, reason: 'the visit is still open');
    expect(found.containsKey('charge:${fresh.id}'), isFalse, reason: 'less than a day old');
    expect(found['order:${order.id}'], isNotNull, reason: 'a result with no charge');
    expect(found['rx:${rx.id}'], isNotNull, reason: 'medicines dispensed with no pharmacy charge');

    // Billing the ECG clears that finding.
    await addUser(app, 'cashier', [Roles.billing]);
    await signIn(app, 'cashier');
    final d = await BillingService.createDraft(app.db, p.id, charges: [leaked]);
    await BillingService.finalise(app.db, d.id);
    final again = {for (final f in await _run(app, BillMatchingAgent())) f.key: f};
    expect(again.containsKey('charge:${leaked.id}'), isFalse);
    await app.close();
  });

  test('cash variance, unpaid bills and discount patterns', () async {
    final app = await bootTestHospital([PatientsModule(), BillingModule()]);
    final now = DateTime.now();
    final db = app.systemDb;
    final user = await addUser(app, 'cashier', [Roles.billing]);
    for (final (v, day) in [(-60000, 1), (-250000, 2), (-5000, 3)]) {
      await db.insert(BillCol.closings, {
        'closing_date': dayKey(now.subtract(Duration(days: day))),
        'user_id': user.id,
        'user_name': 'Cashier',
        'expected_cash_paise': 500000,
        'counted_cash_paise': 500000 + v,
        'variance_paise': v,
        'closed_at': now.subtract(Duration(days: day)),
      });
    }
    final cash = await _run(app, CashVarianceAgent());
    expect(cash.map((f) => f.severity).toList()..sort((a, b) => a.index.compareTo(b.index)), [Severity.medium, Severity.high]);
    expect(cash.firstWhere((f) => f.severity == Severity.medium).title, contains('short by ₹600'));

    // A bill from ten days ago that is still half unpaid.
    await signIn(app, 'cashier');
    final p = await _patient(app, 'Vivek');
    await _charge(app, p, 'Ultrasound', 120000, category: Vals.radiology, at: now.subtract(const Duration(days: 10)));
    final d = await BillingService.createDraft(app.db, p.id);
    final fin = await BillingService.finalise(app.db, d.id, at: now.subtract(const Duration(days: 10)));
    await BillingService.takePayment(app.db, fin.id, [const PaymentEntry('cash', 60000)]);
    final unpaid = await _run(app, UnpaidBillsAgent());
    expect(unpaid.single.key, 'unpaid:${dayKey(now).replaceAll('-', '')}');
    expect(unpaid.single.amountAtRiskPaise, 60000);
    expect(unpaid.single.severity, Severity.low);

    // Discounts: a small one most weeks, then a burst, one of them at night.
    Future<void> discounted(int amount, DateTime at) => db.insert(BillCol.invoices, {
          'number': 'INV-T-${at.millisecondsSinceEpoch}-$amount',
          'kind': InvoiceKind.invoice,
          'patient_id': p.id,
          'patient_name': 'Vivek',
          'status': InvoiceStatus.finalised,
          'gross_paise': 500000,
          'discount_paise': amount,
          'net_paise': 500000 - amount,
          'balance_paise': 0,
          'finalised_at': at,
          'discount_by': user.id,
          'discount_by_name': 'Cashier',
          'discount_at': at,
        });
    for (var w = 2; w <= 13; w++) {
      await discounted(10000 + (w % 3) * 5000, DateTime(now.year, now.month, now.day, 11).subtract(Duration(days: 7 * w)));
    }
    await discounted(150000, now.subtract(const Duration(days: 2)));
    await discounted(90000, DateTime(now.year, now.month, now.day, 23, 10).subtract(const Duration(days: 3)));
    final patterns = {for (final f in await _run(app, DiscountPatternsAgent())) f.key: f};
    expect(patterns['user:${user.id}'], isNotNull);
    expect(patterns['user:${user.id}']!.severity, Severity.medium);
    expect(patterns['user:${user.id}']!.subjectKey, 'user:${user.id}');
    expect(patterns['night:${user.id}'], isNotNull);
    expect(patterns['night:${user.id}']!.severity, Severity.low);
    await app.close();
  });

  test('the demo hospital has a story for every screen and agent', () async {
    final app = await bootTestHospital([PatientsModule(), BillingModule()], demo: true);
    final db = app.readDb;
    final finals = await db.count(const Query(BillCol.invoices).eq('kind', InvoiceKind.invoice).eq('status', InvoiceStatus.finalised));
    expect(finals, greaterThan(12));
    expect(await db.count(const Query(BillCol.invoices).eq('status', InvoiceStatus.draft)), greaterThan(0));
    expect(await db.count(const Query(Col.approvals).eq('type', BillingApprovals.discount).eq('status', 'pending')), 1);
    expect(await db.count(const Query(Col.approvals).eq('type', BillingApprovals.discount).eq('status', 'applied')), greaterThan(3));
    expect(await db.count(const Query(BillCol.payments).eq('kind', PaymentKind.refund)), 2);
    expect(await db.count(const Query(BillCol.closings)), greaterThanOrEqualTo(7));
    expect((await BillingService.readyToBill(db)).length, greaterThanOrEqualTo(2));
    final modes = {for (final p in await db.query(const Query(BillCol.payments).take(2000))) p.str('mode')};
    expect(modes, containsAll(['cash', 'upi', 'card']));

    final matching = await _run(app, BillMatchingAgent());
    expect(matching.where((f) => f.title.startsWith('Leakage')), isNotEmpty);
    expect(matching.where((f) => f.title.startsWith('Price deviation')), isNotEmpty);
    expect(matching.where((f) => f.title.startsWith('Unauthorised discount')), hasLength(1));
    expect(matching.where((f) => f.title.startsWith('Possible overbilling')), isNotEmpty);
    expect((await _run(app, CashVarianceAgent())).where((f) => f.amountAtRiskPaise == 60000), hasLength(1));
    expect(await _run(app, UnpaidBillsAgent()), hasLength(1));
    final patterns = await _run(app, DiscountPatternsAgent());
    expect(patterns.where((f) => f.key.startsWith('night:')), isNotEmpty);
    await app.close();
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/billing/billing_module.dart';
import 'package:kendra_hms/modules/billing/billing_schema.dart';
import 'package:kendra_hms/modules/billing/billing_service.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

Future<AppServices> _hospital() async {
  final app = await bootTestHospital([PatientsModule(), BillingModule()]);
  await addUser(app, 'cashier', [Roles.billing], extra: {'discount_limit_paise': 50000});
  await addUser(app, 'board1', [Roles.board]);
  return app;
}

Future<Rec> _patient(AppServices app, String name) => app.systemDb
    .insert(Col.patients, {'uhid': 'TH-${name.toUpperCase()}', 'first_name': name, 'full_name': name, 'payer_type': 'self'});

Future<Rec> _charge(AppServices app, Rec p, String desc, int amount,
        {String? code, String category = Vals.lab, String? encounterId, DateTime? at, int qty = 1}) =>
    app.systemDb.insert(Col.charges, {
      'patient_id': p.id,
      'encounter_id': encounterId,
      'service_code': code,
      'description': desc,
      'category': category,
      'quantity': qty,
      'unit_price_paise': amount ~/ qty,
      'amount_paise': amount,
      'status': Vals.pending,
      'source_module': 'lab',
      'service_date': at ?? DateTime.now(),
    });

Future<Rec> _inv(AppServices app, String id) async => (await app.readDb.get(BillCol.invoices, id))!;

/// A final bill of ₹1,000 for a new patient, made by the cashier.
Future<Rec> _finalBill(AppServices app, String name) async {
  final p = await _patient(app, name);
  await _charge(app, p, 'Consultation', 50000, code: 'CONSULT', category: Vals.consultation);
  await _charge(app, p, 'CBC', 35000);
  await _charge(app, p, 'Injection', 15000, category: Vals.procedure);
  final d = await BillingService.createDraft(app.db, p.id);
  return BillingService.finalise(app.db, d.id);
}

void main() {
  test('totals: gross, discount, net, paid and balance, with a split payment', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final p = await _patient(app, 'Aarti');
    await _charge(app, p, 'Consultation', 50000, code: 'CONSULT', category: Vals.consultation);
    await _charge(app, p, 'CBC', 35000);
    await _charge(app, p, 'Medicines', 15000, category: Vals.pharmacy);

    var d = await BillingService.createDraft(app.db, p.id);
    expect(d.str('status'), InvoiceStatus.draft);
    expect(d.str('number'), startsWith('DRAFT-'));
    expect(d.integer('gross_paise'), 100000);
    expect(d.integer('net_paise'), 100000);

    final out = await BillingService.requestDiscount(app, d.id, 10000, 'Senior citizen');
    expect(out.applied, isTrue, reason: '₹100 is within the ₹500 limit');
    d = await _inv(app, d.id);
    expect(d.integer('discount_paise'), 10000);
    expect(d.integer('net_paise'), 90000);
    expect(d.str('discount_by_name'), 'Cashier');
    final lines = await BillingService.linesOf(app.readDb, d.id);
    expect(lines.fold<int>(0, (a, l) => a + l.integer('net_paise')), 90000, reason: 'the discount is spread over the lines');

    final fin = await BillingService.finalise(app.db, d.id);
    expect(fin.integer('balance_paise'), 90000);
    expect(fin.integer('paid_paise'), 0);

    await expectLater(BillingService.takePayment(app.db, fin.id, [const PaymentEntry('upi', 90000)]),
        throwsA(isA<ValidationException>()), reason: 'UPI needs a reference');
    await expectLater(BillingService.takePayment(app.db, fin.id, [const PaymentEntry('cash', 95000)]),
        throwsA(isA<ValidationException>()), reason: 'cannot take more than is due');

    final paid = await BillingService.takePayment(app.db, fin.id, [
      const PaymentEntry('cash', 40000),
      const PaymentEntry('upi', 30000, reference: '412345678901'),
    ]);
    expect(paid, hasLength(2));
    expect(paid.map((r) => r.str('number')).every((n) => n.startsWith('RCPT-')), isTrue);
    var bill = await _inv(app, fin.id);
    expect(bill.integer('paid_paise'), 70000);
    expect(bill.integer('balance_paise'), 20000);

    await BillingService.takePayment(app.db, fin.id, [const PaymentEntry('card', 20000, reference: 'APPR 551023')]);
    bill = await _inv(app, fin.id);
    expect(bill.integer('gross_paise'), 100000);
    expect(bill.integer('discount_paise'), 10000);
    expect(bill.integer('net_paise'), 90000);
    expect(bill.integer('paid_paise'), 90000);
    expect(bill.integer('balance_paise'), 0);
    await expectLater(BillingService.takePayment(app.db, fin.id, [const PaymentEntry('cash', 100)]),
        throwsA(isA<ValidationException>()), reason: 'nothing is due');
    await app.close();
  });

  test('finalise numbers the bill and bills its charges; a charge is never on two bills', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final p = await _patient(app, 'Rohan');
    final c1 = await _charge(app, p, 'X-ray chest', 45000, category: Vals.radiology);
    final c2 = await _charge(app, p, 'CBC', 35000);

    final a = await BillingService.createDraft(app.db, p.id);
    var c = (await app.readDb.get(Col.charges, c1.id))!;
    expect(c.str('status'), Vals.pending, reason: 'a draft does not bill anything yet');
    expect(c.str('invoice_id'), a.id, reason: 'but it holds the charge');
    expect(await BillingService.unbilledFor(app.readDb, p.id), isEmpty);
    await expectLater(BillingService.createDraft(app.db, p.id, charges: [c1]), throwsA(isA<ValidationException>()));

    // Taking a line off returns its charge to "ready to bill".
    final lines = await BillingService.linesOf(app.readDb, a.id);
    final cbc = lines.firstWhere((l) => l.str('charge_id') == c2.id);
    await BillingService.removeLine(app.db, a.id, cbc.id);
    c = (await app.readDb.get(Col.charges, c2.id))!;
    expect(c.strOrNull('invoice_id'), isNull);
    expect(c.str('status'), Vals.pending);
    expect((await _inv(app, a.id)).integer('gross_paise'), 45000);

    final fin = await BillingService.finalise(app.db, a.id);
    expect(fin.str('number'), matches(RegExp(r'^INV-\d\d-\d{6}$')));
    expect(fin.str('status'), InvoiceStatus.finalised);
    expect(fin.str('finalised_by_name'), 'Cashier');
    c = (await app.readDb.get(Col.charges, c1.id))!;
    expect(c.str('status'), Vals.billed);
    expect(c.str('invoice_id'), fin.id);

    // The removed charge goes on the next bill, with the next number.
    final b = await BillingService.createDraft(app.db, p.id);
    final fin2 = await BillingService.finalise(app.db, b.id);
    expect(fin2.str('number'), isNot(fin.str('number')));
    expect(int.parse(fin2.str('number').split('-').last), greaterThan(int.parse(fin.str('number').split('-').last)));
    await app.close();
  });

  test('final bills cannot be edited', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final fin = await _finalBill(app, 'Sneha');
    final service = (await app.readDb.first(const Query(Col.services).eq('code', 'PROC-DRESS')))!;
    final line = (await BillingService.linesOf(app.readDb, fin.id)).first;
    await expectLater(BillingService.addManualLine(app.db, fin.id, service: service), throwsA(isA<ValidationException>()));
    await expectLater(BillingService.removeLine(app.db, fin.id, line.id), throwsA(isA<ValidationException>()));
    await expectLater(BillingService.finalise(app.db, fin.id), throwsA(isA<ValidationException>()));
    await expectLater(BillingService.requestDiscount(app, fin.id, 5000, 'Late'), throwsA(isA<ValidationException>()));
    await expectLater(BillingService.discardDraft(app.db, fin.id), throwsA(isA<ValidationException>()));
    final after = await _inv(app, fin.id);
    expect(after.integer('net_paise'), 100000);
    expect(after.version, fin.version);
    await app.close();
  });

  test('a discount within the limit applies at once; above it waits for the board', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final p = await _patient(app, 'Imran');
    await _charge(app, p, 'Ultrasound abdomen', 120000, category: Vals.radiology);
    await _charge(app, p, 'Consultation', 50000, category: Vals.consultation);
    final d = await BillingService.createDraft(app.db, p.id);

    final small = await BillingService.requestDiscount(app, d.id, 40000, 'Senior citizen');
    expect(small.applied, isTrue);
    expect((await _inv(app, d.id)).integer('discount_paise'), 40000);

    final big = await BillingService.requestDiscount(app, d.id, 80000, 'Financial hardship');
    expect(big.applied, isFalse);
    expect(big.approval.str('status'), 'pending');
    expect((await _inv(app, d.id)).integer('discount_paise'), 40000, reason: 'nothing changes until the board decides');
    await expectLater(BillingService.finalise(app.db, d.id), throwsA(isA<ValidationException>()),
        reason: 'cannot finalise while a discount is waiting');
    await expectLater(app.approvals.approve(big.approval), throwsA(isA<PermissionDeniedException>()),
        reason: 'the requester cannot approve their own discount');

    await signIn(app, 'board1');
    final done = await app.approvals.approve(big.approval);
    expect(done.str('status'), 'applied');
    final inv = await _inv(app, d.id);
    expect(inv.integer('discount_paise'), 80000, reason: 'a new request replaces the earlier discount');
    expect(inv.integer('net_paise'), 90000);
    expect(inv.str('discount_approval_id'), big.approval.id);

    await signIn(app, 'cashier');
    final fin = await BillingService.finalise(app.db, d.id);
    expect(fin.integer('net_paise'), 90000);
    await app.close();
  });

  test('refunds go through approvals and never re-open a paid bill', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final fin = await _finalBill(app, 'Kavya');
    await BillingService.takePayment(app.db, fin.id, [const PaymentEntry('cash', 100000)]);

    final small = await BillingService.requestRefund(app, fin.id, 30000, 'cash', 'Service not given');
    expect(small.applied, isTrue);
    var bill = await _inv(app, fin.id);
    expect(bill.integer('refunded_paise'), 30000);
    expect(bill.integer('paid_paise'), 70000);
    expect(bill.integer('balance_paise'), 0, reason: 'a refund for a service not given reduces what is owed');
    final refunds = await app.readDb.query(Query(BillCol.payments).eq('invoice_id', fin.id).eq('kind', PaymentKind.refund));
    expect(refunds.single.integer('amount_paise'), 30000, reason: 'amounts are always positive');
    expect(refunds.single.str('number'), startsWith('RFND-'));

    final big = await BillingService.requestRefund(app, fin.id, 60000, 'cash', 'Charged by mistake');
    expect(big.applied, isFalse);
    await expectLater(BillingService.requestRefund(app, fin.id, 10000, 'cash', 'Again'), throwsA(isA<ValidationException>()),
        reason: 'one refund request at a time');
    await signIn(app, 'board1');
    expect((await app.approvals.approve(big.approval)).str('status'), 'applied');
    bill = await _inv(app, fin.id);
    expect(bill.integer('refunded_paise'), 90000);
    expect(bill.integer('paid_paise'), 10000);
    expect(bill.integer('balance_paise'), 0);
    await signIn(app, 'cashier');
    await expectLater(BillingService.requestRefund(app, fin.id, 20000, 'cash', 'More'), throwsA(isA<ValidationException>()),
        reason: 'cannot refund more than was paid');

    // Returns-only bill: we owe the patient; a refund settles it.
    final p = await _patient(app, 'Joseph');
    await _charge(app, p, 'Return: Amoxicillin', -21000, category: Vals.pharmacy);
    final ret = await BillingService.finalise(app.db, (await BillingService.createDraft(app.db, p.id)).id);
    expect(ret.integer('balance_paise'), -21000);
    expect(BillingService.refundable(ret), 21000);
    await BillingService.requestRefund(app, ret.id, 21000, 'cash', 'Medicines returned');
    expect((await _inv(app, ret.id)).integer('balance_paise'), 0);
    await app.close();
  });

  test('cancelling a bill issues a credit note, refunds the money and frees the charges', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final fin = await _finalBill(app, 'Ritu');
    await BillingService.takePayment(app.db, fin.id, [
      const PaymentEntry('cash', 60000),
      const PaymentEntry('upi', 40000, reference: '400011112222'),
    ]);
    final req = await BillingService.requestCancel(app, fin.id, 'Wrong patient');
    expect(req.applied, isFalse, reason: '₹1,000 is above the cashier limit');
    expect((await _inv(app, fin.id)).str('status'), InvoiceStatus.finalised);

    await signIn(app, 'board1');
    expect((await app.approvals.approve(req.approval)).str('status'), 'applied');

    final orig = await _inv(app, fin.id);
    expect(orig.str('status'), InvoiceStatus.cancelled);
    expect(orig.integer('net_paise'), 100000, reason: 'the original keeps its amounts');
    expect(orig.integer('balance_paise'), 0);
    expect(orig.integer('paid_paise'), 0);
    final cn = (await app.readDb.first(Query(BillCol.invoices).eq('credit_note_for', fin.id)))!;
    expect(cn.str('kind'), InvoiceKind.creditNote);
    expect(cn.str('number'), startsWith('CN-'));
    expect(cn.integer('net_paise'), -100000);
    final origLines = await BillingService.linesOf(app.readDb, fin.id);
    final cnLines = await BillingService.linesOf(app.readDb, cn.id);
    expect(cnLines, hasLength(origLines.length));
    expect(cnLines.fold<int>(0, (a, l) => a + l.integer('amount_paise')), -100000);

    final refunds = await app.readDb.query(Query(BillCol.payments).eq('invoice_id', fin.id).eq('kind', PaymentKind.refund));
    expect({for (final r in refunds) r.str('mode'): r.integer('amount_paise')}, {'cash': 60000, 'upi': 40000},
        reason: 'money goes back the way it came');

    final charges = await app.readDb.query(Query(Col.charges).eq('patient_id', fin.str('patient_id')));
    expect(charges.every((c) => c.str('status') == Vals.pending && c.strOrNull('invoice_id') == null), isTrue);

    // They can be billed again, correctly this time.
    await signIn(app, 'cashier');
    final again = await BillingService.createDraft(app.db, fin.str('patient_id'));
    expect(again.integer('gross_paise'), 100000);
    await app.close();
  });

  test('closing the day compares counted cash with what was taken', () async {
    final app = await _hospital();
    await signIn(app, 'cashier');
    final fin = await _finalBill(app, 'Manoj');
    await BillingService.takePayment(app.db, fin.id, [
      const PaymentEntry('cash', 70000),
      const PaymentEntry('upi', 30000, reference: '400099998888'),
    ]);
    final s = app.auth.session!;
    final expected = await BillingService.expectedByMode(app.readDb, s.userId, DateTime.now());
    expect(expected, {'cash': 70000, 'upi': 30000});
    await expectLater(
        BillingService.closeDay(app.db, userId: s.userId, userName: s.displayName, day: DateTime.now(), countedCashPaise: 50000),
        throwsA(isA<ValidationException>()),
        reason: 'a difference above ₹100 needs a note');
    final c = await BillingService.closeDay(app.db,
        userId: s.userId, userName: s.displayName, day: DateTime.now(), countedCashPaise: 50000, notes: 'Gave change twice');
    expect(c.integer('expected_cash_paise'), 70000);
    expect(c.integer('variance_paise'), -20000);
    await app.close();
  });

  test('amounts in words', () {
    expect(amountInWords(125000), 'Rupees One Thousand Two Hundred Fifty only');
    expect(amountInWords(12345678), 'Rupees One Lakh Twenty Three Thousand Four Hundred Fifty Six and Seventy Eight Paise only');
    expect(BillingService.allocate(1000, [3000, 7000, -500]), [300, 700, 0]);
    expect(BillingService.allocate(100, [1, 1, 1]).fold<int>(0, (a, b) => a + b), 100);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_module.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_schema.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_service.dart';

import '../../helpers.dart';

Rec _batch(String id, DateTime expiry, int qty, {int created = 0}) => Rec(PCol.batches, {
      'id': id,
      'created_at': DateTime(2026, 1, 1).add(Duration(minutes: created)),
      'updated_at': DateTime(2026, 1, 1),
      'product_id': 'p1',
      'batch_no': id.toUpperCase(),
      'expiry_date': expiry,
      'qty_on_hand': qty,
      'cost_paise': 100,
      'mrp_paise': 150,
    });

/// A fresh hospital with a pharmacist signed in, one patient and a supplier.
Future<(AppServices, Rec, Rec)> _hospital() async {
  final app = await bootTestHospital([PatientsModule(), PharmacyModule()]);
  await addUser(app, 'pharma1', [Roles.pharmacist]);
  await addUser(app, 'board1', [Roles.board]);
  await addUser(app, 'drtest', [Roles.doctor], extra: {'is_clinician': true});
  await signIn(app, 'pharma1');
  final patient = await app.systemDb.insert(Col.patients, {
    'uhid': 'TH-26-000001',
    'first_name': 'Asha',
    'last_name': 'Patil',
    'full_name': 'Asha Patil',
    'phone': '9822012345',
    'allergies': 'Penicillin',
  });
  final supplier = await app.db.insert(PCol.suppliers, {'name': 'MedLine Distributors', 'lead_days': 2, 'active': true});
  return (app, patient, supplier);
}

Future<Rec> _product(AppServices app, String name) async =>
    (await app.store.query(Query(PCol.products).eq('name', name).take(1))).single;

DateTime _monthsAhead(int m) {
  final n = DateTime.now();
  return PharmacyService.expiryFromMonth(((n.month - 1 + m) % 12) + 1, n.year + (n.month - 1 + m) ~/ 12);
}

/// Signs out first so a late account-change refresh never touches the closed database.
Future<void> _close(AppServices app) async {
  if (app.auth.signedIn) await app.auth.logout();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await app.close();
}

Future<int> _movementSum(AppServices app, String batchId) async =>
    (await app.readDb.sum(Query(PCol.movements).eq('batch_id', batchId), 'qty')).toInt();

void main() {
  test('FEFO takes the earliest unexpired batch with stock and splits across batches', () {
    final now = DateTime.now();
    final batches = [
      _batch('late', now.add(const Duration(days: 400)), 50),
      _batch('expired', now.subtract(const Duration(days: 3)), 30),
      _batch('empty', now.add(const Duration(days: 20)), 0),
      _batch('soon', now.add(const Duration(days: 40)), 8),
      _batch('mid', now.add(const Duration(days: 200)), 5),
    ];
    final one = PharmacyService.pickFefo(batches, 6);
    expect(one.picks.map((p) => (p.batch.id, p.qty)), [('soon', 6)]);

    final split = PharmacyService.pickFefo(batches, 20);
    expect(split.picks.map((p) => (p.batch.id, p.qty)), [('soon', 8), ('mid', 5), ('late', 7)]);
    expect(split.shortBy, 0);

    final tooMany = PharmacyService.pickFefo(batches, 70);
    expect(tooMany.picked, 63, reason: 'expired and empty batches are never picked');
    expect(tooMany.shortBy, 7);
  });

  test('prescription quantities from dose, frequency and days', () {
    expect(PharmacyService.dosesPerDay('1-0-1'), 2);
    expect(PharmacyService.dosesPerDay('1-1-1'), 3);
    expect(PharmacyService.dosesPerDay('½-0-½'), 1);
    expect(PharmacyService.dosesPerDay('TDS'), 3);
    expect(PharmacyService.prescribedQty({'frequency': '1-0-1', 'duration_days': 5, 'dose': '1 tablet'}, unit: 'tablet'), 10);
    expect(PharmacyService.prescribedQty({'quantity': 15, 'frequency': '1-0-1'}, unit: 'tablet'), 15);
    expect(PharmacyService.prescribedQty({'frequency': '1-1-1', 'duration_days': 5, 'dose': '5 ml'}, unit: 'bottle'), 1,
        reason: 'a syrup is one bottle, not 75 ml');
    expect(PharmacyService.parseExpiry('08/27'), DateTime(2027, 8, 31));
    expect(PharmacyService.allergyConflicts('Penicillin', [('Mox 500', 'Amoxicillin')]), isNotEmpty);
    expect(PharmacyService.allergyConflicts('Penicillin', [('Dolo 650', 'Paracetamol')]), isEmpty);
  });

  test('starter medicine list is seeded with a product for each', () async {
    final app = await bootTestHospital([PatientsModule(), PharmacyModule()]);
    final meds = await app.store.count(const Query(Col.medicines));
    final products = await app.store.count(const Query(PCol.products));
    expect(meds, greaterThanOrEqualTo(55));
    expect(products, meds);
    await _close(app);
  });

  test('goods receipt creates batches and movements and closes the PO', () async {
    final (app, _, supplier) = await _hospital();
    final dolo = await _product(app, 'Dolo 650');
    final po = await PharmacyService.createOrder(app.db,
        supplierId: supplier.id, items: [{'product_id': dolo.id, 'name': 'Dolo 650', 'qty': 100, 'cost_paise': 140}]);
    expect(po.str('number'), startsWith('PO-'));
    final sent = await PharmacyService.markOrdered(app.db, po, leadDays: 2);
    expect(sent.str('status'), PoStatus.ordered);

    final grn = await PharmacyService.receive(app.db,
        supplierId: supplier.id,
        orderId: po.id,
        supplierInvoiceNo: 'INV-77',
        byName: 'Neha',
        lines: [
          ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'do24a', expiry: _monthsAhead(10), qty: 60, costPaise: 140, mrpPaise: 206),
          ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'DO24B', expiry: _monthsAhead(16), qty: 40, costPaise: 140, mrpPaise: 206),
        ]);
    expect(grn.str('number'), startsWith('GRN-'));
    expect(grn.integer('total_paise'), 100 * 140);
    final batches = await app.store.query(Query(PCol.batches).eq('product_id', dolo.id).sort('expiry_date'));
    expect(batches.map((b) => (b.str('batch_no'), b.integer('qty_on_hand'))), [('DO24A', 60), ('DO24B', 40)]);
    for (final b in batches) {
      expect(await _movementSum(app, b.id), b.integer('qty_on_hand'));
      expect(b.str('receipt_id'), grn.id);
    }
    expect((await app.store.get(PCol.orders, po.id))!.str('status'), PoStatus.received);

    // The same batch number again adds to that batch instead of making a second one.
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'DO24A', expiry: _monthsAhead(10), qty: 10, costPaise: 140, mrpPaise: 206),
    ]);
    final a = (await app.store.query(Query(PCol.batches).eq('batch_no', 'DO24A'))).single;
    expect(a.integer('qty_on_hand'), 70);
    expect(await _movementSum(app, a.id), 70);

    await expectLater(
      PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
        ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'OLD1', expiry: DateTime.now().subtract(const Duration(days: 40)), qty: 5, costPaise: 1, mrpPaise: 2),
      ]),
      throwsA(isA<ValidationException>()),
      reason: 'expired goods are refused at receipt',
    );
    await _close(app);
  });

  test('dispensing moves stock, posts charges and updates the prescription', () async {
    final (app, patient, supplier) = await _hospital();
    final dolo = await _product(app, 'Dolo 650');
    final pan = await _product(app, 'Pan 40');
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'SOON', expiry: _monthsAhead(2), qty: 6, costPaise: 140, mrpPaise: 200),
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'LATER', expiry: _monthsAhead(14), qty: 50, costPaise: 140, mrpPaise: 210),
      ReceiptLine(productId: pan.id, name: 'Pan 40', batchNo: 'PAN1', expiry: _monthsAhead(12), qty: 30, costPaise: 500, mrpPaise: 750),
    ]);
    final doctor = (await app.store.query(const Query(Col.users).eq('username', 'drtest'))).single;
    final encounter = await app.systemDb.insert(Col.encounters, {
      'patient_id': patient.id,
      'type': Vals.opd,
      'status': Vals.closed,
      'doctor_id': doctor.id,
      'started_at': DateTime.now().subtract(const Duration(minutes: 30)),
    });
    final rx = await app.systemDb.insert(Col.prescriptions, {
      'patient_id': patient.id,
      'encounter_id': encounter.id,
      'doctor_id': doctor.id,
      'status': Vals.active,
      'items': [
        {'medicine_id': dolo.str('medicine_id'), 'drug_name': 'Dolo 650', 'dose': '1 tablet', 'frequency': '1-1-1', 'duration_days': 3, 'quantity': 9, 'dispensed_qty': 0},
        {'drug_name': 'Pantoprazole 40', 'dose': '1 tablet', 'frequency': '1-0-0', 'duration_days': 5, 'dispensed_qty': 0},
      ],
    });

    // Matching: by medicine id, and by generic name when only the drug name is given.
    final index = ProductIndex(await PharmacyService.activeProducts(app.readDb));
    expect(index.match(rx.maps('items')[0]).$1?.id, dolo.id);
    expect(index.match(rx.maps('items')[1]).$1?.id, pan.id);

    final doloBatches = await PharmacyService.stockBatches(app.readDb, dolo.id);
    final fefo = PharmacyService.pickFefo(doloBatches, 9);
    expect(fefo.picks.map((p) => (p.batch.str('batch_no'), p.qty)), [('SOON', 6), ('LATER', 3)]);

    // Only the Dolo line first: the prescription becomes partly dispensed.
    final d1 = await PharmacyService.dispense(app.db,
        patientId: patient.id,
        prescription: rx,
        byName: 'Neha',
        lines: [DispenseLine(product: dolo, picks: fefo.picks, rxIndex: 0)]);
    expect(d1.str('number'), startsWith('PH-'));
    expect(d1.integer('total_paise'), 6 * 200 + 3 * 210);
    final soon = (await app.store.query(const Query(PCol.batches).eq('batch_no', 'SOON'))).single;
    final later = (await app.store.query(const Query(PCol.batches).eq('batch_no', 'LATER'))).single;
    expect(soon.integer('qty_on_hand'), 0);
    expect(later.integer('qty_on_hand'), 47);
    expect(await _movementSum(app, soon.id), 0);
    expect(await _movementSum(app, later.id), 47);
    final moves = await app.store.query(Query(PCol.movements).eq('ref_id', d1.id));
    expect(moves.map((m) => m.integer('qty')).toList()..sort(), [-6, -3]);
    expect(moves.every((m) => m.str('type') == MoveType.dispense && m.str('patient_id') == patient.id), isTrue);

    final charges = await app.store.query(Query(Col.charges).startsWith('source_id', '${d1.id}:').sort('source_id'));
    expect(charges, hasLength(2));
    final c0 = charges.first;
    expect(c0.str('category'), 'pharmacy');
    expect(c0.str('status'), 'pending');
    expect(c0.str('source_module'), 'pharmacy');
    expect(c0.str('source_collection'), 'pharmacy_dispenses');
    expect(c0.str('service_code'), dolo.str('sku'));
    expect(c0.str('description'), 'Dolo 650 (batch SOON)');
    expect(c0.integer('quantity'), 6);
    expect(c0.integer('unit_price_paise'), 200);
    expect(c0.integer('amount_paise'), 1200);
    expect(c0.str('encounter_id'), encounter.id);
    expect(c0.str('ordered_by'), doctor.id);

    var saved = (await app.store.get(Col.prescriptions, rx.id))!;
    expect(saved.str('status'), Vals.partiallyDispensed);
    expect(saved.maps('items')[0]['dispensed_qty'], 9);

    // Then the rest: fully dispensed.
    final panPicks = PharmacyService.pickFefo(await PharmacyService.stockBatches(app.readDb, pan.id),
        PharmacyService.remainingQty(saved.maps('items')[1], unit: 'tablet'));
    await PharmacyService.dispense(app.db,
        patientId: patient.id, prescription: saved, byName: 'Neha', lines: [DispenseLine(product: pan, picks: panPicks.picks, rxIndex: 1)]);
    saved = (await app.store.get(Col.prescriptions, rx.id))!;
    expect(saved.str('status'), Vals.dispensed);
    expect(saved.date('dispensed_at'), isNotNull);

    // A return puts stock back and cancels the pending charge for that line.
    await PharmacyService.returnItems(app.db, dispense: d1, qtyByLine: {0: 6}, reason: 'Unopened', byName: 'Neha');
    final soonAfter = (await app.store.get(PCol.batches, soon.id))!;
    expect(soonAfter.integer('qty_on_hand'), 6);
    expect(await _movementSum(app, soon.id), 6);
    expect((await app.store.get(Col.charges, c0.id))!.str('status'), 'cancelled');
    // A partial return of the other line posts a negative charge instead.
    await PharmacyService.returnItems(app.db, dispense: d1, qtyByLine: {1: 1}, reason: 'Unopened', byName: 'Neha');
    final credits = await app.store.query(const Query(Col.charges).lt('amount_paise', 0));
    expect(credits.single.integer('quantity'), -1);
    expect(credits.single.integer('amount_paise'), -210);
    await expectLater(
        PharmacyService.returnItems(app.db, dispense: d1, qtyByLine: {0: 1}, reason: 'Again', byName: 'Neha'),
        throwsA(isA<ValidationException>()),
        reason: 'cannot return more than was given');
    await _close(app);
  });

  test('cannot dispense more than is on hand, and nothing is written', () async {
    final (app, patient, supplier) = await _hospital();
    final dolo = await _product(app, 'Dolo 650');
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'B1', expiry: _monthsAhead(6), qty: 5, costPaise: 140, mrpPaise: 200),
    ]);
    final b = (await PharmacyService.stockBatches(app.readDb, dolo.id)).single;
    final movesBefore = await app.store.count(const Query(PCol.movements));
    await expectLater(
      PharmacyService.dispense(app.db,
          patientId: patient.id, byName: 'Neha', lines: [DispenseLine(product: dolo, picks: [BatchPick(b, 8)])]),
      throwsA(isA<ValidationException>()),
    );
    expect(await app.store.count(const Query(PCol.movements)), movesBefore);
    expect((await app.store.get(PCol.batches, b.id))!.integer('qty_on_hand'), 5);
    expect(await app.store.count(const Query(Col.charges)), 0);
    expect(await app.store.count(const Query(PCol.dispenses)), 0);

    // Someone else sold 3 in the meantime: the stale pick of 5 is refused too.
    await PharmacyService.dispense(app.db, patientId: patient.id, byName: 'Neha', lines: [DispenseLine(product: dolo, picks: [BatchPick(b, 3)])]);
    await expectLater(
      PharmacyService.dispense(app.db, patientId: patient.id, byName: 'Neha', lines: [DispenseLine(product: dolo, picks: [BatchPick(b, 5)])]),
      throwsA(isA<ValidationException>()),
    );
    expect((await app.store.get(PCol.batches, b.id))!.integer('qty_on_hand'), 2);
    await _close(app);
  });

  test('low stock agent proposes one PO per supplier; approving creates a draft', () async {
    final (app, _, supplier) = await _hospital();
    final dolo = await _product(app, 'Dolo 650');
    final pan = await _product(app, 'Pan 40');
    final ors = await _product(app, 'Electral ORS');
    for (final p in [dolo, pan, ors]) {
      await app.db.update(PCol.products, p.id, {'preferred_supplier_id': supplier.id});
    }
    // Everything else has plenty or no reorder level.
    await app.systemDb.batch([
      for (final p in await app.store.query(const Query(PCol.products).take(500)))
        if (![dolo.id, pan.id, ors.id].contains(p.id)) UpdateOp(PCol.products, p.id, {'reorder_level': 0}),
    ]);
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'D1', expiry: _monthsAhead(6), qty: 20, costPaise: 140, mrpPaise: 206),
      ReceiptLine(productId: pan.id, name: 'Pan 40', batchNo: 'P1', expiry: _monthsAhead(6), qty: 500, costPaise: 500, mrpPaise: 750),
    ]);

    await app.agents!.runById('pharmacy.low_stock');
    var proposals = await app.store.query(const Query(Col.proposals).eq('agent_id', 'pharmacy.low_stock').eq('status', 'pending'));
    expect(proposals, hasLength(1), reason: 'Dolo (20 ≤ 200) and ORS (out) from the same supplier: one proposal');
    final p = proposals.single;
    expect(p.str('handler'), 'pharmacy.create_po');
    expect(p.str('title'), 'Reorder 2 medicines from MedLine Distributors');
    final items = p.map('payload')['items'] as List;
    expect(items.map((i) => (i as Map)['product_id']).toSet(), {dolo.id, ors.id});
    expect(items.firstWhere((i) => (i as Map)['product_id'] == dolo.id)['qty'], dolo.integer('reorder_qty'));

    final done = await app.tower.approveProposal(p);
    expect(done.str('result'), matches(RegExp(r'^Created PO-\d\d-\d{6}$')));
    final po = (await app.store.query(const Query(PCol.orders))).single;
    expect(po.str('status'), PoStatus.draft);
    expect(po.flag('from_proposal'), isTrue);
    expect(po.str('supplier_id'), supplier.id);

    // The draft now covers both products, so nothing new is proposed.
    await app.agents!.runById('pharmacy.low_stock');
    proposals = await app.store.query(const Query(Col.proposals).eq('agent_id', 'pharmacy.low_stock').eq('status', 'pending'));
    expect(proposals, isEmpty);
    await _close(app);
  });

  test('integrity agent flags a movement without a batch update', () async {
    final (app, _, supplier) = await _hospital();
    final dolo = await _product(app, 'Dolo 650');
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: dolo.id, name: 'Dolo 650', batchNo: 'D1', expiry: _monthsAhead(6), qty: 50, costPaise: 140, mrpPaise: 206),
    ]);
    await app.agents!.runById('pharmacy.stock_integrity');
    expect(await app.store.count(const Query(Col.findings).eq('agent_id', 'pharmacy.stock_integrity').eq('status', 'open')), 0);

    final b = (await PharmacyService.stockBatches(app.readDb, dolo.id)).single;
    await app.db.insert(PCol.movements, {'product_id': dolo.id, 'batch_id': b.id, 'qty': -4, 'type': MoveType.adjustment, 'reason': 'Counted'});
    await app.agents!.runById('pharmacy.stock_integrity');
    final f = (await app.store.query(const Query(Col.findings).eq('agent_id', 'pharmacy.stock_integrity').eq('status', 'open'))).single;
    expect(f.str('title'), 'Stock record mismatch: Dolo 650');
    expect(f.str('severity'), 'high');
    expect(f.integer('amount_at_risk_paise'), 4 * 140);
    await _close(app);
  });

  test('adjustments over ₹5,000 wait for the board; small ones apply at once', () async {
    final (app, _, supplier) = await _hospital();
    final lantus = await _product(app, 'Lantus SoloStar');
    await PharmacyService.receive(app.db, supplierId: supplier.id, byName: 'Neha', lines: [
      ReceiptLine(productId: lantus.id, name: 'Lantus SoloStar', batchNo: 'L1', expiry: _monthsAhead(8), qty: 20, costPaise: 52500, mrpPaise: 75000),
    ]);
    var b = (await PharmacyService.stockBatches(app.readDb, lantus.id)).single;

    final (small, _) = await PharmacyService.adjustOrRequest(app, batch: b, qtyDelta: -2, reason: 'Damaged', productName: 'Lantus');
    expect(small, isTrue, reason: '2 × ₹525 is within the limit');
    b = (await app.store.get(PCol.batches, b.id))!;
    expect(b.integer('qty_on_hand'), 18);

    final (big, msg) = await PharmacyService.adjustOrRequest(app, batch: b, qtyDelta: -10, reason: 'Fridge failure', productName: 'Lantus');
    expect(big, isFalse);
    expect(msg, contains('approval'));
    expect((await app.store.get(PCol.batches, b.id))!.integer('qty_on_hand'), 18, reason: 'nothing changes before approval');
    final approval = (await app.store.query(const Query(Col.approvals).eq('type', 'pharmacy.adjustment'))).single;
    expect(approval.str('status'), 'pending');
    expect(approval.integer('amount_paise'), 10 * 52500);
    expect(approval.map('payload'), {'batch_id': b.id, 'qty_delta': -10, 'reason': 'Fridge failure'});
    await expectLater(app.approvals.approve(approval), throwsA(isA<PermissionDeniedException>()));

    await signIn(app, 'board1');
    final applied = await app.approvals.approve(approval);
    expect(applied.str('status'), 'applied');
    b = (await app.store.get(PCol.batches, b.id))!;
    expect(b.integer('qty_on_hand'), 8);
    expect(await _movementSum(app, b.id), 8);
    final mv = (await app.store.query(Query(PCol.movements).eq('ref_id', approval.id))).single;
    expect(mv.str('type'), MoveType.adjustment);
    expect(mv.integer('qty'), -10);
    await _close(app);
  });

  test('demo pharmacy is consistent and gives the agents something to find', () async {
    final app = await bootTestHospital([PatientsModule(), PharmacyModule()], demo: true);
    await app.agents!.runAll();
    final rx = await app.store.query(const Query(Col.prescriptions).take(100));
    final waiting = rx.where((r) => r.str('status') == Vals.active).length;
    expect(rx.length, greaterThanOrEqualTo(10));
    expect(waiting, lessThan(rx.length / 2), reason: 'most prescriptions are dispensed');
    expect(waiting, greaterThan(0), reason: 'some are still in the queue');

    // Every batch equals the sum of its movements, except the one planted for the integrity agent.
    final batches = await app.store.query(const Query(PCol.batches).take(5000));
    var mismatches = 0;
    for (final b in batches) {
      if (await _movementSum(app, b.id) != b.integer('qty_on_hand')) mismatches++;
      expect(b.integer('qty_on_hand'), greaterThanOrEqualTo(0));
    }
    expect(mismatches, 1);

    Future<List<Rec>> open(String agent) =>
        app.store.query(Query(Col.findings).eq('agent_id', agent).eq('status', 'open').take(500));
    final integrity = await open('pharmacy.stock_integrity');
    expect(integrity.map((f) => f.str('title')).where((t) => t.startsWith('Stock record mismatch')), hasLength(1));
    expect(integrity.where((f) => f.str('title').startsWith('Medicines dispensed without')), isEmpty,
        reason: 'every demo dispense posted its charges');
    final expiry = await open('pharmacy.expiry');
    expect(expiry.where((f) => f.str('severity') == 'high').length, inInclusiveRange(2, 3));
    expect(expiry.where((f) => f.str('severity') == 'medium').length, greaterThanOrEqualTo(4));
    final proposals = await app.store.query(const Query(Col.proposals).eq('status', 'pending'));
    expect(proposals.where((p) => p.str('handler') == 'pharmacy.create_po'), isNotEmpty);
    expect(proposals.where((p) => p.str('handler') == 'pharmacy.writeoff_expired'), hasLength(1));
    final stock = await PharmacyService.stock(app.readDb);
    expect(stock.values.where((s) => s.atOrBelowReorder).length, inInclusiveRange(4, 10));
    expect(await app.store.count(const Query(PCol.dispenses).eq('kind', DispenseKind.counter)), greaterThanOrEqualTo(12));
    await _close(app);
  });
}

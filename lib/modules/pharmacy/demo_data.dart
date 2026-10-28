import 'dart:math';

import 'package:kendra_hms/core/core.dart';

import 'catalog_data.dart';
import 'pharmacy_schema.dart';
import 'pharmacy_service.dart';

const _suppliers = <(MedGroup, String, String, String, String, int)>[
  (MedGroup.acute, 'MedLine Distributors', '020 2612 4410', '27AABCM4521K1Z3', 'Shop 4, Budhwar Peth, Pune', 2),
  (MedGroup.chronic, 'Sai Pharma Agencies', '020 2433 9087', '27AAKFS2290P1ZQ', 'Narayan Peth, Pune', 3),
  (MedGroup.hospital, 'Apex Healthcare Supplies', '020 2687 1123', '27AADCA7781H1Z9', 'Bhosari MIDC, Pune', 5),
  (MedGroup.general, 'Lifeline Pharma', '98220 41875', '27AAGFL6612M1ZB', 'Kothrud, Pune', 4),
];

/// Products with expired stock still on the shelf.
const _expired = ['Brufen 400', 'Gelusil MPS Syrup', 'Ciplox Eye/Ear Drops'];

/// Products with a batch expiring in the next 20–58 days.
const _nearExpiry = ['Electral ORS', 'Cetzine 10', 'Becosules', 'Ascoril LS Syrup', 'Monocef 1g Injection', 'Huminsulin 30/70'];

/// Products kept below their reorder level.
const _low = ['Azithral 500', 'Telma 40', 'Asthalin Inhaler', 'Shelcal 500', 'Normal Saline 500 ml', 'Taxim-O 200', 'Montair LC'];

/// Low products already on the open purchase order (the agent leaves them alone).
const _onOrder = ['Taxim-O 200', 'Montair LC'];

const _counterItems = [
  'Dolo 650', 'Cetzine 10', 'Electral ORS', 'Becosules', 'Soframycin Cream', 'Volini Gel', 'Combiflam',
  'Gelusil MPS Syrup', 'Neurobion Forte', 'Calpol 500', 'Ecosprin 75', 'Refresh Tears',
];

/// Prescriptions the demo creates when OPD has not written any:
/// (doctor username, [(medicine, dose, frequency, days, instructions)]).
const _demoRx = <(String, List<(String, String, String, int, String)>)>[
  ('board', [('Dolo 650', '1 tablet', '1-1-1', 3, 'After food'), ('Azithral 500', '1 tablet', '1-0-0', 3, ''), ('Pan 40', '1 tablet', '1-0-0', 5, 'Before breakfast')]),
  ('drnair', [('Zerodol-P', '1 tablet', '1-0-1', 5, 'After food'), ('Pan 40', '1 tablet', '1-0-0', 5, 'Before breakfast'), ('Volini Gel', 'Apply', '1-1-1', 7, 'On the knee')]),
  ('drkhan', [('Calpol 250 Syrup', '5 ml', '1-1-1', 3, 'If fever above 100°F'), ('Electral ORS', '1 sachet', 'After each loose stool', 3, 'In 1 litre boiled water')]),
  ('board', [('Glycomet GP 1', '1 tablet', '1-0-1', 30, 'With meals'), ('Telma 40', '1 tablet', '1-0-0', 30, ''), ('Atorva 10', '1 tablet', '0-0-1', 30, '')]),
  ('drkhan', [('Azithral 200 Liquid', '5 ml', '1-0-0', 3, ''), ('Ascoril LS Syrup', '2.5 ml', '1-1-1', 5, '')]),
  ('drnair', [('Shelcal 500', '1 tablet', '0-1-0', 30, 'After lunch'), ('Uprise-D3 60K', '1 capsule', 'Weekly', 56, 'Every Sunday with milk'), ('Ultracet', '1 tablet', 'SOS', 3, 'Only for severe pain')]),
  ('board', [('Cetzine 10', '1 tablet', '0-0-1', 5, ''), ('Montair LC', '1 tablet', '0-0-1', 10, ''), ('Asthalin Inhaler', '2 puffs', 'SOS', 30, 'When breathless')]),
  ('drkhan', [('Calpol 250 Syrup', '5 ml', '1-1-1', 3, ''), ('Econorm', '1 sachet', '1-0-1', 5, 'Mix in water')]),
  ('board', [('Pan-D', '1 capsule', '1-0-0', 7, 'Before breakfast'), ('Ondem 4', '1 tablet', 'SOS', 2, 'For vomiting'), ('Electral ORS', '1 sachet', '1-1-1', 2, '')]),
  ('drnair', [('Combiflam', '1 tablet', '1-0-1', 3, 'After food'), ('Evion 400', '1 capsule', '1-0-0', 30, '')]),
  ('board', [('Amlong 5', '1 tablet', '1-0-0', 30, ''), ('Ecosprin 75', '1 tablet', '0-1-0', 30, 'After lunch'), ('Rosuvas 10', '1 tablet', '0-0-1', 30, '')]),
  ('drkhan', [('Mox 500', '1 capsule', '1-1-1', 5, ''), ('Dolo 650', '1 tablet', '1-1-1', 3, 'If fever')]),
  ('board', [('Augmentin 625 Duo', '1 tablet', '1-0-1', 5, 'After food'), ('Dolo 650', '1 tablet', '1-1-1', 3, ''), ('Pan 40', '1 tablet', '1-0-0', 5, '')]),
  ('drnair', [('Zerodol-P', '1 tablet', '1-0-1', 5, ''), ('Neurobion Forte', '1 tablet', '1-0-0', 30, '')]),
];

/// Fills the demo pharmacy: suppliers, 60 days of purchase orders and
/// receipts, batches with varied expiry, prescriptions dispensed through the
/// real dispense logic, a week of counter sales and a few things for the
/// agents to find.
Future<void> seedPharmacyDemo(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final rnd = Random(26);
  final now = DateTime.now();
  final today = startOfDay(now);
  await ensureProducts(db);

  final pharmacist = await db.first(Query(Col.users).eq('username', 'pharmacy'));
  final by = pharmacist?.str('display_name') ?? 'Pharmacist';

  // Suppliers, and each product's preferred supplier.
  final supplierOf = <MedGroup, Rec>{};
  for (final (g, name, phone, gstin, address, lead) in _suppliers) {
    supplierOf[g] = await db.insert(PCol.suppliers,
        {'name': name, 'phone': phone, 'gstin': gstin, 'address': address, 'lead_days': lead, 'active': true});
  }
  var products = await PharmacyService.activeProducts(db);
  MedGroup groupOf(Rec p) => seedFor(p.str('name'))?.group ?? MedGroup.general;
  await db.batch([
    for (final p in products) UpdateOp(PCol.products, p.id, {'preferred_supplier_id': supplierOf[groupOf(p)]!.id}),
  ]);
  products = await PharmacyService.activeProducts(db);
  final byName = {for (final p in products) p.str('name'): p};
  bool isIn(List<String> names, Rec p) => names.contains(p.str('name'));

  String batchNo(Rec p, int n) {
    final letters = p.str('sku').replaceAll(RegExp(r'[^A-Z]'), '');
    return '${letters.length >= 2 ? letters.substring(0, 2) : 'BT'}${(24 + n % 3)}${(1000 + rnd.nextInt(8999))}';
  }

  DateTime monthsAhead(int m) => PharmacyService.expiryFromMonth(((now.month - 1 + m) % 12) + 1, now.year + (now.month - 1 + m) ~/ 12);

  // 1. Opening stock, received 60 days ago from each supplier.
  for (final g in MedGroup.values) {
    final lines = <ReceiptLine>[];
    for (final p in products.where((p) => groupOf(p) == g)) {
      final level = max(p.integer('reorder_level'), 5);
      final DateTime expiry;
      if (isIn(_expired, p)) {
        expiry = today.subtract(Duration(days: 4 + rnd.nextInt(20)));
      } else if (isIn(_nearExpiry, p)) {
        expiry = today.add(Duration(days: 20 + rnd.nextInt(38)));
      } else {
        expiry = monthsAhead(5 + rnd.nextInt(14));
      }
      final qty = isIn(_low, p)
          ? max(2, (level * (0.45 + rnd.nextDouble() * 0.3)).round())
          : isIn(_expired, p)
              ? max(4, (level * 0.3).round())
              : (level * (2.2 + rnd.nextDouble() * 1.6)).round();
      lines.add(ReceiptLine(
        productId: p.id,
        name: p.str('name'),
        batchNo: batchNo(p, 0),
        expiry: expiry,
        qty: qty,
        costPaise: p.integer('purchase_price_paise'),
        mrpPaise: p.integer('mrp_paise'),
      ));
      // Expired and near-expiry products also have a fresh batch behind the old one.
      if (isIn(_expired, p) || isIn(_nearExpiry, p)) {
        lines.add(ReceiptLine(
          productId: p.id,
          name: p.str('name'),
          batchNo: batchNo(p, 1),
          expiry: monthsAhead(12 + rnd.nextInt(10)),
          qty: (level * (1.5 + rnd.nextDouble())).round(),
          costPaise: p.integer('purchase_price_paise'),
          mrpPaise: p.integer('mrp_paise'),
        ));
      }
    }
    if (lines.isEmpty) continue;
    await PharmacyService.receive(db,
        supplierId: supplierOf[g]!.id,
        lines: lines,
        byName: by,
        supplierInvoiceNo: 'OPEN-${g.index + 1}',
        at: today.subtract(Duration(days: 60 - g.index)).add(const Duration(hours: 11)));
  }

  // 2. Purchase orders over the last 60 days.
  Future<Rec> po(MedGroup g, int daysAgo, List<Rec> items, {int? receivedAfter, bool send = true, String? notes}) async {
    final at = today.subtract(Duration(days: daysAgo)).add(Duration(hours: 10, minutes: rnd.nextInt(50)));
    var o = await PharmacyService.createOrder(db,
        supplierId: supplierOf[g]!.id,
        items: [
          for (final p in items)
            {'product_id': p.id, 'name': p.str('name'), 'qty': max(p.integer('reorder_qty'), 10), 'cost_paise': p.integer('purchase_price_paise')}
        ],
        notes: notes,
        at: at);
    if (send) o = await PharmacyService.markOrdered(db, o, leadDays: supplierOf[g]!.integer('lead_days'), at: at);
    if (receivedAfter != null) {
      final rAt = at.add(Duration(days: receivedAfter, hours: 3));
      await PharmacyService.receive(db,
          supplierId: supplierOf[g]!.id,
          orderId: o.id,
          supplierInvoiceNo: 'INV/${2600 + rnd.nextInt(900)}',
          byName: by,
          at: rAt,
          lines: [
            for (final it in o.maps('items'))
              ReceiptLine(
                productId: it['product_id'] as String,
                name: it['name'] as String,
                batchNo: batchNo(byName[it['name']]!, 2),
                expiry: monthsAhead(14 + rnd.nextInt(12)),
                qty: (it['qty'] as num).toInt(),
                costPaise: (it['cost_paise'] as num).toInt(),
                mrpPaise: byName[it['name']]!.integer('mrp_paise'),
              )
          ]);
    }
    return o;
  }

  List<Rec> pick(MedGroup g, int n, {List<String> skip = const []}) {
    final list = products
        .where((p) => groupOf(p) == g && !isIn(_low, p) && !isIn(_expired, p) && !isIn(_nearExpiry, p) && !isIn(skip, p))
        .toList();
    list.shuffle(rnd);
    return list.take(n).toList();
  }

  await po(MedGroup.acute, 46, pick(MedGroup.acute, 5), receivedAfter: 2);
  await po(MedGroup.chronic, 33, pick(MedGroup.chronic, 6), receivedAfter: 3);
  final cancelled = await po(MedGroup.general, 21, pick(MedGroup.general, 3));
  await PharmacyService.cancelOrder(db, cancelled, 'Supplier could not supply before the 15th; ordered elsewhere');
  await po(MedGroup.hospital, 18, pick(MedGroup.hospital, 4), receivedAfter: 2);
  await po(MedGroup.general, 7, pick(MedGroup.general, 5), receivedAfter: 3);
  await po(MedGroup.acute, 2,
      [for (final n in _onOrder) byName[n]!, ...pick(MedGroup.acute, 2)],
      notes: 'Urgent: Taxim-O and Montair LC running low');
  await po(MedGroup.chronic, 0, pick(MedGroup.chronic, 3), send: false, notes: 'Monthly top-up for chronic medicines');

  // 3. Prescriptions: dispense about three in four of those waiting, oldest first.
  var waiting = await db.query(Query(Col.prescriptions).eq('status', Vals.active).sort('created_at').take(500));
  if (waiting.isEmpty) waiting = await _createDemoPrescriptions(db, rnd, byName);
  final encounters = await db.byIds(Col.encounters, waiting.map((r) => r.strOrNull('encounter_id')));
  DateTime prescribedAt(Rec rx) {
    final e = encounters[rx.str('encounter_id')];
    final t = e?.date('ended_at') ?? e?.date('started_at');
    return t != null && t.isBefore(rx.createdAt) ? t : rx.createdAt;
  }

  waiting.sort((a, b) => prescribedAt(a).compareTo(prescribedAt(b)));
  final medicines = await db.byIds(Col.medicines, [for (final r in waiting) for (final i in r.maps('items')) i['medicine_id'] as String?]);
  final toDispense = (waiting.length * 0.75).round();
  for (final rx in waiting.take(toDispense)) {
    var at = prescribedAt(rx).add(Duration(minutes: 8 + rnd.nextInt(25)));
    if (at.isAfter(now)) at = now.subtract(const Duration(minutes: 2));
    try {
      await dispensePrescriptionAuto(db, rx, byName: by, at: at, medicines: medicines);
    } catch (_) {
      // Nothing in stock for this one; it stays in the queue.
    }
  }

  // 4. A week of counter sales.
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(60));
  final counter = [for (final n in _counterItems) ?byName[n]];
  final sales = <Rec>[];
  for (var i = 0; i < 15 && patients.isNotEmpty && counter.isNotEmpty; i++) {
    final daysAgo = i < 4 ? 0 : 1 + (i % 6);
    var at = today.subtract(Duration(days: daysAgo)).add(Duration(hours: 9 + rnd.nextInt(11), minutes: rnd.nextInt(60)));
    if (at.isAfter(now)) at = now.subtract(Duration(minutes: 5 + i * 7));
    final patient = patients[rnd.nextInt(patients.length)];
    final chosen = ([...counter]..shuffle(rnd)).take(1 + rnd.nextInt(3));
    final stock = PharmacyService.summarize(chosen, await PharmacyService.batchesWithStock(db), now: at);
    final lines = <DispenseLine>[];
    for (final p in chosen) {
      final countable = {'tablet', 'capsule'}.contains(p.str('unit'));
      final fefo = PharmacyService.pickFefo(stock[p.id]!.batches, countable ? 10 : 1, now: at);
      if (fefo.picks.isNotEmpty) lines.add(DispenseLine(product: p, picks: fefo.picks));
    }
    if (lines.isEmpty) continue;
    sales.add(await PharmacyService.dispense(db, patientId: patient.id, lines: lines, byName: by, at: at));
  }

  // 5. One return, two honest adjustments, and things for the agents and the board.
  if (sales.length > 3) {
    final s = sales[3];
    final it = s.maps('items').first;
    final q = (it['qty'] as num).toInt();
    await PharmacyService.returnItems(db,
        dispense: s,
        qtyByLine: {0: q > 4 ? 5 : q},
        reason: 'Bought extra by mistake; strip unopened',
        byName: by,
        at: s.date('dispensed_at')!.add(const Duration(hours: 2)));
  }
  final allBatches = await PharmacyService.batchesWithStock(db);
  Rec? batchOf(String name) {
    final p = byName[name];
    if (p == null) return null;
    final list = allBatches.where((b) => b.str('product_id') == p.id && b.integer('qty_on_hand') > 0).toList()
      ..sort((a, b) => b.integer('qty_on_hand').compareTo(a.integer('qty_on_hand')));
    return list.isEmpty ? null : list.first;
  }

  final syrup = batchOf('Calpol 250 Syrup');
  if (syrup != null) {
    await PharmacyService.applyAdjustment(db,
        batchId: syrup.id, qtyDelta: -2, reason: 'Breakage: 2 bottles broken while unpacking', byName: by,
        at: today.subtract(const Duration(days: 9)).add(const Duration(hours: 16)));
  }
  final dolo = batchOf('Dolo 650');
  if (dolo != null) {
    await PharmacyService.applyAdjustment(db,
        batchId: dolo.id, qtyDelta: 3, reason: 'Physical count: 3 loose tablets found in the return tray', byName: by,
        at: today.subtract(const Duration(days: 4)).add(const Duration(hours: 18)));
  }
  // A big adjustment waiting for the board (requests above ₹5,000 need approval).
  final lantus = batchOf('Lantus SoloStar');
  if (lantus != null && pharmacist != null && lantus.integer('qty_on_hand') >= 10) {
    final value = PharmacyService.adjustmentValue(lantus, -10);
    await db.insert(Col.approvals, {
      'type': 'pharmacy.adjustment',
      'status': 'pending',
      'title': 'Remove 10 Lantus SoloStar (batch ${lantus.str('batch_no')})',
      'amount_paise': value,
      'requested_by': pharmacist.id,
      'requested_by_name': by,
      'reason': 'Fridge temperature excursion overnight; pens discarded as per cold-chain policy',
      'subject_collection': PCol.batches,
      'subject_id': lantus.id,
      'payload': {'batch_id': lantus.id, 'qty_delta': -10, 'reason': 'Cold-chain failure: pens discarded'},
      'required_approvals': value > ctx.services.settings.highValueLimitPaise ? 2 : 1,
      'approvers': <Object?>[],
      'auto_approved': false,
    });
  }
  // Someone recorded a count but the batch was never updated: the integrity agent should notice.
  final odd = batchOf('Pan 40');
  if (odd != null) {
    await db.insert(PCol.movements, {
      'product_id': odd.str('product_id'),
      'batch_id': odd.id,
      'qty': -6,
      'type': MoveType.adjustment,
      'reason': 'Counted short at month end',
      'value_paise': -6 * odd.integer('cost_paise'),
      'by_name': by,
      'moved_at': today.subtract(const Duration(days: 2)).add(const Duration(hours: 19)),
    });
  }
}

/// Dispenses everything that can be matched and is in stock (used by the
/// demo; the counter screen does the same with a person confirming).
Future<Rec> dispensePrescriptionAuto(Db db, Rec rx,
    {required String byName, DateTime? at, Map<String, Rec> medicines = const {}}) async {
  final products = await PharmacyService.activeProducts(db);
  final meds = {...medicines, ...await db.byIds(Col.medicines, products.map((p) => p.strOrNull('medicine_id')))};
  final index = ProductIndex(products, medicines: meds);
  final batches = await PharmacyService.batchesWithStock(db);
  final stock = PharmacyService.summarize(index.all, batches, now: at);
  final lines = <DispenseLine>[];
  final taken = <String, int>{};
  for (final (i, item) in rx.maps('items').indexed) {
    final (product, _) = index.match(item, stock: stock);
    if (product == null) continue;
    final want = PharmacyService.remainingQty(item, unit: product.str('unit'));
    if (want <= 0) continue;
    final avail = [
      for (final b in stock[product.id]?.batches ?? const <Rec>[])
        b.copyWith({'qty_on_hand': b.integer('qty_on_hand') - (taken[b.id] ?? 0)})
    ];
    final fefo = PharmacyService.pickFefo(avail, want, now: at);
    if (fefo.picks.isEmpty) continue;
    for (final p in fefo.picks) {
      taken[p.batch.id] = (taken[p.batch.id] ?? 0) + p.qty;
    }
    lines.add(DispenseLine(product: product, picks: fefo.picks, rxIndex: i));
  }
  return PharmacyService.dispense(db, patientId: rx.str('patient_id'), prescription: rx, lines: lines, byName: byName, at: at);
}

/// Stand-in for OPD when it is not installed: short visits over the last
/// three days, each ending with a prescription.
Future<List<Rec>> _createDemoPrescriptions(Db db, Random rnd, Map<String, Rec> productsByName) async {
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(40));
  final doctors = {
    for (final u in await db.query(const Query(Col.users).eq('is_clinician', true).take(20))) u.str('username'): u
  };
  if (patients.isEmpty || doctors.isEmpty) return const [];
  final meds = {for (final m in await db.query(const Query(Col.medicines).take(5000))) m.str('name'): m};
  final now = DateTime.now();
  final today = startOfDay(now);
  final out = <Rec>[];
  for (final (n, (doctorName, items)) in _demoRx.indexed) {
    final doctor = doctors[doctorName] ?? doctors.values.first;
    // Oldest first: four visits two days ago, four yesterday, the rest today.
    final day = n < 4 ? 2 : (n < 8 ? 1 : 0);
    final slot = n < 8 ? n % 4 : n - 8;
    var start = today.subtract(Duration(days: day)).add(Duration(hours: 9, minutes: 35 * slot + rnd.nextInt(20)));
    if (day == 0) {
      // Today's visits end in the last few hours, so the queue has real waits.
      start = now.subtract(Duration(minutes: 30 + (13 - n) * 22 + rnd.nextInt(10)));
    }
    final end = start.add(Duration(minutes: 10 + rnd.nextInt(8)));
    // The penicillin-allergic patient gets the Augmentin prescription, so the
    // allergy check has something to catch.
    final patient = items.any((i) => i.$1.startsWith('Augmentin'))
        ? patients.firstWhere((p) => p.str('allergies').toLowerCase().contains('penicillin'), orElse: () => patients[n])
        : patients[(n * 3 + 1) % patients.length];
    final encounterId = db.newId();
    final rxItems = <Map<String, Object?>>[];
    for (final (name, dose, freq, days, instructions) in items) {
      final med = meds[name];
      final item = <String, Object?>{
        'medicine_id': med?.id,
        'drug_name': med == null ? '$name capsule' : name,
        'dose': dose,
        'frequency': freq,
        'duration_days': days,
        'route': switch (med?.str('form')) {
          'ointment' => 'Local',
          'drops' => 'Eye',
          'inhaler' => 'Inhalation',
          'injection' => 'IV',
          _ => 'Oral',
        },
        'instructions': instructions,
        'dispensed_qty': 0,
      };
      // Most doctors give a quantity; leave one out so the estimate is used.
      if (n % 5 != 2) {
        item['quantity'] = PharmacyService.prescribedQty({...item}, unit: med?.str('unit') ?? 'tablet');
      }
      rxItems.add(item);
    }
    final rxId = db.newId();
    await db.batch([
      InsertOp(
          Col.encounters,
          {
            'patient_id': patient.id,
            'type': Vals.opd,
            'status': Vals.closed,
            'doctor_id': doctor.id,
            'department': doctor.str('department'),
            'started_at': start,
            'ended_at': end,
            'source_module': 'pharmacy',
            'summary': 'OPD visit (demo)',
          },
          id: encounterId),
      InsertOp(
          Col.prescriptions,
          {
            'patient_id': patient.id,
            'encounter_id': encounterId,
            'doctor_id': doctor.id,
            'items': rxItems,
            'status': Vals.active,
          },
          id: rxId),
    ]);
    out.add((await db.get(Col.prescriptions, rxId))!);
  }
  return out;
}

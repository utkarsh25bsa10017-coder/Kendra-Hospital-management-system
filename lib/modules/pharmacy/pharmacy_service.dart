import 'dart:math' as math;

import 'package:kendra_hms/core/core.dart';

import 'pharmacy_schema.dart';

/// A quantity taken from one batch.
class BatchPick {
  const BatchPick(this.batch, this.qty);
  final Rec batch;
  final int qty;
}

class FefoResult {
  const FefoResult(this.picks, this.shortBy);
  final List<BatchPick> picks;

  /// How many units could not be found in usable (unexpired) stock.
  final int shortBy;
  int get picked => picks.fold(0, (a, p) => a + p.qty);
}

/// One line to dispense: a product and the batches it comes from.
class DispenseLine {
  const DispenseLine({required this.product, required this.picks, this.rxIndex});
  final Rec product;
  final List<BatchPick> picks;

  /// Index of the prescription item this line fills.
  final int? rxIndex;
  int get qty => picks.fold(0, (a, p) => a + p.qty);
}

/// One line of a goods receipt.
class ReceiptLine {
  const ReceiptLine({
    required this.productId,
    required this.name,
    required this.batchNo,
    required this.expiry,
    required this.qty,
    required this.costPaise,
    required this.mrpPaise,
  });
  final String productId;
  final String name;
  final String batchNo;
  final DateTime expiry;
  final int qty;
  final int costPaise;
  final int mrpPaise;
}

/// Stock position of one product, worked out from its batches.
class StockInfo {
  StockInfo(this.product);
  final Rec product;

  /// Usable (unexpired) units on the shelf.
  int onHand = 0;
  int expiredQty = 0;
  int valuePaise = 0; // usable stock at cost
  int expiredValuePaise = 0;
  int nearExpiryQty = 0;
  int nearExpiryValuePaise = 0;
  int negativeBatches = 0;
  DateTime? nearestExpiry; // earliest unexpired expiry with stock
  final batches = <Rec>[];

  int get reorderLevel => product.integer('reorder_level');
  bool get out => onHand <= 0;
  bool get low => onHand > 0 && onHand <= reorderLevel;
  bool get atOrBelowReorder => onHand <= reorderLevel && reorderLevel > 0;
  bool get nearExpiry => nearExpiryQty > 0;
  bool get expired => expiredQty > 0;
  int get mrpPaise => product.integer('mrp_paise');
}

/// Matches prescription items to products.
class ProductIndex {
  ProductIndex(List<Rec> products, {this.medicines = const {}}) {
    for (final p in products) {
      _byId[p.id] = p;
      final mid = p.strOrNull('medicine_id');
      if (mid != null) _byMedicine[mid] = p;
      _byName[PharmacyService.norm(p.str('name'))] = p;
      final g = PharmacyService.norm(p.str('generic_name'));
      if (g.isNotEmpty) _byGeneric.putIfAbsent(g, () => []).add(p);
    }
    _names = _byName.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  final Map<String, Rec> medicines;
  final _byId = <String, Rec>{};
  final _byMedicine = <String, Rec>{};
  final _byName = <String, Rec>{};
  final _byGeneric = <String, List<Rec>>{};
  late final List<String> _names;

  Iterable<Rec> get all => _byId.values;
  Rec? byId(String? id) => id == null ? null : _byId[id];

  /// The product for a prescription item and how it was found:
  /// 'medicine' (same medicine), 'name', 'generic' or null.
  (Rec?, String?) match(Map<String, Object?> item, {Map<String, StockInfo> stock = const {}}) {
    final pid = item['product_id'] as String?;
    if (pid != null && _byId[pid] != null) return (_byId[pid], 'medicine');
    final mid = item['medicine_id'] as String?;
    if (mid != null && _byMedicine[mid] != null) return (_byMedicine[mid], 'medicine');
    final med = mid == null ? null : medicines[mid];
    final name = PharmacyService.norm((item['drug_name'] as String?) ?? med?.str('name') ?? '');
    if (name.isNotEmpty) {
      final exact = _byName[name];
      if (exact != null) return (exact, 'name');
      for (final n in _names) {
        if (n.length >= 4 && name.length >= 4 && (name.startsWith(n) || n.startsWith(name))) {
          return (_byName[n], 'name');
        }
      }
    }
    // Generic: "Paracetamol 650" → a product whose generic is paracetamol.
    final generic = PharmacyService.norm((item['generic_name'] as String?) ?? med?.str('generic_name') ?? '');
    final candidates = <Rec>[];
    for (final e in _byGeneric.entries) {
      if ((generic.isNotEmpty && e.key == generic) || (name.isNotEmpty && name.startsWith(e.key))) {
        candidates.addAll(e.value);
      }
    }
    if (candidates.isEmpty) return (null, null);
    // Prefer the same strength, the right route (injection or not), then
    // whatever is in stock; ties go by name so the choice is stable.
    final digits = RegExp(r'\d+').allMatches(name).map((m) => m.group(0)!).toSet();
    final route = '${item['route'] ?? ''}'.toLowerCase();
    final wantsInjection = RegExp(r'\b(iv|im|sc|inj|injection|intravenous|intramuscular|subcut)').hasMatch(route);
    int score(Rec p) {
      var s = 0;
      final m = medicines[p.str('medicine_id')];
      final pn = PharmacyService.norm('${p.str('name')} ${m?.str('strength') ?? ''}');
      if (digits.isNotEmpty && digits.every(pn.contains)) s += 4;
      final isInjection = m?.str('form') == 'injection' || {'vial', 'ampoule'}.contains(p.str('unit'));
      if (isInjection == wantsInjection) s += 2;
      if ((stock[p.id]?.onHand ?? 0) > 0) s += 1;
      return s;
    }

    final scores = {for (final c in candidates) c.id: score(c)};
    candidates.sort((a, b) {
      final c = scores[b.id]!.compareTo(scores[a.id]!);
      return c != 0 ? c : a.str('name').compareTo(b.str('name'));
    });
    return (candidates.first, 'generic');
  }

  /// Other products with the same generic (for substitution).
  List<Rec> alternatives(Rec product) {
    final g = PharmacyService.norm(product.str('generic_name'));
    if (g.isEmpty) return const [];
    return [for (final p in _byGeneric[g] ?? const <Rec>[]) if (p.id != product.id) p];
  }
}

/// Stock rules shared by the screens, the agents and the demo seeder.
abstract final class PharmacyService {
  static const nearExpiryDays = 60;

  /// Adjustments worth more than this (at cost) need board approval.
  static const adjustApprovalPaise = 500000;

  static String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static bool isExpired(DateTime? expiry, DateTime now) => expiry != null && expiry.isBefore(startOfDay(now));

  static bool isNearExpiry(DateTime? expiry, DateTime now, [int days = nearExpiryDays]) =>
      expiry != null && !isExpired(expiry, now) && expiry.isBefore(startOfDay(now).add(Duration(days: days + 1)));

  /// Last day of the month, the way medicine packs print expiry ("EXP 08/27").
  static DateTime expiryFromMonth(int month, int year) => DateTime(year, month + 1, 0);

  static String expiryLabel(DateTime? d) {
    if (d == null) return '—';
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[d.month - 1]} ${d.year}';
  }

  /// Parses "08/27", "8/2027" or "08-27" into the last day of that month.
  static DateTime? parseExpiry(String s) {
    final m = RegExp(r'^\s*(\d{1,2})\s*[/\-. ]\s*(\d{2}|\d{4})\s*$').firstMatch(s);
    if (m == null) return null;
    final month = int.parse(m.group(1)!);
    var year = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    if (year < 100) year += 2000;
    return expiryFromMonth(month, year);
  }

  static String expiryInput(DateTime? d) =>
      d == null ? '' : '${d.month.toString().padLeft(2, '0')}/${(d.year % 100).toString().padLeft(2, '0')}';

  /// "PH-26-000123"
  static Future<String> nextNumber(Db db, String prefix) async {
    final n = await db.nextSequence('pharmacy.${prefix.toLowerCase()}');
    final yy = (DateTime.now().year % 100).toString().padLeft(2, '0');
    return '$prefix-$yy-${n.toString().padLeft(6, '0')}';
  }

  // ------------------------------------------------------------------ FEFO

  /// First-expiry-first-out: takes [qty] from the batch that expires first,
  /// then the next, skipping expired and empty batches.
  static FefoResult pickFefo(Iterable<Rec> batches, int qty, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final usable = batches.where((b) => b.integer('qty_on_hand') > 0 && !isExpired(b.date('expiry_date'), n)).toList()
      ..sort((a, b) {
        final ea = a.date('expiry_date') ?? DateTime(9999);
        final eb = b.date('expiry_date') ?? DateTime(9999);
        final c = ea.compareTo(eb);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    final picks = <BatchPick>[];
    var left = qty;
    for (final b in usable) {
      if (left <= 0) break;
      final take = math.min(left, b.integer('qty_on_hand'));
      picks.add(BatchPick(b, take));
      left -= take;
    }
    return FefoResult(picks, math.max(0, left));
  }

  /// Batches of one product that still have stock, earliest expiry first.
  static Future<List<Rec>> stockBatches(ReadDb db, String productId) => db.query(Query(PCol.batches)
      .eq('product_id', productId)
      .where('qty_on_hand', Op.neq, 0)
      .sort('expiry_date')
      .take(100));

  // ------------------------------------------------------------------ stock

  static Map<String, StockInfo> summarize(Iterable<Rec> products, Iterable<Rec> batches, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final out = {for (final p in products) p.id: StockInfo(p)};
    for (final b in batches) {
      final s = out[b.str('product_id')];
      if (s == null) continue;
      final q = b.integer('qty_on_hand');
      if (q == 0) continue;
      s.batches.add(b);
      if (q < 0) {
        s.negativeBatches++;
        continue;
      }
      final exp = b.date('expiry_date');
      final value = q * b.integer('cost_paise');
      if (isExpired(exp, n)) {
        s.expiredQty += q;
        s.expiredValuePaise += value;
        continue;
      }
      s.onHand += q;
      s.valuePaise += value;
      if (exp != null && (s.nearestExpiry == null || exp.isBefore(s.nearestExpiry!))) s.nearestExpiry = exp;
      if (isNearExpiry(exp, n)) {
        s.nearExpiryQty += q;
        s.nearExpiryValuePaise += value;
      }
    }
    return out;
  }

  static Future<List<Rec>> activeProducts(ReadDb db) =>
      db.query(const Query(PCol.products).eq('active', true).sort('name').take(5000));

  static Future<List<Rec>> batchesWithStock(ReadDb db) =>
      db.query(const Query(PCol.batches).where('qty_on_hand', Op.neq, 0).sort('expiry_date').take(20000));

  static Future<Map<String, StockInfo>> stock(ReadDb db, {DateTime? now}) async =>
      summarize(await activeProducts(db), await batchesWithStock(db), now: now);

  /// What to order for a product that is at or below its reorder level.
  static int suggestedQty(Rec product, int onHand) {
    final rq = product.integer('reorder_qty');
    if (rq > 0) return rq;
    return math.max(1, 2 * product.integer('reorder_level') - onHand);
  }

  // ------------------------------------------------------------------ prescriptions

  static const _countable = {'tablet', 'capsule', 'tab', 'cap', 'sachet', 'unit', 'piece', 'strip', 'ampoule', 'vial'};

  static double _num(String s) {
    final t = s.trim().replaceAll('½', '.5').replaceAll('¼', '.25');
    if (t.startsWith('.')) return double.tryParse('0$t') ?? 0;
    return double.tryParse(t) ?? 0;
  }

  /// Doses per day from "1-0-1", "BD", "TDS", "once daily"...
  static double dosesPerDay(String? frequency) {
    final f = (frequency ?? '').trim().toLowerCase();
    if (f.isEmpty) return 1;
    if (RegExp(r'^[\d½¼.]+(\s*-\s*[\d½¼.]+){1,4}$').hasMatch(f)) {
      return f.split('-').map(_num).fold<double>(0, (a, b) => a + b);
    }
    if (RegExp(r'\b(qid|qds|four times)\b').hasMatch(f)) return 4;
    if (RegExp(r'\b(tds|tid|thrice|three times)\b').hasMatch(f)) return 3;
    if (RegExp(r'\b(bd|bid|twice)\b').hasMatch(f)) return 2;
    if (RegExp(r'\b(weekly|once a week)\b').hasMatch(f)) return 1 / 7;
    return 1; // OD, HS, SOS, STAT, once daily...
  }

  /// Units a prescription item asks for: its quantity, or dose × frequency × days.
  static int prescribedQty(Map<String, Object?> item, {String? unit}) {
    final q = (item['quantity'] as num?)?.toInt() ?? 0;
    if (q > 0) return q;
    final u = (unit ?? '').toLowerCase();
    if (u.isNotEmpty && !_countable.contains(u)) return 1; // a bottle, tube, inhaler...
    final f = (item['frequency'] as String? ?? '').toLowerCase();
    final days = (item['duration_days'] as num?)?.toInt() ?? (f.contains('stat') ? 1 : 5);
    final doseText = (item['dose'] as String? ?? '1');
    final dm = RegExp(r'[\d½¼.]+').firstMatch(doseText);
    final dose = dm == null ? 1.0 : math.max(_num(dm.group(0)!), 0.25);
    return math.max(1, (dosesPerDay(f) * days * dose).ceil());
  }

  static int remainingQty(Map<String, Object?> item, {String? unit}) =>
      math.max(0, prescribedQty(item, unit: unit) - ((item['dispensed_qty'] as num?)?.toInt() ?? 0));

  static String statusAfter(List<Map<String, Object?>> items, String current) {
    final need = items.where((i) => prescribedQty(i, unit: i['unit'] as String?) > 0).toList();
    final got = need.where((i) => ((i['dispensed_qty'] as num?)?.toInt() ?? 0) > 0).length;
    if (need.isNotEmpty && need.every((i) => remainingQty(i, unit: i['unit'] as String?) == 0)) return Vals.dispensed;
    if (got > 0) return Vals.partiallyDispensed;
    return current;
  }

  // ------------------------------------------------------------------ allergies

  static const _allergyClasses = <String, List<String>>{
    'penicillin': ['amoxicillin', 'amoxycillin', 'ampicillin', 'cloxacillin', 'piperacillin', 'penicillin', 'clavulan'],
    'sulfa': ['sulfamethoxazole', 'cotrimoxazole', 'sulfasalazine', 'sulphamethoxazole'],
    'cephalosporin': ['cefixime', 'ceftriaxone', 'cefuroxime', 'cefpodoxime', 'cephalexin', 'cefalexin'],
    'nsaid': ['ibuprofen', 'diclofenac', 'aceclofenac', 'naproxen', 'aspirin', 'mefenamic'],
    'aspirin': ['aspirin', 'acetylsalicylic'],
  };

  /// Medicines in [lines] that clash with the patient's recorded allergies.
  /// [lines] are (display name, generic name).
  static List<String> allergyConflicts(String allergies, Iterable<(String, String)> lines) {
    final a = allergies.toLowerCase();
    if (a.trim().isEmpty) return const [];
    final words = a.split(RegExp(r'[^a-z]+')).where((w) => w.length >= 4).toSet();
    final out = <String>[];
    for (final (name, generic) in lines) {
      final text = '$name $generic'.toLowerCase();
      String? why;
      for (final w in words) {
        if (text.contains(w)) {
          why = '$name — patient is allergic to ${titleCase(w)}';
          break;
        }
        for (final e in _allergyClasses.entries) {
          if ((w.startsWith(e.key) || e.key.startsWith(w)) && e.value.any(text.contains)) {
            why = '$name may contain a ${e.key} (allergy: ${titleCase(w)})';
            break;
          }
        }
        if (why != null) break;
      }
      if (why != null) out.add(why);
    }
    return out;
  }

  // ------------------------------------------------------------------ dispensing

  /// Dispenses [lines] in one all-or-nothing write: the dispense record, a
  /// movement and batch update per batch, a pending charge per line and the
  /// prescription's dispensed quantities and status.
  static Future<Rec> dispense(
    Db db, {
    required String patientId,
    required List<DispenseLine> lines,
    required String byName,
    Rec? prescription,
    String? encounterId,
    String? doctorId,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    final todo = lines.where((l) => l.qty > 0).toList();
    if (todo.isEmpty) throw ValidationException('Choose at least one medicine to dispense');

    // Fresh batch figures, so two counters can't sell the same strip twice.
    final fresh = await db.byIds(PCol.batches, [for (final l in todo) for (final p in l.picks) p.batch.id]);
    final takeByBatch = <String, int>{};
    for (final l in todo) {
      for (final p in l.picks.where((p) => p.qty > 0)) {
        final b = fresh[p.batch.id];
        if (b == null || b.str('product_id') != l.product.id) {
          throw ValidationException('Batch ${p.batch.str('batch_no')} is not stock of ${l.product.str('name')}');
        }
        if (isExpired(b.date('expiry_date'), when)) {
          throw ValidationException('Batch ${b.str('batch_no')} of ${l.product.str('name')} has expired');
        }
        takeByBatch[b.id] = (takeByBatch[b.id] ?? 0) + p.qty;
      }
    }
    for (final e in takeByBatch.entries) {
      final b = fresh[e.key]!;
      final have = b.integer('qty_on_hand');
      if (e.value > have) {
        final name = todo.firstWhere((l) => l.product.id == b.str('product_id')).product.str('name');
        throw ValidationException('Only $have of $name left in batch ${b.str('batch_no')}');
      }
    }

    final id = db.newId();
    final number = await nextNumber(db, 'PH');
    final rx = prescription;
    final encounter = encounterId ?? rx?.strOrNull('encounter_id');
    final doctor = doctorId ?? rx?.strOrNull('doctor_id');
    final items = <Map<String, Object?>>[];
    final ops = <WriteOp>[];
    var total = 0;
    for (final l in todo) {
      for (final p in l.picks.where((p) => p.qty > 0)) {
        final b = fresh[p.batch.id]!;
        final mrp = b.integer('mrp_paise', l.product.integer('mrp_paise'));
        final amount = mrp * p.qty;
        final line = items.length;
        total += amount;
        items.add({
          'product_id': l.product.id,
          'name': l.product.str('name'),
          'sku': l.product.str('sku'),
          'batch_id': b.id,
          'batch_no': b.str('batch_no'),
          'expiry': b.date('expiry_date')?.toIso8601String(),
          'qty': p.qty,
          'mrp_paise': mrp,
          'amount_paise': amount,
          'rx_index': ?l.rxIndex,
        });
        ops.add(InsertOp(PCol.movements, {
          'product_id': l.product.id,
          'batch_id': b.id,
          'qty': -p.qty,
          'type': MoveType.dispense,
          'ref_collection': PCol.dispenses,
          'ref_id': id,
          'patient_id': patientId,
          'value_paise': -p.qty * b.integer('cost_paise'),
          'by_name': byName,
          'moved_at': when,
        }));
        ops.add(InsertOp(Col.charges, {
          'patient_id': patientId,
          'encounter_id': encounter,
          'service_code': l.product.str('sku'),
          'description': '${l.product.str('name')} (batch ${b.str('batch_no')})',
          'category': Vals.pharmacy,
          'quantity': p.qty,
          'unit_price_paise': mrp,
          'amount_paise': amount,
          'status': Vals.pending,
          'source_module': 'pharmacy',
          'source_collection': PCol.dispenses,
          'source_id': '$id:$line',
          'service_date': when,
          'ordered_by': doctor,
        }));
      }
    }
    for (final e in takeByBatch.entries) {
      final b = fresh[e.key]!;
      ops.add(UpdateOp(PCol.batches, b.id, {'qty_on_hand': b.integer('qty_on_hand') - e.value},
          expectedVersion: b.version));
    }
    final record = {
      'number': number,
      'patient_id': patientId,
      'encounter_id': encounter,
      'prescription_id': rx?.id,
      'doctor_id': doctor,
      'kind': rx == null ? DispenseKind.counter : DispenseKind.prescription,
      'items': items,
      'total_paise': total,
      'dispensed_by_name': byName,
      'dispensed_at': when,
    };
    ops.insert(0, InsertOp(PCol.dispenses, record, id: id));

    if (rx != null) {
      final rxItems = [for (final i in rx.maps('items')) {...i}];
      for (final l in todo) {
        final i = l.rxIndex;
        if (i == null || i < 0 || i >= rxItems.length) continue;
        rxItems[i]['dispensed_qty'] = ((rxItems[i]['dispensed_qty'] as num?)?.toInt() ?? 0) + l.qty;
        rxItems[i]['unit'] ??= l.product.strOrNull('unit');
      }
      ops.add(UpdateOp(
          Col.prescriptions,
          rx.id,
          {
            'items': rxItems,
            'status': statusAfter(rxItems, rx.str('status')),
            'dispensed_at': when,
          },
          expectedVersion: rx.version));
    }
    final saved = await db.batch(ops);
    return saved.first;
  }

  /// Quantities of each line of [dispense] already returned.
  static Future<Map<int, int>> returnedSoFar(ReadDb db, String dispenseId) async {
    final out = <int, int>{};
    for (final r in await db.query(Query(PCol.dispenses).eq('return_of', dispenseId).take(100))) {
      for (final i in r.maps('items')) {
        final idx = (i['of_index'] as num?)?.toInt();
        if (idx != null) out[idx] = (out[idx] ?? 0) + ((i['qty'] as num?)?.toInt() ?? 0);
      }
    }
    return out;
  }

  /// Takes medicines back onto the shelf. Pending charges for whole lines
  /// are cancelled; anything else gets a negative charge so the bill is
  /// credited (financial records are never edited after billing).
  static Future<Rec> returnItems(
    Db db, {
    required Rec dispense,
    required Map<int, int> qtyByLine,
    required String reason,
    required String byName,
    DateTime? at,
  }) async {
    if (dispense.str('kind') == DispenseKind.returned) throw ValidationException('This is already a return');
    if (reason.trim().isEmpty) throw ValidationException('Give a reason for the return');
    final when = at ?? DateTime.now();
    final items = dispense.maps('items');
    final already = await returnedSoFar(db, dispense.id);
    final wanted = {for (final e in qtyByLine.entries) if (e.value > 0) e.key: e.value};
    if (wanted.isEmpty) throw ValidationException('Enter how many of each medicine came back');
    for (final e in wanted.entries) {
      if (e.key < 0 || e.key >= items.length) throw ValidationException('Unknown line');
      final left = ((items[e.key]['qty'] as num?)?.toInt() ?? 0) - (already[e.key] ?? 0);
      if (e.value > left) throw ValidationException('Only $left of ${items[e.key]['name']} can be returned');
    }
    final batches = await db.byIds(PCol.batches, [for (final i in wanted.keys) items[i]['batch_id'] as String?]);
    final charges = {
      for (final c in await db.query(Query(Col.charges)
          .isIn('source_id', [for (final i in wanted.keys) '${dispense.id}:$i'])
          .take(100)))
        c.str('source_id'): c,
    };
    final id = db.newId();
    final number = await nextNumber(db, 'PH');
    final outItems = <Map<String, Object?>>[];
    final ops = <WriteOp>[];
    final addByBatch = <String, int>{};
    var total = 0;
    for (final e in wanted.entries) {
      final it = items[e.key];
      final b = batches[it['batch_id']];
      if (b == null) throw ValidationException('Batch ${it['batch_no']} no longer exists');
      final mrp = (it['mrp_paise'] as num?)?.toInt() ?? 0;
      final amount = mrp * e.value;
      final line = outItems.length;
      total -= amount;
      outItems.add({...it, 'qty': e.value, 'amount_paise': -amount, 'of_index': e.key});
      addByBatch[b.id] = (addByBatch[b.id] ?? 0) + e.value;
      ops.add(InsertOp(PCol.movements, {
        'product_id': it['product_id'],
        'batch_id': b.id,
        'qty': e.value,
        'type': MoveType.returned,
        'ref_collection': PCol.dispenses,
        'ref_id': id,
        'reason': reason,
        'patient_id': dispense.strOrNull('patient_id'),
        'value_paise': e.value * b.integer('cost_paise'),
        'by_name': byName,
        'moved_at': when,
      }));
      final charge = charges['${dispense.id}:${e.key}'];
      final wholeLine = (already[e.key] ?? 0) == 0 && e.value == ((it['qty'] as num?)?.toInt() ?? 0);
      if (charge != null && charge.str('status') == Vals.pending && wholeLine) {
        ops.add(UpdateOp(Col.charges, charge.id, {'status': Vals.cancelled, 'cancel_reason': 'Returned: $reason'},
            expectedVersion: charge.version));
      } else {
        ops.add(InsertOp(Col.charges, {
          'patient_id': dispense.str('patient_id'),
          'encounter_id': dispense.strOrNull('encounter_id'),
          'service_code': it['sku'] ?? charge?.strOrNull('service_code'),
          'description': 'Return: ${it['name']} (batch ${it['batch_no']})',
          'category': Vals.pharmacy,
          'quantity': -e.value,
          'unit_price_paise': mrp,
          'amount_paise': -amount,
          'status': Vals.pending,
          'source_module': 'pharmacy',
          'source_collection': PCol.dispenses,
          'source_id': '$id:$line',
          'service_date': when,
          'ordered_by': dispense.strOrNull('doctor_id'),
        }));
      }
    }
    for (final e in addByBatch.entries) {
      final b = batches[e.key]!;
      ops.add(UpdateOp(PCol.batches, b.id, {'qty_on_hand': b.integer('qty_on_hand') + e.value},
          expectedVersion: b.version));
    }
    ops.insert(
        0,
        InsertOp(
            PCol.dispenses,
            {
              'number': number,
              'patient_id': dispense.strOrNull('patient_id'),
              'encounter_id': dispense.strOrNull('encounter_id'),
              'prescription_id': dispense.strOrNull('prescription_id'),
              'doctor_id': dispense.strOrNull('doctor_id'),
              'kind': DispenseKind.returned,
              'items': outItems,
              'total_paise': total,
              'dispensed_by_name': byName,
              'dispensed_at': when,
              'return_of': dispense.id,
              'reason': reason,
            },
            id: id));
    return (await db.batch(ops)).first;
  }

  // ------------------------------------------------------------------ receiving

  /// Goods receipt: new batches (or more of an existing batch), a receipt
  /// movement per line and the purchase order marked received.
  static Future<Rec> receive(
    Db db, {
    required String supplierId,
    required List<ReceiptLine> lines,
    required String byName,
    String? orderId,
    String? supplierInvoiceNo,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    if (lines.isEmpty) throw ValidationException('Add at least one line');
    for (final l in lines) {
      if (l.batchNo.trim().isEmpty) throw ValidationException('Enter the batch number for ${l.name}');
      if (l.qty <= 0) throw ValidationException('Enter the quantity received for ${l.name}');
      if (l.costPaise < 0 || l.mrpPaise < 0) throw ValidationException('Prices cannot be negative');
      if (isExpired(l.expiry, when)) throw ValidationException('${l.name} batch ${l.batchNo} has already expired');
    }
    final existing = <String, Rec>{};
    final productIds = lines.map((l) => l.productId).toSet();
    for (final b in await db.query(Query(PCol.batches).isIn('product_id', productIds).take(5000))) {
      existing['${b.str('product_id')}|${b.str('batch_no').trim().toUpperCase()}'] = b;
    }
    final id = db.newId();
    final number = await nextNumber(db, 'GRN');
    final ops = <WriteOp>[];
    final items = <Map<String, Object?>>[];
    final newBatches = <String, (String, Map<String, Object?>)>{}; // key -> (id, data)
    final addToExisting = <String, int>{};
    var total = 0;
    for (final l in lines) {
      final key = '${l.productId}|${l.batchNo.trim().toUpperCase()}';
      final old = existing[key];
      String batchId;
      if (old != null) {
        batchId = old.id;
        addToExisting[old.id] = (addToExisting[old.id] ?? 0) + l.qty;
      } else if (newBatches[key] != null) {
        batchId = newBatches[key]!.$1;
        final d = newBatches[key]!.$2;
        d['qty_received'] = (d['qty_received'] as int) + l.qty;
        d['qty_on_hand'] = (d['qty_on_hand'] as int) + l.qty;
      } else {
        batchId = db.newId();
        newBatches[key] = (
          batchId,
          {
            'product_id': l.productId,
            'batch_no': l.batchNo.trim().toUpperCase(),
            'expiry_date': l.expiry,
            'mrp_paise': l.mrpPaise,
            'cost_paise': l.costPaise,
            'qty_received': l.qty,
            'qty_on_hand': l.qty,
            'supplier_id': supplierId,
            'receipt_id': id,
          }
        );
      }
      final amount = l.qty * l.costPaise;
      total += amount;
      items.add({
        'product_id': l.productId,
        'name': l.name,
        'batch_id': batchId,
        'batch_no': l.batchNo.trim().toUpperCase(),
        'expiry': l.expiry.toIso8601String(),
        'qty': l.qty,
        'cost_paise': l.costPaise,
        'mrp_paise': l.mrpPaise,
        'amount_paise': amount,
      });
      ops.add(InsertOp(PCol.movements, {
        'product_id': l.productId,
        'batch_id': batchId,
        'qty': l.qty,
        'type': MoveType.receipt,
        'ref_collection': PCol.receipts,
        'ref_id': id,
        'value_paise': amount,
        'by_name': byName,
        'moved_at': when,
      }));
    }
    final head = <WriteOp>[
      InsertOp(PCol.receipts, {
        'number': number,
        'supplier_id': supplierId,
        'order_id': orderId,
        'supplier_invoice_no': supplierInvoiceNo?.trim(),
        'items': items,
        'total_paise': total,
        'received_at': when,
        'received_by_name': byName,
      }, id: id),
      for (final e in newBatches.values) InsertOp(PCol.batches, e.$2, id: e.$1),
    ];
    for (final e in addToExisting.entries) {
      final b = existing.values.firstWhere((x) => x.id == e.key);
      ops.add(UpdateOp(
          PCol.batches,
          b.id,
          {
            'qty_on_hand': b.integer('qty_on_hand') + e.value,
            'qty_received': b.integer('qty_received') + e.value,
          },
          expectedVersion: b.version));
    }
    final lastCost = <String, int>{for (final l in lines) l.productId: l.costPaise};
    for (final e in lastCost.entries) {
      ops.add(UpdateOp(PCol.products, e.key, {'purchase_price_paise': e.value}));
    }
    if (orderId != null) {
      ops.add(UpdateOp(PCol.orders, orderId, {'status': PoStatus.received, 'received_at': when}));
    }
    return (await db.batch([...head, ...ops])).first;
  }

  // ------------------------------------------------------------------ adjustments

  static int adjustmentValue(Rec batch, int qtyDelta) => qtyDelta.abs() * batch.integer('cost_paise');

  /// Corrects a batch after a count, damage or breakage. Always leaves a
  /// movement with the reason.
  static Future<String> applyAdjustment(
    Db db, {
    required String batchId,
    required int qtyDelta,
    required String reason,
    required String byName,
    String? approvalId,
    DateTime? at,
  }) async {
    if (qtyDelta == 0) throw ValidationException('Enter how many to add or remove');
    if (reason.trim().isEmpty) throw ValidationException('A reason is required for every stock adjustment');
    final b = await db.get(PCol.batches, batchId);
    if (b == null) throw ValidationException('Batch not found');
    final now = b.integer('qty_on_hand') + qtyDelta;
    if (now < 0) throw ValidationException('Only ${b.integer('qty_on_hand')} on hand in batch ${b.str('batch_no')}');
    final product = await db.get(PCol.products, b.str('product_id'));
    await db.batch([
      InsertOp(PCol.movements, {
        'product_id': b.str('product_id'),
        'batch_id': b.id,
        'qty': qtyDelta,
        'type': MoveType.adjustment,
        'ref_collection': approvalId == null ? null : Col.approvals,
        'ref_id': approvalId,
        'reason': reason.trim(),
        'value_paise': qtyDelta * b.integer('cost_paise'),
        'by_name': byName,
        'moved_at': at ?? DateTime.now(),
      }),
      UpdateOp(PCol.batches, b.id, {'qty_on_hand': now}, expectedVersion: b.version),
    ]);
    final sign = qtyDelta > 0 ? '+' : '−';
    return 'Adjusted ${product?.str('name') ?? 'stock'} batch ${b.str('batch_no')} by $sign${qtyDelta.abs()} (now $now)';
  }

  /// Applies a small adjustment at once; one worth more than
  /// [adjustApprovalPaise] goes to the board as a `pharmacy.adjustment`
  /// approval. Returns (applied, message).
  static Future<(bool, String)> adjustOrRequest(
    AppServices app, {
    required Rec batch,
    required int qtyDelta,
    required String reason,
    String productName = 'stock',
  }) async {
    if (reason.trim().isEmpty) throw ValidationException('A reason is required for every stock adjustment');
    if (qtyDelta < 0 && -qtyDelta > batch.integer('qty_on_hand')) {
      throw ValidationException('Only ${batch.integer('qty_on_hand')} on hand in batch ${batch.str('batch_no')}');
    }
    final value = adjustmentValue(batch, qtyDelta);
    if (value <= adjustApprovalPaise) {
      final msg = await applyAdjustment(app.db,
          batchId: batch.id, qtyDelta: qtyDelta, reason: reason, byName: app.auth.session?.displayName ?? 'Pharmacist');
      return (true, msg);
    }
    final out = await app.approvals.request(
      type: 'pharmacy.adjustment',
      title: '${qtyDelta > 0 ? 'Add' : 'Remove'} ${qtyDelta.abs()} $productName (batch ${batch.str('batch_no')})',
      amountPaise: value,
      reason: reason.trim(),
      subjectCollection: PCol.batches,
      subjectId: batch.id,
      payload: {'batch_id': batch.id, 'qty_delta': qtyDelta, 'reason': reason.trim()},
    );
    if (out.applied) return (true, out.result);
    return (false, 'Sent for approval: adjustments over ${formatMoney(adjustApprovalPaise)} need the board');
  }

  /// Writes off expired batches at once when small, otherwise asks the board
  /// (`pharmacy.writeoff`). Returns (applied, message).
  static Future<(bool, String)> writeOffOrRequest(AppServices app, List<Rec> batches, {String productName = 'stock'}) async {
    final now = DateTime.now();
    final expired = batches.where((b) => b.integer('qty_on_hand') > 0 && isExpired(b.date('expiry_date'), now)).toList();
    if (expired.isEmpty) throw ValidationException('No expired stock to write off');
    final value = expired.fold<int>(0, (a, b) => a + b.integer('qty_on_hand') * b.integer('cost_paise'));
    if (value <= adjustApprovalPaise) {
      return (
        true,
        await writeOffExpired(app.db, expired.map((b) => b.id), byName: app.auth.session?.displayName ?? 'Pharmacist')
      );
    }
    final out = await app.approvals.request(
      type: 'pharmacy.writeoff',
      title: 'Write off expired $productName (${plural(expired.length, 'batch', 'batches')})',
      amountPaise: value,
      reason: 'Expired',
      subjectCollection: PCol.batches,
      subjectId: expired.first.id,
      payload: {'batch_ids': [for (final b in expired) b.id]},
    );
    if (out.applied) return (true, out.result);
    return (false, 'Sent to the board for approval');
  }

  /// Takes expired batches off the books. Batches that are no longer expired
  /// or already empty are skipped.
  static Future<String> writeOffExpired(
    Db db,
    Iterable<String> batchIds, {
    required String byName,
    String reason = 'Expired',
    String? approvalId,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    final batches = await db.byIds(PCol.batches, batchIds);
    final ops = <WriteOp>[];
    var value = 0;
    var count = 0;
    for (final b in batches.values) {
      final q = b.integer('qty_on_hand');
      if (q <= 0 || !isExpired(b.date('expiry_date'), when)) continue;
      count++;
      value += q * b.integer('cost_paise');
      ops.add(InsertOp(PCol.movements, {
        'product_id': b.str('product_id'),
        'batch_id': b.id,
        'qty': -q,
        'type': MoveType.expiryWriteoff,
        'ref_collection': approvalId == null ? null : Col.approvals,
        'ref_id': approvalId,
        'reason': '$reason (expiry ${expiryLabel(b.date('expiry_date'))})',
        'value_paise': -q * b.integer('cost_paise'),
        'by_name': byName,
        'moved_at': when,
      }));
      ops.add(UpdateOp(PCol.batches, b.id, {'qty_on_hand': 0}, expectedVersion: b.version));
    }
    if (count == 0) return 'Nothing to write off: those batches are no longer expired stock on the shelf';
    await db.batch(ops);
    return 'Wrote off ${plural(count, 'expired batch', 'expired batches')} worth ${formatMoney(value)} at cost';
  }

  // ------------------------------------------------------------------ purchase orders

  static Future<Rec> createOrder(
    Db db, {
    required String? supplierId,
    required List<Map<String, Object?>> items,
    bool fromProposal = false,
    String? notes,
    DateTime? at,
  }) async {
    final clean = [
      for (final i in items)
        if (((i['qty'] as num?)?.toInt() ?? 0) > 0)
          {
            'product_id': i['product_id'],
            'name': i['name'],
            'qty': (i['qty'] as num).toInt(),
            'cost_paise': (i['cost_paise'] as num?)?.toInt() ?? 0,
          }
    ];
    if (clean.isEmpty) throw ValidationException('Add at least one medicine with a quantity');
    final number = await nextNumber(db, 'PO');
    return db.insert(PCol.orders, {
      'number': number,
      'supplier_id': supplierId,
      'status': PoStatus.draft,
      'items': clean,
      'total_paise': orderTotal(clean),
      'raised_at': at ?? DateTime.now(),
      'from_proposal': fromProposal,
      'notes': notes,
    });
  }

  static int orderTotal(List<Map<String, Object?>> items) => items.fold(
      0, (a, i) => a + ((i['qty'] as num?)?.toInt() ?? 0) * ((i['cost_paise'] as num?)?.toInt() ?? 0));

  static Future<Rec> markOrdered(Db db, Rec order, {int leadDays = 3, DateTime? at}) {
    if (order.str('status') != PoStatus.draft) throw ValidationException('Only a draft can be sent');
    final when = at ?? DateTime.now();
    return db.update(
        PCol.orders,
        order.id,
        {
          'status': PoStatus.ordered,
          'ordered_at': when,
          'expected_at': when.add(Duration(days: leadDays <= 0 ? 3 : leadDays)),
        },
        expectedVersion: order.version);
  }

  static Future<Rec> cancelOrder(Db db, Rec order, String reason) {
    if (order.str('status') == PoStatus.received) throw ValidationException('A received order cannot be cancelled');
    return db.update(PCol.orders, order.id, {'status': PoStatus.cancelled, 'cancel_reason': reason},
        expectedVersion: order.version);
  }

  /// Plain-text order to send to the supplier (WhatsApp, email).
  static String orderText(Rec order, Rec? supplier, String hospital) {
    final b = StringBuffer()
      ..writeln('Purchase order ${order.str('number')}')
      ..writeln('From: $hospital')
      ..writeln('To: ${supplier?.str('name') ?? ''}')
      ..writeln();
    for (final (i, it) in order.maps('items').indexed) {
      b.writeln('${i + 1}. ${it['name']} — ${it['qty']}');
    }
    b
      ..writeln()
      ..writeln('Estimated value: ${formatMoney(order.integer('total_paise'))}');
    return b.toString();
  }

  /// Plain-text dispense slip.
  static String dispenseText(Rec d, {String patient = '', String hospital = ''}) {
    final b = StringBuffer()
      ..writeln(hospital)
      ..writeln('${d.str('kind') == DispenseKind.returned ? 'Return' : 'Pharmacy'} ${d.str('number')} · ${formatDateTime(d.date('dispensed_at'))}')
      ..writeln(patient)
      ..writeln();
    for (final it in d.maps('items')) {
      b.writeln('${it['name']} · batch ${it['batch_no']} · exp ${expiryLabel(DateTime.tryParse('${it['expiry']}'))}'
          ' · ${it['qty']} × ${formatMoney((it['mrp_paise'] as num?)?.toInt())} = ${formatMoney((it['amount_paise'] as num?)?.toInt())}');
    }
    b
      ..writeln()
      ..writeln('Total ${formatMoney(d.integer('total_paise'))}');
    return b.toString();
  }

  /// A small stable hash (FNV-1a) for proposal keys.
  static String hashOf(Iterable<String> parts) {
    var h = 0x811c9dc5;
    for (final c in (parts.toList()..sort()).join('|').codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }
}

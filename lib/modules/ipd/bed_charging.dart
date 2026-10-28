import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kendra_hms/core/core.dart';

import 'bed_days.dart';
import 'ipd_schema.dart';

/// Wards and price-list entries needed to price bed-days.
class BedPricing {
  BedPricing(this.wards, this.services);

  /// By ward id (archived ones included, so old stays still price).
  final Map<String, Rec> wards;

  /// By service code.
  final Map<String, Rec> services;

  static Future<BedPricing> load(ReadDb db) async {
    final wards = {for (final w in await db.query(const Query(IpdCol.wards).withArchived().take(1000))) w.id: w};
    final codes = {for (final w in wards.values) ...[bedCode(w), nursingCode(w)]};
    final services = codes.isEmpty
        ? <String, Rec>{}
        : {
            for (final s in await db.query(Query(Col.services).isIn('code', codes.toList()).withArchived().take(1000)))
              s.str('code'): s,
          };
    return BedPricing(wards, services);
  }

  static String bedCode(Rec ward) => ward.strOrNull('bed_service_code') ?? defaultBedCode(ward.str('kind'));
  static String nursingCode(Rec ward) => ward.strOrNull('nursing_service_code') ?? defaultNursingCode(ward.str('kind'));

  String wardName(String wardId) => wards[wardId]?.str('name') ?? 'Ward';

  /// Service code and price of one bed-day item ('bed' or 'nursing') in a
  /// ward, or null when the ward or its price is not set up.
  (String, int)? price(String wardId, String kind) {
    final w = wards[wardId];
    if (w == null) return null;
    final code = kind == BedCharging.bed ? bedCode(w) : nursingCode(w);
    final s = services[code];
    if (s == null) return null;
    return (code, s.integer('price_paise'));
  }

  /// Bed + nursing price of one day in a ward (0 when not set up).
  int dayPrice(String wardId) => (price(wardId, BedCharging.bed)?.$2 ?? 0) + (price(wardId, BedCharging.nursing)?.$2 ?? 0);
}

/// What posting would write for one admission.
class BedDayPosting {
  const BedDayPosting({required this.ops, required this.owed, required this.postedUntil, required this.newDays, required this.unpriced});

  /// Charges still to be written.
  final List<InsertOp> ops;

  /// Every bed-day owed so far, by the rule in bed_days.dart.
  final List<BedDay> owed;

  /// Last day up to which every owed day is fully charged (after [ops]).
  final DateTime? postedUntil;

  /// Days that get at least one new charge.
  final int newDays;

  /// Owed days that cannot be charged because the ward has no price.
  final List<BedDay> unpriced;

  int get amountPaise => ops.fold(0, (a, o) => a + ((o.data['amount_paise'] as int?) ?? 0));
}

/// Posts bed-day charges to core `charges`. Deterministic bookkeeping, not an
/// agent: it runs when the app starts on the data host and every hour, at
/// discharge, and when demo data is created. Posting is idempotent — each
/// charge has a fixed source_id (and a fixed record id), so running it again
/// never charges a day twice, even from two devices at once.
abstract final class BedCharging {
  static const bed = 'bed';
  static const nursing = 'nursing';
  static const kinds = [bed, nursing];

  static String sourceId(String admissionId, DateTime day, String kind) => '$admissionId:${dayKey(day)}:$kind';

  /// Fixed record id: a second insert of the same bed-day fails instead of
  /// creating a duplicate.
  static String chargeId(String admissionId, DateTime day, String kind) =>
      'ipd-$admissionId-${dayKey(day).replaceAll('-', '')}-$kind';

  static Future<void> _tail = Future.value();

  /// Runs [job] after any posting already running on this device.
  static Future<T> serial<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await job());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Works out the charges still missing for [admission]. Pass [dischargedAt]
  /// when discharging, so the discharge day is left out.
  static Future<BedDayPosting> prepare(ReadDb db, Rec admission,
      {required DateTime now, DateTime? dischargedAt, BedPricing? pricing}) async {
    final prices = pricing ?? await BedPricing.load(db);
    final owed = await BedDays.planFor(db, admission, now: now, dischargedAt: dischargedAt);
    // Archived and cancelled charges count as posted: somebody changed them on
    // purpose, and the unbilled bed-days agent asks a person to look.
    final existing = {
      for (final c in await db.query(Query(Col.charges)
          .eq('source_collection', IpdCol.admissions)
          .startsWith('source_id', '${admission.id}:')
          .withArchived()
          .take(5000)))
        c.str('source_id'),
    };
    final ops = <InsertOp>[];
    final unpriced = <BedDay>[];
    DateTime? until;
    var complete = true;
    var newDays = 0;
    for (final d in owed) {
      var covered = true;
      var added = false;
      for (final kind in kinds) {
        final sid = sourceId(admission.id, d.day, kind);
        if (existing.contains(sid)) continue;
        final p = prices.price(d.wardId, kind);
        if (p == null) {
          covered = false;
          continue;
        }
        final (code, unit) = p;
        added = true;
        ops.add(InsertOp(
          Col.charges,
          {
            'patient_id': admission.str('patient_id'),
            'encounter_id': admission.strOrNull('encounter_id'),
            'service_code': code,
            'description': '${kind == bed ? 'Bed' : 'Nursing'} — ${prices.wardName(d.wardId)} — ${formatDateShort(d.day)}',
            'category': kind == bed ? Vals.bed : Vals.nursing,
            'quantity': 1,
            'unit_price_paise': unit,
            'amount_paise': unit,
            'status': Vals.pending,
            'source_module': 'ipd',
            'source_collection': IpdCol.admissions,
            'source_id': sid,
            'service_date': d.day,
          },
          id: chargeId(admission.id, d.day, kind),
        ));
      }
      if (added) newDays++;
      if (!covered) unpriced.add(d);
      if (covered && complete) {
        until = d.day;
      } else {
        complete = false;
      }
    }
    return BedDayPosting(ops: ops, owed: owed, postedUntil: until, newDays: newDays, unpriced: unpriced);
  }

  /// Posts what is owed so far for one admission. Returns the number of days
  /// that got new charges.
  static Future<int> post(Db db, Rec admission, {DateTime? now, BedPricing? pricing}) => serial(() async {
        final at = now ?? DateTime.now();
        for (var attempt = 0;; attempt++) {
          final fresh = await db.get(IpdCol.admissions, admission.id) ?? admission;
          final p = await prepare(db, fresh, now: at, pricing: pricing);
          final ops = <WriteOp>[
            ...p.ops,
            if (p.postedUntil != null && fresh.date('bed_charges_posted_until') != p.postedUntil)
              UpdateOp(IpdCol.admissions, fresh.id, {'bed_charges_posted_until': p.postedUntil}),
          ];
          try {
            await db.batch(ops);
            return p.newDays;
          } on ValidationException {
            // Another device posted the same day a moment ago; look again once.
            if (attempt >= 1) rethrow;
          }
        }
      });

  /// True when every day owed so far is already posted (no queries needed).
  static bool upToDate(Rec admission, DateTime now) {
    final until = admission.date('bed_charges_posted_until');
    final admitted = admission.date('admitted_at');
    if (until == null || admitted == null) return false;
    final days = BedDays.chargeableDays(admittedAt: admitted, dischargedAt: admission.date('discharged_at'), now: now);
    return !until.isBefore(days.last);
  }

  /// Posts every current admission, and recent discharges whose charges did
  /// not all go through. Returns the number of days posted.
  static Future<int> postAll(Db db, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final current = await db.query(Query(IpdCol.admissions).isIn('status', IpdVals.current).take(2000));
    final recent = await db.query(Query(IpdCol.admissions)
        .eq('status', IpdVals.discharged)
        .gte('discharged_at', at.subtract(const Duration(days: 45)))
        .take(2000));
    final todo = [...current, ...recent].where((a) => !upToDate(a, at)).toList();
    if (todo.isEmpty) return 0;
    final pricing = await BedPricing.load(db);
    var days = 0;
    for (final a in todo) {
      try {
        days += await post(db, a, now: at, pricing: pricing);
      } catch (e) {
        debugPrint('ipd: could not post bed-days for ${a.str('number')}: $e');
      }
    }
    return days;
  }
}

import 'package:kendra_hms/core/core.dart';

import 'ipd_schema.dart';

// THE BED-DAY RULE
//
// A patient is charged one bed-day for every calendar day on which they
// occupied a bed, counting the admission day and excluding the discharge
// day — except a same-day discharge, which counts as one day.
//
// Each bed-day is charged at the ward of the bed occupied at the start of
// that day (00:00). For the admission day it is the admitting ward.
//
// While the patient is still in hospital, today is not owed yet (it may turn
// out to be the discharge day); it becomes owed at midnight. The admission
// day is owed at once, because even a same-day discharge pays for it.
//
// Every bed-day posts two rows to core `charges`: a bed charge and a nursing
// charge, priced from the ward's bed_service_code / nursing_service_code, with
// source_id `<admissionId>:<yyyy-mm-dd>:bed` and `<admissionId>:<yyyy-mm-dd>:nursing`.

/// A bed move: from [at] onwards the patient is in [wardId].
class WardMove {
  const WardMove(this.at, this.wardId);
  final DateTime at;
  final String wardId;
}

/// One chargeable calendar day and the ward it is charged at.
class BedDay {
  const BedDay(this.day, this.wardId);

  /// Local midnight of the day.
  final DateTime day;
  final String wardId;

  String get key => dayKey(day);
}

abstract final class BedDays {
  static DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

  /// The calendar days owed for a stay (see the rule above). For a patient
  /// still in hospital ([dischargedAt] null), days up to yesterday plus the
  /// admission day.
  static List<DateTime> chargeableDays({required DateTime admittedAt, DateTime? dischargedAt, required DateTime now}) {
    final first = startOfDay(admittedAt);
    // The first calendar day that is NOT charged.
    final stop = startOfDay(dischargedAt ?? now);
    final days = [first];
    for (var d = nextDay(first); d.isBefore(stop); d = nextDay(d)) {
      days.add(d);
    }
    return days;
  }

  /// Number of bed-days for a finished stay (or owed so far for a current one).
  static int count({required DateTime admittedAt, DateTime? dischargedAt, required DateTime now}) =>
      chargeableDays(admittedAt: admittedAt, dischargedAt: dischargedAt, now: now).length;

  /// The ward the patient was in at moment [t].
  static String wardAt(DateTime t, String admittingWardId, List<WardMove> moves) {
    var ward = admittingWardId;
    for (final m in moves) {
      if (m.at.isAfter(t)) break;
      ward = m.wardId;
    }
    return ward;
  }

  /// Owed days with the ward each one is charged at.
  static List<BedDay> plan({
    required DateTime admittedAt,
    DateTime? dischargedAt,
    required String admittingWardId,
    List<WardMove> moves = const [],
    required DateTime now,
  }) {
    final sorted = [...moves]..sort((a, b) => a.at.compareTo(b.at));
    final days = chargeableDays(admittedAt: admittedAt, dischargedAt: dischargedAt, now: now);
    return [
      for (final (i, d) in days.indexed) BedDay(d, i == 0 ? admittingWardId : wardAt(d, admittingWardId, sorted)),
    ];
  }

  /// "Day 4" of a stay: the admission day is day 1.
  static int dayNumber(DateTime admittedAt, DateTime now) {
    final diff = startOfDay(now).difference(startOfDay(admittedAt)).inHours / 24;
    final n = diff.round() + 1;
    return n < 1 ? 1 : n;
  }

  /// The ward moves of an admission from its transfer records, and the ward
  /// it started in.
  static (String admittingWardId, List<WardMove> moves) movesFrom(Rec admission, List<Rec> transfers,
      {Map<String, Rec> beds = const {}}) {
    final sorted = [...transfers]..sort((a, b) => (a.date('at') ?? a.createdAt).compareTo(b.date('at') ?? b.createdAt));
    String? wardOfBed(String? bedId) => bedId == null ? null : beds[bedId]?.strOrNull('ward_id');
    final moves = <WardMove>[];
    for (final t in sorted) {
      final ward = t.strOrNull('to_ward_id') ?? wardOfBed(t.strOrNull('to_bed_id'));
      if (ward != null) moves.add(WardMove(t.date('at') ?? t.createdAt, ward));
    }
    final admitting = sorted.isEmpty
        ? admission.str('ward_id')
        : (sorted.first.strOrNull('from_ward_id') ?? wardOfBed(sorted.first.strOrNull('from_bed_id')) ?? admission.str('ward_id'));
    return (admitting, moves);
  }

  /// Loads the transfers of [admission] and plans its owed bed-days.
  static Future<List<BedDay>> planFor(ReadDb db, Rec admission, {required DateTime now, DateTime? dischargedAt}) async {
    final transfers = await db.query(Query(IpdCol.transfers).eq('admission_id', admission.id).sort('at').take(500));
    final needBeds = transfers.where((t) => t.strOrNull('to_ward_id') == null || t.strOrNull('from_ward_id') == null);
    final beds = needBeds.isEmpty
        ? const <String, Rec>{}
        : await db.byIds(IpdCol.beds, [for (final t in needBeds) ...[t.strOrNull('from_bed_id'), t.strOrNull('to_bed_id')]]);
    final (admitting, moves) = movesFrom(admission, transfers, beds: beds);
    return plan(
      admittedAt: admission.date('admitted_at')!,
      dischargedAt: dischargedAt ?? admission.date('discharged_at'),
      admittingWardId: admitting,
      moves: moves,
      now: now,
    );
  }
}

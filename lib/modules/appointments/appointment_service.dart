import 'package:kendra_hms/core/core.dart';

abstract final class AppointmentPerms {
  static const view = 'appointments.view';
  static const manage = 'appointments.manage';
  static const schedules = 'appointments.schedules';
}

abstract final class ApptCol {
  static const schedules = 'doctor_schedules';
  static const appointments = 'appointments';
}

abstract final class ApptStatus {
  static const booked = 'booked';
  static const checkedIn = 'checked_in';
  static const inConsultation = 'in_consultation';
  static const completed = 'completed';
  static const cancelled = 'cancelled';
  static const noShow = 'no_show';

  static const all = [booked, checkedIn, inConsultation, completed, noShow, cancelled];

  /// Words the front desk uses.
  static String label(String s) => switch (s) {
        booked => 'Booked',
        checkedIn => 'Waiting',
        inConsultation => 'With doctor',
        completed => 'Done',
        cancelled => 'Cancelled',
        noShow => 'No-show',
        _ => titleCase(s),
      };

  static Tone tone(String s) => switch (s) {
        booked => Tone.neutral,
        checkedIn => Tone.warning,
        inConsultation => Tone.info,
        completed => Tone.success,
        noShow => Tone.danger,
        _ => Tone.neutral,
      };
}

abstract final class ApptKind {
  static const booked = 'booked';
  static const walkIn = 'walk_in';
  static const followUp = 'follow_up';

  static String label(String k) => switch (k) {
        walkIn => 'Walk-in',
        followUp => 'Follow-up',
        _ => 'Appointment',
      };
}

abstract final class BookedVia {
  static const phone = 'phone';
  static const frontDesk = 'front_desk';
  static const followUp = 'follow_up';

  static const options = [(phone, 'Phone'), (frontDesk, 'At the desk'), (followUp, 'Follow-up')];
}

/// One bookable slot generated from a doctor's schedule.
class Slot {
  const Slot(this.start, this.end, {this.room = '', this.scheduleId});
  final DateTime start;
  final DateTime end;
  final String room;
  final String? scheduleId;

  bool overlaps(DateTime s, DateTime e) => s.isBefore(end) && e.isAfter(start);

  @override
  bool operator ==(Object other) => other is Slot && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'Slot(${formatDateTime(start)})';
}

class CheckInResult {
  const CheckInResult(this.appointment, this.encounter);
  final Rec appointment;
  final Rec encounter;
  int get token => encounter.integer('token_no');
}

const _weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String weekdayName(int weekday) => _weekdayNames[(weekday - 1).clamp(0, 6)];

/// Midnight at the start of [d]'s day.
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// Midnight at the start of the next day (safe across daylight-saving changes).
DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "Today", "Tomorrow", "Yesterday" or "Mon 26 Oct".
String dayLabel(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (sameDay(d, n)) return 'Today';
  if (sameDay(d, DateTime(n.year, n.month, n.day + 1))) return 'Tomorrow';
  if (sameDay(d, DateTime(n.year, n.month, n.day - 1))) return 'Yesterday';
  return '${formatWeekday(d)} ${formatDateShort(d)}';
}

/// yyyymmdd, used in token sequence names.
String compactDay(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

/// Booking, check-in and schedule rules shared by the screens, the agents
/// and the demo seeder.
abstract final class AppointmentService {
  static const defaultSlotMinutes = 15;

  // ------------------------------------------------------------ schedules

  static DateTime at(DateTime day, int minute) => DateTime(day.year, day.month, day.day, minute ~/ 60, minute % 60);

  static String minuteLabel(int minute) => formatTime(at(DateTime(2000), minute));

  static String sessionLabel(Rec s) =>
      '${minuteLabel(s.integer('start_minute'))} – ${minuteLabel(s.integer('end_minute'))}';

  /// The slots a doctor's [schedules] give on [day], in time order.
  static List<Slot> slotsForDay(Iterable<Rec> schedules, DateTime day) {
    final sessions = schedules
        .where((s) => s.integer('weekday') == day.weekday && s['active'] != false && !s.archived)
        .toList()
      ..sort((a, b) => a.integer('start_minute').compareTo(b.integer('start_minute')));
    final out = <Slot>[];
    for (final s in sessions) {
      final len = s.integer('slot_minutes', defaultSlotMinutes).clamp(5, 240);
      final end = s.integer('end_minute');
      for (var m = s.integer('start_minute'); m + len <= end; m += len) {
        out.add(Slot(at(day, m), at(day, m + len), room: s.str('room'), scheduleId: s.id));
      }
    }
    return out;
  }

  /// Walk-ins are squeezed in by token, so they don't use up a slot.
  /// Cancelled and no-show appointments give their slot back.
  static bool blocksSlot(Rec a) =>
      a.str('kind') != ApptKind.walkIn && a.str('status') != ApptStatus.cancelled && a.str('status') != ApptStatus.noShow;

  static DateTime endOf(Rec a) =>
      a.date('end_at') ?? a.date('start_at')!.add(const Duration(minutes: defaultSlotMinutes));

  /// [slots] not taken by any of [appointments]. With [now], slots that have
  /// already started are left out too.
  static List<Slot> freeSlots(List<Slot> slots, Iterable<Rec> appointments, {DateTime? now, String? ignoreId}) {
    final taken = appointments.where((a) => a.id != ignoreId && blocksSlot(a)).toList();
    return [
      for (final s in slots)
        if ((now == null || !s.start.isBefore(now)) && !taken.any((a) => s.overlaps(a.date('start_at')!, endOf(a)))) s,
    ];
  }

  static Future<List<Rec>> schedulesFor(ReadDb db, String doctorId) =>
      db.query(Query(ApptCol.schedules).eq('doctor_id', doctorId).sort('start_minute').take(100));

  static Future<List<Rec>> allSchedules(ReadDb db) =>
      db.query(const Query(ApptCol.schedules).sort('start_minute').take(2000));

  static Future<List<Rec>> doctors(ReadDb db) =>
      db.query(const Query(Col.users).eq('is_clinician', true).eq('active', true).sort('display_name').take(200));

  static Future<List<Rec>> appointmentsOn(ReadDb db, DateTime day, {String? doctorId}) {
    var q = Query(ApptCol.appointments).between('start_at', dayOf(day), nextDay(day)).sort('start_at').take(1000);
    if (doctorId != null) q = q.eq('doctor_id', doctorId);
    return db.query(q);
  }

  static Future<List<Slot>> freeSlotsOn(ReadDb db, String doctorId, DateTime day, {DateTime? now, String? ignoreId}) async {
    final slots = slotsForDay(await schedulesFor(db, doctorId), day);
    if (slots.isEmpty) return const [];
    return freeSlots(slots, await appointmentsOn(db, day, doctorId: doctorId),
        now: now ?? DateTime.now(), ignoreId: ignoreId);
  }

  /// The earliest free slot from [from] (default now), looking [days] ahead.
  static Future<Slot?> nextFreeSlot(ReadDb db, String doctorId, {DateTime? from, int days = 30, String? ignoreId}) async {
    final start = from ?? DateTime.now();
    final schedules = await schedulesFor(db, doctorId);
    if (schedules.isEmpty) return null;
    for (var i = 0; i < days; i++) {
      final day = DateTime(start.year, start.month, start.day + i);
      final slots = slotsForDay(schedules, day);
      if (slots.isEmpty) continue;
      final free = freeSlots(slots, await appointmentsOn(db, day, doctorId: doctorId), now: start, ignoreId: ignoreId);
      if (free.isNotEmpty) return free.first;
    }
    return null;
  }

  /// The doctor's room at [at]: the session running then, else the day's first.
  static String roomAt(Iterable<Rec> schedules, DateTime at) {
    final today = schedules.where((s) => s.integer('weekday') == at.weekday && s['active'] != false).toList()
      ..sort((a, b) => a.integer('start_minute').compareTo(b.integer('start_minute')));
    final m = at.hour * 60 + at.minute;
    for (final s in today) {
      if (m >= s.integer('start_minute') - 30 && m < s.integer('end_minute') && s.str('room').isNotEmpty) return s.str('room');
    }
    for (final s in today) {
      if (s.str('room').isNotEmpty) return s.str('room');
    }
    for (final s in schedules) {
      if (s.str('room').isNotEmpty) return s.str('room');
    }
    return '';
  }

  /// True when a session of the doctor is running at [at].
  static bool inSession(Iterable<Rec> schedules, DateTime at) {
    final m = at.hour * 60 + at.minute;
    return schedules.any((s) =>
        s.integer('weekday') == at.weekday &&
        s['active'] != false &&
        m >= s.integer('start_minute') &&
        m < s.integer('end_minute'));
  }

  // ------------------------------------------------------------ booking

  static String tokenSequence(String doctorId, DateTime day) => 'token:${compactDay(day)}:$doctorId';

  static Future<void> _checkClash(ReadDb db,
      {required String patientId, required String doctorId, required DateTime start, required DateTime end, String? ignoreId}) async {
    final sameDayAppts = await appointmentsOn(db, start, doctorId: doctorId);
    for (final a in sameDayAppts) {
      if (a.id == ignoreId || !blocksSlot(a) || a.str('status') == ApptStatus.completed) continue;
      if (a.str('patient_id') == patientId) {
        throw ValidationException(
            'This patient already has an appointment with this doctor at ${formatTime(a.date('start_at'))} that day');
      }
    }
    for (final a in sameDayAppts) {
      if (a.id == ignoreId || !blocksSlot(a)) continue;
      if (a.date('start_at')!.isBefore(end) && endOf(a).isAfter(start)) {
        throw ValidationException('${formatTime(start)} was just booked by someone else. Pick another time.');
      }
    }
  }

  static Future<Rec> book(
    Db db, {
    required String patientId,
    required String doctorId,
    required DateTime start,
    DateTime? end,
    String bookedVia = BookedVia.frontDesk,
    String? reason,
    String? notes,
  }) async {
    final e = end ?? start.add(const Duration(minutes: defaultSlotMinutes));
    await _checkClash(db, patientId: patientId, doctorId: doctorId, start: start, end: e);
    return db.insert(ApptCol.appointments, {
      'patient_id': patientId,
      'doctor_id': doctorId,
      'start_at': start,
      'end_at': e,
      'kind': bookedVia == BookedVia.followUp ? ApptKind.followUp : ApptKind.booked,
      'status': ApptStatus.booked,
      'booked_via': bookedVia,
      'reason': _clean(reason),
      'notes': _clean(notes),
    });
  }

  static String? _clean(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  static Map<String, Object?> _encounter({
    required String patientId,
    required String doctorId,
    required Rec? doctor,
    required DateTime at,
    required int token,
    required String appointmentId,
  }) =>
      {
        'patient_id': patientId,
        'type': Vals.opd,
        'status': Vals.open,
        'doctor_id': doctorId,
        'department': doctor?.strOrNull('department'),
        'started_at': at,
        'checked_in_at': at,
        'queue_status': Vals.waiting,
        'token_no': token,
        'source_module': 'appointments',
        'source_id': appointmentId,
      };

  /// Patient has arrived: opens the OPD visit (encounter) with the next token
  /// for that doctor today. Exactly one encounter per appointment.
  static Future<CheckInResult> checkIn(Db db, Rec appointment, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final a = await db.get(ApptCol.appointments, appointment.id);
    if (a == null) throw ValidationException('This appointment no longer exists');
    if (a.strOrNull('encounter_id') != null || a.str('status') != ApptStatus.booked) {
      throw ValidationException(switch (a.str('status')) {
        ApptStatus.cancelled => 'This appointment was cancelled. Book a new one or use Walk-in.',
        ApptStatus.noShow => 'This appointment was marked as a no-show. Use Walk-in instead.',
        _ => 'Already checked in with token ${a.integer('token_no')}',
      });
    }
    final start = a.date('start_at')!;
    if (!sameDay(start, t)) {
      throw ValidationException(start.isBefore(t)
          ? 'This appointment was on ${formatDate(start)}. Use Walk-in for today.'
          : 'This appointment is on ${formatDate(start)}. Reschedule it to today first.');
    }
    final doctorId = a.str('doctor_id');
    final doctor = await db.get(Col.users, doctorId);
    final token = await db.nextSequence(tokenSequence(doctorId, t));
    final encId = db.newId();
    final res = await db.batch([
      InsertOp(
          Col.encounters,
          _encounter(
              patientId: a.str('patient_id'), doctorId: doctorId, doctor: doctor, at: t, token: token, appointmentId: a.id),
          id: encId),
      UpdateOp(ApptCol.appointments, a.id, {'status': ApptStatus.checkedIn, 'encounter_id': encId, 'token_no': token},
          expectedVersion: a.version),
    ]);
    return CheckInResult(res[1], res[0]);
  }

  /// A patient without an appointment: books and checks in at once.
  static Future<CheckInResult> walkIn(Db db,
      {required String patientId, required String doctorId, String? reason, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final already = await db.query(Query(Col.encounters)
        .eq('patient_id', patientId)
        .eq('doctor_id', doctorId)
        .eq('type', Vals.opd)
        .eq('status', Vals.open)
        .between('checked_in_at', dayOf(t), nextDay(t))
        .take(5));
    final waiting = already.where((e) => e.str('queue_status') == Vals.waiting || e.str('queue_status') == Vals.withDoctor);
    if (waiting.isNotEmpty) {
      throw ValidationException('Already in this doctor\'s queue with token ${waiting.first.integer('token_no')}');
    }
    final doctor = await db.get(Col.users, doctorId);
    final token = await db.nextSequence(tokenSequence(doctorId, t));
    final apptId = db.newId();
    final encId = db.newId();
    final res = await db.batch([
      InsertOp(
          ApptCol.appointments,
          {
            'patient_id': patientId,
            'doctor_id': doctorId,
            'start_at': t,
            'end_at': t.add(const Duration(minutes: defaultSlotMinutes)),
            'kind': ApptKind.walkIn,
            'status': ApptStatus.checkedIn,
            'booked_via': BookedVia.frontDesk,
            'encounter_id': encId,
            'token_no': token,
            'reason': _clean(reason),
          },
          id: apptId),
      InsertOp(
          Col.encounters,
          _encounter(patientId: patientId, doctorId: doctorId, doctor: doctor, at: t, token: token, appointmentId: apptId),
          id: encId),
    ]);
    return CheckInResult(res[0], res[1]);
  }

  static void _needBooked(Rec a, String action) {
    if (a.str('status') != ApptStatus.booked) {
      throw ValidationException('Only booked appointments can be $action. This one is ${ApptStatus.label(a.str('status')).toLowerCase()}.');
    }
  }

  static Future<Rec> cancel(Db db, Rec a, String reason) async {
    if (reason.trim().isEmpty) throw ValidationException('Give a reason for cancelling');
    _needBooked(a, 'cancelled');
    return db.update(ApptCol.appointments, a.id, {'status': ApptStatus.cancelled, 'cancel_reason': reason.trim()},
        expectedVersion: a.version);
  }

  static Future<Rec> markNoShow(Db db, Rec a) async {
    _needBooked(a, 'marked as no-show');
    return db.update(ApptCol.appointments, a.id, {'status': ApptStatus.noShow}, expectedVersion: a.version);
  }

  /// Marks the given appointments as no-show, skipping any that are no
  /// longer booked (the patient arrived late, or someone cancelled).
  /// Returns (marked, skipped).
  static Future<(int, int)> markNoShowMany(Db db, Iterable<String> ids) async {
    final wanted = ids.toSet();
    final found = await db.byIds(ApptCol.appointments, wanted);
    final ops = <WriteOp>[
      for (final a in found.values)
        if (a.str('status') == ApptStatus.booked && !a.archived && a.strOrNull('encounter_id') == null)
          UpdateOp(ApptCol.appointments, a.id, {'status': ApptStatus.noShow}, expectedVersion: a.version),
    ];
    await db.batch(ops);
    return (ops.length, wanted.length - ops.length);
  }

  static Future<Rec> reschedule(Db db, Rec a, Slot slot, {String? doctorId}) async {
    _needBooked(a, 'moved');
    final doc = doctorId ?? a.str('doctor_id');
    await _checkClash(db, patientId: a.str('patient_id'), doctorId: doc, start: slot.start, end: slot.end, ignoreId: a.id);
    return db.update(ApptCol.appointments, a.id, {'start_at': slot.start, 'end_at': slot.end, 'doctor_id': doc},
        expectedVersion: a.version);
  }

  // ------------------------------------------------------------ status follows the visit

  /// What the OPD visit says about the appointment, or null without one.
  static String? statusFromEncounter(Rec? e) {
    if (e == null) return null;
    final q = e.str('queue_status');
    if (q == Vals.left) return ApptStatus.cancelled;
    if (q == Vals.done || e.str('status') == Vals.closed) return ApptStatus.completed;
    if (e.str('status') == Vals.cancelled) return ApptStatus.cancelled;
    if (q == Vals.withDoctor) return ApptStatus.inConsultation;
    return ApptStatus.checkedIn;
  }

  /// The status to show: the stored one, overridden by the linked visit.
  static String effectiveStatus(Rec a, Rec? encounter) {
    final s = a.str('status', ApptStatus.booked);
    if (encounter == null || s == ApptStatus.cancelled || s == ApptStatus.noShow) return s;
    return statusFromEncounter(encounter)!;
  }

  /// Writes the visit's progress back to checked-in appointments
  /// (checked in → with doctor → done). Runs on the data host as the system.
  static Future<int> syncWithEncounters(Db db, {DateTime? since}) async {
    final from = since ?? DateTime.now().subtract(const Duration(days: 3));
    final appts = await db.query(Query(ApptCol.appointments)
        .isIn('status', [ApptStatus.checkedIn, ApptStatus.inConsultation])
        .gte('start_at', from)
        .take(2000));
    final linked = appts.where((a) => a.strOrNull('encounter_id') != null).toList();
    if (linked.isEmpty) return 0;
    final encs = await db.byIds(Col.encounters, linked.map((a) => a.str('encounter_id')));
    final ops = <WriteOp>[];
    for (final a in linked) {
      final s = statusFromEncounter(encs[a.str('encounter_id')]);
      if (s != null && s != a.str('status')) {
        ops.add(UpdateOp(ApptCol.appointments, a.id, {
          'status': s,
          if (s == ApptStatus.cancelled) 'cancel_reason': 'Left before seeing the doctor',
        }));
      }
    }
    await db.batch(ops);
    return ops.length;
  }

  // ------------------------------------------------------------ queue

  /// Today's OPD visits (any source: appointments, OPD walk-ins).
  static Future<List<Rec>> opdVisitsOn(ReadDb db, DateTime day) => db.query(Query(Col.encounters)
      .eq('type', Vals.opd)
      .between('checked_in_at', dayOf(day), nextDay(day))
      .sort('checked_in_at')
      .take(1000));

  static bool isWaiting(Rec e) => e.str('status') == Vals.open && e.str('queue_status') == Vals.waiting;
  static bool isWithDoctor(Rec e) => e.str('status') == Vals.open && e.str('queue_status') == Vals.withDoctor;

  /// Waiting patients per doctor id.
  static Map<String, int> waitingCounts(Iterable<Rec> visits) {
    final out = <String, int>{};
    for (final e in visits.where(isWaiting)) {
      out.update(e.str('doctor_id'), (v) => v + 1, ifAbsent: () => 1);
    }
    return out;
  }

  /// The doctor a walk-in should go to: someone in session now, with the
  /// fewest people waiting (ties: fewer patients today).
  static String? suggestDoctor(List<Rec> doctors, Iterable<Rec> visits, Map<String, List<Rec>> schedulesByDoctor,
      {DateTime? now}) {
    if (doctors.isEmpty) return null;
    final t = now ?? DateTime.now();
    final waiting = waitingCounts(visits);
    final seen = <String, int>{};
    for (final e in visits) {
      seen.update(e.str('doctor_id'), (v) => v + 1, ifAbsent: () => 1);
    }
    final inNow = doctors.where((d) => inSession(schedulesByDoctor[d.id] ?? const [], t)).toList();
    final pool = inNow.isEmpty ? doctors : inNow;
    final sorted = [...pool]..sort((a, b) {
        final w = (waiting[a.id] ?? 0).compareTo(waiting[b.id] ?? 0);
        return w != 0 ? w : (seen[a.id] ?? 0).compareTo(seen[b.id] ?? 0);
      });
    return sorted.first.id;
  }
}

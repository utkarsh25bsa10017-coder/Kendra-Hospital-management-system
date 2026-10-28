import 'dart:math';

import 'package:kendra_hms/core/core.dart';

import 'appointment_service.dart';

const _rooms = {'board': 'Room 1', 'drkhan': 'Room 3', 'drnair': 'Room 5'};

const _reasons = <String, List<String>>{
  'Paediatrics': ['Fever', 'Cough and cold', 'Vaccination', 'Growth check', 'Ear pain', 'Loose motions'],
  'Orthopaedics': ['Knee pain', 'Back pain', 'Fracture follow-up', 'Shoulder pain', 'Neck stiffness', 'Ankle sprain'],
  'General Medicine': ['Fever', 'BP review', 'Diabetes review', 'Acidity', 'Headache', 'Body ache', 'Thyroid review'],
};

class _Plan {
  _Plan(this.doctor, this.start, this.status,
      {this.kind = ApptKind.booked, this.checkedIn, this.called, this.ended, this.cancelReason});
  final Rec doctor;
  final DateTime start;
  final String status;
  final String kind;
  final DateTime? checkedIn;
  final DateTime? called;
  final DateTime? ended;
  final String? cancelReason;
}

/// Weekly schedules for every doctor, a busy "today" (some seen, some with
/// the doctor, some waiting, some still to come, two who never arrived),
/// tomorrow's bookings and a month of history.
Future<void> seedDemoAppointments(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final now = DateTime.now();
  final today = dayOf(now);
  final rnd = Random(11);
  final doctors = await AppointmentService.doctors(db);
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(200));
  if (doctors.isEmpty || patients.isEmpty) return;

  Rec byUser(String username, int fallback) =>
      doctors.firstWhere((d) => d.str('username') == username, orElse: () => doctors[fallback % doctors.length]);
  final gm = byUser('board', 0);
  final paeds = byUser('drkhan', 1);
  final ortho = byUser('drnair', 2);

  // ---------------------------------------------------------------- schedules
  InsertOp session(Rec d, int weekday, int from, int to, String room) => InsertOp(ApptCol.schedules, {
        'doctor_id': d.id,
        'weekday': weekday,
        'start_minute': from,
        'end_minute': to,
        'slot_minutes': 15,
        'room': room,
        'active': true,
      });
  final scheduleOps = <WriteOp>[];
  for (final (i, d) in doctors.indexed) {
    final room = _rooms[d.str('username')] ?? 'Room ${i * 2 + 1}';
    for (var wd = DateTime.monday; wd <= DateTime.saturday; wd++) {
      scheduleOps.add(session(d, wd, 9 * 60, 13 * 60, room));
    }
    if (d.id == paeds.id) {
      // Evening children's OPD after school.
      scheduleOps.add(session(d, DateTime.tuesday, 17 * 60, 20 * 60, room));
      scheduleOps.add(session(d, DateTime.thursday, 17 * 60, 20 * 60, room));
    }
    if (d.id == gm.id) scheduleOps.add(session(d, DateTime.sunday, 10 * 60, 13 * 60, room));
  }
  await db.batch(scheduleOps);
  final schedules = <String, List<Rec>>{};
  for (final s in await AppointmentService.allSchedules(db)) {
    schedules.putIfAbsent(s.str('doctor_id'), () => []).add(s);
  }
  List<Slot> slotsOn(Rec d, DateTime day) => AppointmentService.slotsForDay(schedules[d.id] ?? const [], day);

  // ---------------------------------------------------------------- helpers
  final children = patients.where((p) {
    final dob = p.date('dob');
    return dob != null && ageInYears(dob) < 15;
  }).toList();
  final usedByDay = <String, Set<String>>{};
  Rec patientFor(Rec doctor, DateTime day) {
    final used = usedByDay.putIfAbsent(dayKey(day), () => {});
    final pool = doctor.id == paeds.id && children.isNotEmpty && rnd.nextInt(3) > 0 ? children : patients;
    for (var tries = 0; tries < 40; tries++) {
      final p = pool[rnd.nextInt(pool.length)];
      if (used.add(p.id)) return p;
    }
    return patients[rnd.nextInt(patients.length)];
  }

  String reasonFor(Rec d) {
    final list = _reasons[d.str('department')] ?? _reasons['General Medicine']!;
    return list[rnd.nextInt(list.length)];
  }

  Future<void> write(List<_Plan> plans) async {
    plans.sort((a, b) => (a.checkedIn ?? a.start).compareTo(b.checkedIn ?? b.start));
    final ops = <WriteOp>[];
    for (final p in plans) {
      final patient = patientFor(p.doctor, p.start);
      final apptId = db.newId();
      String? encId;
      int? token;
      final at = p.checkedIn;
      if (at != null) {
        token = await db.nextSequence(AppointmentService.tokenSequence(p.doctor.id, at));
        encId = db.newId();
        final done = p.status == ApptStatus.completed;
        ops.add(InsertOp(
            Col.encounters,
            {
              'patient_id': patient.id,
              'type': Vals.opd,
              'status': done ? Vals.closed : Vals.open,
              'doctor_id': p.doctor.id,
              'department': p.doctor.strOrNull('department'),
              'started_at': at,
              'checked_in_at': at,
              'called_at': p.called,
              'ended_at': p.ended,
              'queue_status': switch (p.status) {
                ApptStatus.completed => Vals.done,
                ApptStatus.inConsultation => Vals.withDoctor,
                _ => Vals.waiting,
              },
              'token_no': token,
              'source_module': 'appointments',
              'source_id': apptId,
            },
            id: encId));
      }
      final via = switch (p.kind) {
            ApptKind.walkIn => BookedVia.frontDesk,
            ApptKind.followUp => BookedVia.followUp,
            _ => rnd.nextInt(3) == 0 ? BookedVia.frontDesk : BookedVia.phone,
          };
      final reason = p.kind == ApptKind.followUp ? 'Follow-up review' : reasonFor(p.doctor);
      ops.add(InsertOp(
          ApptCol.appointments,
          {
            'patient_id': patient.id,
            'doctor_id': p.doctor.id,
            'start_at': p.start,
            'end_at': p.start.add(const Duration(minutes: 15)),
            'kind': p.kind,
            'status': p.status,
            'encounter_id': encId,
            'token_no': token,
            'reason': reason,
            'notes': reason == 'Fracture follow-up' ? 'Bring the last X-ray' : null,
            'booked_via': via,
            'cancel_reason': p.cancelReason,
          },
          id: apptId));
    }
    await db.batch(ops);
  }

  String randomKind() {
    final r = rnd.nextInt(100);
    return r < 15 ? ApptKind.walkIn : (r < 30 ? ApptKind.followUp : ApptKind.booked);
  }

  // ---------------------------------------------------------------- the last 30 days
  final history = <_Plan>[];
  for (var back = 30; back >= 1; back--) {
    final day = DateTime(today.year, today.month, today.day - back);
    for (final d in doctors) {
      final slots = slotsOn(d, day);
      if (slots.isEmpty) continue;
      final picks = (List<int>.generate(slots.length, (i) => i)..shuffle(rnd)).take(1 + rnd.nextInt(3)).toList()..sort();
      for (final i in picks) {
        final s = slots[i].start;
        if (rnd.nextInt(100) < 9) {
          history.add(_Plan(d, s, ApptStatus.noShow));
          continue;
        }
        final kind = randomKind();
        final arrived = s.subtract(Duration(minutes: rnd.nextInt(12)));
        final called = s.add(Duration(minutes: 2 + rnd.nextInt(25)));
        history.add(_Plan(d, kind == ApptKind.walkIn ? arrived : s, ApptStatus.completed,
            kind: kind, checkedIn: arrived, called: called, ended: called.add(Duration(minutes: 7 + rnd.nextInt(14)))));
      }
    }
  }
  await write(history);

  // ---------------------------------------------------------------- today
  DateTime clampToday(DateTime t) {
    final lo = today.add(const Duration(minutes: 5));
    final hi = nextDay(today).subtract(const Duration(minutes: 15));
    if (t.isBefore(lo)) return lo;
    if (t.isAfter(hi)) return hi;
    return t;
  }

  DateTime round5(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % 5);
  DateTime round15(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % 15);
  final usedSlots = <Slot>{};
  Slot? takeSlot(Rec d, bool Function(Slot) ok, {bool latest = false}) {
    final list = slotsOn(d, today).where((s) => ok(s) && !usedSlots.contains(s)).toList();
    if (list.isEmpty) return null;
    final s = latest ? list.last : list.first;
    usedSlots.add(s);
    return s;
  }

  final todays = <_Plan>[];
  // Seen this morning: every other slot, well before now.
  for (final d in [gm, paeds, ortho]) {
    final past = slotsOn(d, today).where((s) => !s.end.isAfter(now.subtract(const Duration(minutes: 90)))).toList();
    final chosen = <DateTime>[for (var i = 0; i < past.length && i < 8; i += 2) past[i].start];
    usedSlots.addAll([for (var i = 0; i < past.length && i < 8; i += 2) past[i]]);
    for (var k = chosen.length; k < 4; k++) {
      chosen.add(clampToday(round5(now.subtract(Duration(minutes: 240 - k * 35)))));
    }
    for (final s in chosen.take(4)) {
      final arrived = s.subtract(Duration(minutes: 3 + rnd.nextInt(8)));
      final called = s.add(Duration(minutes: 3 + rnd.nextInt(10)));
      todays.add(_Plan(d, s, ApptStatus.completed,
          checkedIn: arrived, called: called, ended: called.add(Duration(minutes: 8 + rnd.nextInt(8)))));
    }
  }
  // Two who were booked this morning and never came.
  for (final (i, d) in [paeds, gm].indexed) {
    final cutoff = now.subtract(const Duration(hours: 2, minutes: 15));
    final s = takeSlot(d, (s) => !s.end.isAfter(cutoff), latest: true)?.start ??
        clampToday(round5(now.subtract(Duration(minutes: 150 + i * 20))));
    todays.add(_Plan(d, s, ApptStatus.booked));
  }
  // One cancellation.
  final cancelSlot = takeSlot(ortho, (s) => s.start.isAfter(now.add(const Duration(minutes: 30)))) ??
      takeSlot(ortho, (s) => true, latest: true);
  todays.add(_Plan(ortho, cancelSlot?.start ?? clampToday(round5(now.add(const Duration(minutes: 45)))),
      ApptStatus.cancelled,
      cancelReason: 'Patient asked to cancel'));
  // With the doctor right now.
  for (final (i, d) in [gm, paeds, ortho].indexed) {
    final arrived = clampToday(now.subtract(Duration(minutes: 84 - i * 3)));
    todays.add(_Plan(d, round15(arrived.add(const Duration(minutes: 10))), ApptStatus.inConsultation,
        checkedIn: arrived, called: now.subtract(Duration(minutes: 5 + i * 4))));
  }
  // Waiting room: one has been waiting over an hour.
  const waits = [70, 38, 30, 20, 11, 4];
  final waitDoctors = [paeds, gm, ortho, paeds, gm, paeds];
  const waitKinds = [ApptKind.booked, ApptKind.booked, ApptKind.walkIn, ApptKind.followUp, ApptKind.walkIn, ApptKind.booked];
  for (var i = 0; i < waits.length; i++) {
    final arrived = clampToday(now.subtract(Duration(minutes: waits[i])));
    todays.add(_Plan(
        waitDoctors[i],
        waitKinds[i] == ApptKind.walkIn ? arrived : round15(arrived.add(const Duration(minutes: 10))),
        ApptStatus.checkedIn,
        kind: waitKinds[i],
        checkedIn: arrived));
  }
  // Still to come today.
  for (final (i, d) in [gm, paeds, ortho, paeds].indexed) {
    final s = takeSlot(d, (s) => s.start.isAfter(now.add(Duration(minutes: 10 + i * 20))))?.start ??
        round5(now.add(Duration(minutes: 25 + i * 25)));
    if (!s.isAfter(now) || !sameDay(s, now)) continue;
    todays.add(_Plan(d, s, ApptStatus.booked, kind: i == 3 ? ApptKind.followUp : ApptKind.booked));
  }
  await write(todays);

  // ---------------------------------------------------------------- the coming week
  final upcoming = <_Plan>[];
  for (var ahead = 1; ahead <= 6; ahead++) {
    final day = DateTime(today.year, today.month, today.day + ahead);
    final want = ahead == 1 ? 10 : 2;
    final options = <(Rec, Slot)>[
      for (final d in doctors)
        for (final s in slotsOn(d, day)) (d, s),
    ]..shuffle(rnd);
    for (final (d, s) in options.take(want)) {
      upcoming.add(_Plan(d, s.start, ApptStatus.booked, kind: rnd.nextInt(4) == 0 ? ApptKind.followUp : ApptKind.booked));
    }
  }
  await write(upcoming);
}

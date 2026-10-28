import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/appointments/agents/long_wait_agent.dart';
import 'package:kendra_hms/modules/appointments/agents/missed_appointments_agent.dart';
import 'package:kendra_hms/modules/appointments/appointment_service.dart';
import 'package:kendra_hms/modules/appointments/appointments_module.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

/// A Tuesday far from today, so "now" is always passed in explicitly.
final day = DateTime(2030, 3, 12);
DateTime at(int h, [int m = 0, DateTime? d]) => DateTime((d ?? day).year, (d ?? day).month, (d ?? day).day, h, m);

class _Hospital {
  _Hospital(this.app, this.docA, this.docB, this.patients);
  final AppServices app;
  final Rec docA;
  final Rec docB;
  final List<Rec> patients;
  Db get db => app.db;
}

/// Two doctors with a Tuesday 9–10 AM session (and Wednesday for docA),
/// five patients, signed in as a receptionist.
Future<_Hospital> _boot() async {
  final app = await bootTestHospital([PatientsModule(), AppointmentsModule()]);
  final a = await addUser(app, 'drasha', [Roles.doctor],
      extra: {'display_name': 'Dr. Asha Rao', 'is_clinician': true, 'department': 'Paediatrics'});
  final b = await addUser(app, 'drbala', [Roles.doctor],
      extra: {'display_name': 'Dr. Bala Iyer', 'is_clinician': true, 'department': 'Orthopaedics'});
  await addUser(app, 'desk', [Roles.receptionist]);
  for (final (doc, wd) in [(a, DateTime.tuesday), (a, DateTime.wednesday), (b, DateTime.tuesday)]) {
    await app.systemDb.insert(ApptCol.schedules, {
      'doctor_id': doc.id,
      'weekday': wd,
      'start_minute': 9 * 60,
      'end_minute': 10 * 60,
      'slot_minutes': 15,
      'room': doc.id == a.id ? 'Room 3' : 'Room 5',
      'active': true,
    });
  }
  final patients = <Rec>[
    for (final (i, n) in ['Aarti Patil', 'Rohan Shah', 'Meena Iyer', 'Imran Khan', 'Kavya Nair'].indexed)
      await app.systemDb.insert(Col.patients, {'uhid': 'TH-$i', 'first_name': n.split(' ').first, 'full_name': n}),
  ];
  await signIn(app, 'desk');
  return _Hospital(app, a, b, patients);
}

List<String> _times(Iterable<Slot> slots) => [for (final s in slots) formatTime(s.start)];

void main() {
  test('free slots come from the schedule, without booked slots; cancelled slots are free again', () async {
    final h = await _boot();
    final [p1, p2, p3, ..._] = h.patients;
    final schedules = await AppointmentService.schedulesFor(h.app.readDb, h.docA.id);

    final slots = AppointmentService.slotsForDay(schedules, day);
    expect(_times(slots), ['9:00 AM', '9:15 AM', '9:30 AM', '9:45 AM']);
    expect(slots.first.room, 'Room 3');
    expect(AppointmentService.slotsForDay(schedules, at(0, 0, DateTime(2030, 3, 14))), isEmpty, reason: 'no Thursday OPD');

    await AppointmentService.book(h.db, patientId: p1.id, doctorId: h.docA.id, start: at(9, 15));
    final second = await AppointmentService.book(h.db, patientId: p2.id, doctorId: h.docA.id, start: at(9, 30));
    await AppointmentService.cancel(h.db, second, 'Patient asked to cancel');

    final free = await AppointmentService.freeSlotsOn(h.app.readDb, h.docA.id, day, now: at(8));
    expect(_times(free), ['9:00 AM', '9:30 AM', '9:45 AM']);
    // Slots that have started are not offered.
    final later = await AppointmentService.freeSlotsOn(h.app.readDb, h.docA.id, day, now: at(9, 20));
    expect(_times(later), ['9:30 AM', '9:45 AM']);
    // The other doctor's diary is separate.
    expect(_times(await AppointmentService.freeSlotsOn(h.app.readDb, h.docB.id, day, now: at(8))), hasLength(4));

    // Someone else taking the same slot is refused.
    await expectLater(AppointmentService.book(h.db, patientId: p3.id, doctorId: h.docA.id, start: at(9, 15)),
        throwsA(isA<ValidationException>()));
    // After the last slot today, the next free one is Wednesday 9:00.
    final next = await AppointmentService.nextFreeSlot(h.app.readDb, h.docA.id, from: at(9, 50));
    expect(next!.start, at(9, 0, DateTime(2030, 3, 13)));
    await h.app.close();
  });

  test('check-in opens exactly one visit; tokens go 1, 2, 3 per doctor per day', () async {
    final h = await _boot();
    final [p1, p2, p3, p4, p5] = h.patients;
    final a1 = await AppointmentService.book(h.db, patientId: p1.id, doctorId: h.docA.id, start: at(9));
    final a2 = await AppointmentService.book(h.db, patientId: p2.id, doctorId: h.docA.id, start: at(9, 15));
    final a3 = await AppointmentService.book(h.db, patientId: p3.id, doctorId: h.docA.id, start: at(9, 30));
    final b1 = await AppointmentService.book(h.db, patientId: p4.id, doctorId: h.docB.id, start: at(9));
    final now = at(9, 5);

    final r1 = await AppointmentService.checkIn(h.db, a1, now: now);
    final r2 = await AppointmentService.checkIn(h.db, a2, now: now);
    final rb = await AppointmentService.checkIn(h.db, b1, now: now);
    final r3 = await AppointmentService.checkIn(h.db, a3, now: now);
    expect([r1.token, r2.token, r3.token], [1, 2, 3]);
    expect(rb.token, 1, reason: 'each doctor has their own tokens');

    final enc = r1.encounter;
    expect(enc.str('type'), Vals.opd);
    expect(enc.str('status'), Vals.open);
    expect(enc.str('queue_status'), Vals.waiting);
    expect(enc.str('doctor_id'), h.docA.id);
    expect(enc.str('department'), 'Paediatrics');
    expect(enc.str('source_module'), 'appointments');
    expect(enc.str('source_id'), a1.id);
    expect(enc.date('checked_in_at'), now);
    expect(enc.date('started_at'), now);
    final saved = (await h.app.store.get(ApptCol.appointments, a1.id))!;
    expect(saved.str('status'), ApptStatus.checkedIn);
    expect(saved.str('encounter_id'), enc.id);
    expect(saved.integer('token_no'), 1);

    // Checking in twice is refused and creates nothing.
    await expectLater(AppointmentService.checkIn(h.db, a1, now: now), throwsA(isA<ValidationException>()));
    expect(await h.app.store.query(Query(Col.encounters).eq('source_id', a1.id).take(5)), hasLength(1));

    // A new day starts at token 1 again; other days' appointments wait for their day.
    final wed = DateTime(2030, 3, 13);
    final c1 = await AppointmentService.book(h.db, patientId: p5.id, doctorId: h.docA.id, start: at(9, 0, wed));
    final thu = await AppointmentService.book(h.db, patientId: p1.id, doctorId: h.docA.id, start: at(9, 0, DateTime(2030, 3, 14)));
    expect((await AppointmentService.checkIn(h.db, c1, now: at(9, 0, wed))).token, 1);
    await expectLater(AppointmentService.checkIn(h.db, thu, now: at(9, 0, wed)), throwsA(isA<ValidationException>()));

    // The appointment follows the visit as OPD calls the patient in and finishes.
    await h.app.systemDb.update(Col.encounters, enc.id, {'queue_status': Vals.withDoctor, 'called_at': at(9, 20)});
    var e = (await h.app.store.get(Col.encounters, enc.id))!;
    expect(AppointmentService.effectiveStatus(saved, e), ApptStatus.inConsultation);
    await AppointmentService.syncWithEncounters(h.app.systemDb, since: DateTime(2030));
    expect((await h.app.store.get(ApptCol.appointments, a1.id))!.str('status'), ApptStatus.inConsultation);
    await h.app.systemDb
        .update(Col.encounters, enc.id, {'queue_status': Vals.done, 'status': Vals.closed, 'ended_at': at(9, 35)});
    e = (await h.app.store.get(Col.encounters, enc.id))!;
    expect(AppointmentService.effectiveStatus(saved, e), ApptStatus.completed);
    await AppointmentService.syncWithEncounters(h.app.systemDb, since: DateTime(2030));
    expect((await h.app.store.get(ApptCol.appointments, a1.id))!.str('status'), ApptStatus.completed);
    await h.app.close();
  });

  test('walk-in books and checks in at once, continuing the token sequence', () async {
    final h = await _boot();
    final [p1, p2, p3, ..._] = h.patients;
    final booked = await AppointmentService.book(h.db, patientId: p1.id, doctorId: h.docA.id, start: at(9, 45));
    expect((await AppointmentService.checkIn(h.db, booked, now: at(9, 40))).token, 1);

    final w = await AppointmentService.walkIn(h.db, patientId: p2.id, doctorId: h.docA.id, reason: 'Fever', now: at(10, 5));
    expect(w.token, 2);
    final appt = w.appointment;
    expect(appt.str('kind'), ApptKind.walkIn);
    expect(appt.str('status'), ApptStatus.checkedIn);
    expect(appt.str('booked_via'), BookedVia.frontDesk);
    expect(appt.str('reason'), 'Fever');
    expect(appt.str('encounter_id'), w.encounter.id);
    expect(appt.date('start_at'), at(10, 5));
    expect(w.encounter.str('source_id'), appt.id);
    expect(w.encounter.str('queue_status'), Vals.waiting);
    expect(w.encounter.integer('token_no'), 2);

    // The same patient can't join the same doctor's queue twice.
    await expectLater(AppointmentService.walkIn(h.db, patientId: p2.id, doctorId: h.docA.id, now: at(10, 10)),
        throwsA(isA<ValidationException>()));
    // Walk-ins are squeezed in by token; they don't use up bookable slots.
    final w2 = await AppointmentService.walkIn(h.db, patientId: p3.id, doctorId: h.docA.id, now: at(9, 31));
    expect(w2.token, 3);
    expect(_times(await AppointmentService.freeSlotsOn(h.app.readDb, h.docA.id, day, now: at(8))),
        ['9:00 AM', '9:15 AM', '9:30 AM']);

    // The suggested doctor is the one with the shorter queue.
    final visits = await AppointmentService.opdVisitsOn(h.app.readDb, at(10));
    expect(AppointmentService.waitingCounts(visits)[h.docA.id], 3);
    expect(AppointmentService.suggestDoctor([h.docA, h.docB], visits, const {}, now: at(10)), h.docB.id);
    await h.app.close();
  });

  test('cancelling needs a reason; a cancelled appointment cannot be checked in', () async {
    final h = await _boot();
    final a = await AppointmentService.book(h.db, patientId: h.patients.first.id, doctorId: h.docA.id, start: at(9));
    await expectLater(AppointmentService.cancel(h.db, a, '   '), throwsA(isA<ValidationException>()));
    expect((await h.app.store.get(ApptCol.appointments, a.id))!.str('status'), ApptStatus.booked);

    final c = await AppointmentService.cancel(h.db, a, 'Doctor not available');
    expect(c.str('status'), ApptStatus.cancelled);
    expect(c.str('cancel_reason'), 'Doctor not available');
    await expectLater(AppointmentService.cancel(h.db, c, 'Again'), throwsA(isA<ValidationException>()));
    await expectLater(AppointmentService.checkIn(h.db, c, now: at(9)), throwsA(isA<ValidationException>()));
    await h.app.close();
  });

  test('missed appointments: one proposal; approving it only touches those still booked', () async {
    final h = await _boot();
    await addUser(h.app, 'board1', [Roles.board]);
    final now = DateTime.now();
    final [p1, p2, p3, p4, p5] = h.patients;
    Future<Rec> book(Rec p, Duration ago) =>
        AppointmentService.book(h.db, patientId: p.id, doctorId: h.docA.id, start: now.subtract(ago));
    final m1 = await book(p1, const Duration(hours: 3));
    final m2 = await book(p2, const Duration(hours: 4));
    final m3 = await book(p3, const Duration(hours: 5));
    final recent = await book(p4, const Duration(minutes: 30));
    final gone = await book(p5, const Duration(hours: 6));
    await AppointmentService.cancel(h.db, gone, 'Booked by mistake');

    // Checked directly, with a fixed clock.
    final report = await MissedAppointmentsAgent()
        .run(AgentContext(db: h.app.readDb, settings: h.app.settings, now: now));
    expect(report.findings, isEmpty);
    expect(report.proposals, hasLength(1));
    final p = report.proposals.single;
    expect(p.title, 'Mark 3 missed appointments as no-show');
    expect(p.handler, 'appointments.mark_no_show');
    expect((p.payload['appointment_ids'] as List).toSet(), {m1.id, m2.id, m3.id});
    expect(p.key, 'missed:${compactDay(now)}');

    // Through the runner and the control tower.
    await h.app.agents!.runById('appointments.missed');
    final proposal = (await h.app.store
            .query(const Query(Col.proposals).eq('agent_id', 'appointments.missed').eq('status', 'pending').take(5)))
        .single;
    // Meanwhile one patient phones to cancel.
    await AppointmentService.cancel(h.db, (await h.app.store.get(ApptCol.appointments, m2.id))!, 'Patient asked to cancel');

    await signIn(h.app, 'board1');
    final done = await h.app.tower.approveProposal(proposal);
    expect(done.str('status'), 'approved');
    expect(done.str('result'), contains('Marked 2 appointments as no-show'));
    Future<String> status(Rec a) async => (await h.app.store.get(ApptCol.appointments, a.id))!.str('status');
    expect(await status(m1), ApptStatus.noShow);
    expect(await status(m3), ApptStatus.noShow);
    expect(await status(m2), ApptStatus.cancelled);
    expect(await status(recent), ApptStatus.booked);
    expect(await status(gone), ApptStatus.cancelled);
    await h.app.close();
  });

  test('long-wait agent: over 45 minutes is medium, over 90 is high', () async {
    final h = await _boot();
    final now = at(12);
    final [p1, p2, p3, p4, p5] = h.patients;
    Future<Rec> visit(Rec p, int minutesAgo, {String queue = Vals.waiting, String status = Vals.open, int token = 1}) =>
        h.app.systemDb.insert(Col.encounters, {
          'patient_id': p.id,
          'type': Vals.opd,
          'status': status,
          'doctor_id': h.docA.id,
          'started_at': now.subtract(Duration(minutes: minutesAgo)),
          'checked_in_at': now.subtract(Duration(minutes: minutesAgo)),
          'queue_status': queue,
          'token_no': token,
        });
    await visit(p1, 30);
    await visit(p2, 45, token: 2);
    final medium = await visit(p3, 50, token: 3);
    final high = await visit(p4, 100, token: 4);
    await visit(p5, 120, queue: Vals.withDoctor, token: 5);

    final report = await LongWaitAgent().run(AgentContext(db: h.app.readDb, settings: h.app.settings, now: now));
    final byKey = {for (final f in report.findings) f.key: f};
    expect(byKey.keys.toSet(), {'enc:${medium.id}', 'enc:${high.id}'});
    expect(byKey['enc:${medium.id}']!.severity, Severity.medium);
    expect(byKey['enc:${high.id}']!.severity, Severity.high);
    expect(byKey['enc:${medium.id}']!.title, 'Waiting 50 min for Dr. Asha Rao');
    expect(byKey['enc:${high.id}']!.title, 'Waiting 1 h 40 min for Dr. Asha Rao');
    expect(byKey['enc:${medium.id}']!.patientId, p3.id);
    await h.app.close();
  });

  test('demo data fills a believable day', () async {
    final app = await bootTestHospital([PatientsModule(), AppointmentsModule()], demo: true);
    final db = app.readDb;
    final doctors = await AppointmentService.doctors(db);
    expect(doctors, hasLength(3));
    for (final d in doctors) {
      expect(await AppointmentService.schedulesFor(db, d.id), hasLength(greaterThanOrEqualTo(6)));
    }
    final today = await AppointmentService.appointmentsOn(db, DateTime.now());
    expect(today.length, inInclusiveRange(20, 32));
    final visits = await AppointmentService.opdVisitsOn(db, DateTime.now());
    expect(visits.where(AppointmentService.isWaiting).length, greaterThanOrEqualTo(5));
    expect(visits.where(AppointmentService.isWithDoctor).length, inInclusiveRange(2, 3));
    final history = await db.count(Query(ApptCol.appointments)
        .lt('start_at', dayOf(DateTime.now()))
        .gte('start_at', DateTime.now().subtract(const Duration(days: 31))));
    expect(history, greaterThanOrEqualTo(120));
    // Every checked-in demo appointment has exactly one matching visit.
    final linked = today.where((a) => a.strOrNull('encounter_id') != null).toList();
    final encs = await db.byIds(Col.encounters, linked.map((a) => a.str('encounter_id')));
    for (final a in linked) {
      expect(encs[a.str('encounter_id')]!.str('source_id'), a.id);
      expect(AppointmentService.statusFromEncounter(encs[a.str('encounter_id')]), a.str('status'));
    }
    final waits = await LongWaitAgent().run(AgentContext(db: db, settings: app.settings));
    expect(waits.findings, isNotEmpty);
    await app.close();
  });
}

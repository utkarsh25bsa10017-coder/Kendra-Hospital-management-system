import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/ipd/agents/bed_turnaround_agent.dart';
import 'package:kendra_hms/modules/ipd/agents/discharge_delay_agent.dart';
import 'package:kendra_hms/modules/ipd/agents/long_stay_agent.dart';
import 'package:kendra_hms/modules/ipd/agents/unbilled_bed_days_agent.dart';
import 'package:kendra_hms/modules/ipd/bed_charging.dart';
import 'package:kendra_hms/modules/ipd/bed_days.dart';
import 'package:kendra_hms/modules/ipd/ipd_module.dart';
import 'package:kendra_hms/modules/ipd/ipd_schema.dart';
import 'package:kendra_hms/modules/ipd/ipd_service.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

DateTime _d(int day, [int hour = 0, int minute = 0]) => DateTime(2026, 10, day, hour, minute);

/// A hospital with the default wards, one doctor and three patients.
class _Hospital {
  _Hospital(this.app, this.doctor, this.patients, this.beds, this.wards);
  final AppServices app;
  final Rec doctor;
  final List<Rec> patients;
  final Map<String, Rec> beds; // by label
  final Map<String, Rec> wards; // by kind
  Db get db => app.systemDb;

  static Future<_Hospital> boot() async {
    final app = await bootTestHospital([PatientsModule(), IpdModule()]);
    final doctor = await addUser(app, 'drtest', [Roles.doctor], extra: {'is_clinician': true, 'department': 'Medicine'});
    final patients = [
      for (final (i, n) in ['Asha Rao', 'Ravi Kumar', 'Meera Iyer'].indexed)
        await app.systemDb.insert(Col.patients, {
          'uhid': 'TH-26-00000${i + 1}',
          'first_name': n.split(' ').first,
          'last_name': n.split(' ').last,
          'full_name': n,
        }),
    ];
    final beds = {for (final b in await app.systemDb.query(const Query(IpdCol.beds).take(100))) b.str('label'): b};
    final wards = {for (final w in await app.systemDb.query(const Query(IpdCol.wards).take(100))) w.str('kind'): w};
    return _Hospital(app, doctor, patients, beds, wards);
  }

  Future<Rec> admit(int patient, String bed, DateTime at) => IpdService.admit(db,
      patientId: patients[patient].id, bedId: beds[bed]!.id, attendingDoctorId: doctor.id, diagnosis: 'Dengue fever', at: at);

  Future<Rec> bed(String label) async => (await db.get(IpdCol.beds, beds[label]!.id))!;

  Future<List<Rec>> charges(Rec admission) async => db.query(Query(Col.charges)
      .eq('source_collection', IpdCol.admissions)
      .startsWith('source_id', '${admission.id}:')
      .sort('service_date')
      .take(500));

  Future<AgentReport> runAgent(HmsAgent a, {DateTime? now}) =>
      a.run(AgentContext(db: ReadDb(app.store), settings: app.settings, now: now));
}

void main() {
  group('bed-day rule', () {
    test('same-day discharge counts as one day', () {
      expect(BedDays.count(admittedAt: _d(20, 9), dischargedAt: _d(20, 18), now: _d(24)), 1);
    });

    test('three nights are three bed-days; the discharge day is not charged', () {
      final days = BedDays.chargeableDays(admittedAt: _d(20, 10), dischargedAt: _d(23, 11), now: _d(24));
      expect(days, [_d(20), _d(21), _d(22)]);
    });

    test('admitted late at night still pays for the admission day', () {
      expect(BedDays.count(admittedAt: _d(20, 23, 40), dischargedAt: _d(21, 10), now: _d(24)), 1);
      expect(BedDays.count(admittedAt: _d(20, 23, 40), dischargedAt: _d(22, 10), now: _d(24)), 2);
    });

    test('while in hospital, today is not owed until midnight', () {
      expect(BedDays.chargeableDays(admittedAt: _d(22, 10), now: _d(24, 15)), [_d(22), _d(23)]);
      // Admitted today: the admission day is owed straight away.
      expect(BedDays.chargeableDays(admittedAt: _d(24, 9), now: _d(24, 15)), [_d(24)]);
    });

    test('each day is charged at the ward occupied at the start of the day', () {
      final plan = BedDays.plan(
        admittedAt: _d(20, 10),
        dischargedAt: _d(24, 12),
        admittingWardId: 'semi',
        moves: const [],
        now: _d(25),
      );
      expect(plan.map((d) => d.wardId), ['semi', 'semi', 'semi', 'semi']);
      final moved = BedDays.plan(
        admittedAt: _d(20, 10),
        dischargedAt: _d(24, 12),
        admittingWardId: 'semi',
        // Moved on the 22nd in the afternoon, then to ICU exactly at midnight of the 23rd.
        moves: [WardMove(_d(22, 15), 'private'), WardMove(_d(23), 'icu')],
        now: _d(25),
      );
      expect([for (final d in moved) '${d.day.day}:${d.wardId}'], ['20:semi', '21:semi', '22:semi', '23:icu']);
    });

    test('a move on the admission day does not change the admission day ward', () {
      final plan = BedDays.plan(
          admittedAt: _d(20, 9), dischargedAt: _d(22, 9), admittingWardId: 'general', moves: [WardMove(_d(20, 13), 'icu')], now: _d(25));
      expect([for (final d in plan) d.wardId], ['general', 'icu']);
    });

    test('day number', () {
      expect(BedDays.dayNumber(_d(20, 23), _d(20, 23, 30)), 1);
      expect(BedDays.dayNumber(_d(20, 23), _d(24, 1)), 5);
    });
  });

  group('admission, posting and discharge', () {
    late _Hospital h;
    setUp(() async => h = await _Hospital.boot());
    tearDown(() => h.app.close());

    test('defaults: price list and 30 beds in four wards', () async {
      expect(h.beds.length, 30);
      expect(h.wards.keys.toSet(), {'general', 'semi_private', 'private', 'icu'});
      final bedGen = await h.db.first(const Query(Col.services).eq('code', 'BED-GEN'));
      expect(bedGen!.integer('price_paise'), 120000);
      expect(h.beds['G-12'], isNotNull);
      expect(h.beds['ICU-06'], isNotNull);
    });

    test('admitting creates the encounter, occupies the bed, and posting is idempotent', () async {
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day - 3, 10);
      final adm = await h.admit(0, 'G-01', at);
      expect(adm.str('number'), startsWith('IP-'));
      final enc = (await h.db.get(Col.encounters, adm.str('encounter_id')))!;
      expect(enc.str('type'), Vals.ipd);
      expect(enc.str('status'), Vals.open);
      expect(enc.str('source_module'), 'ipd');
      expect(enc.str('source_id'), adm.id);
      expect(enc.date('started_at'), at);
      final bed = await h.bed('G-01');
      expect(bed.str('status'), IpdVals.occupied);
      expect(bed.str('admission_id'), adm.id);

      // Three days owed so far (today waits for midnight): bed + nursing each.
      expect(await BedCharging.post(h.db, adm), 3);
      var charges = await h.charges(adm);
      expect(charges.length, 6);
      final bedCharge = charges.firstWhere((c) => c.str('category') == Vals.bed);
      expect(bedCharge.str('service_code'), 'BED-GEN');
      expect(bedCharge.integer('amount_paise'), 120000);
      expect(bedCharge.str('status'), Vals.pending);
      expect(bedCharge.str('encounter_id'), enc.id);
      expect(bedCharge.str('description'), 'Bed — General Ward A — ${formatDateShort(at)}');
      expect(bedCharge.str('source_id'), '${adm.id}:${dayKey(at)}:bed');
      expect(charges.where((c) => c.str('category') == Vals.nursing).first.str('service_code'), 'NURSING-GEN');

      // Again, and again through the hourly job: nothing new.
      expect(await BedCharging.post(h.db, adm), 0);
      expect(await BedCharging.postAll(h.db), 0);
      charges = await h.charges(adm);
      expect(charges.length, 6);
      final fresh = (await h.db.get(IpdCol.admissions, adm.id))!;
      expect(fresh.date('bed_charges_posted_until'), DateTime(now.year, now.month, now.day - 1));
      expect(BedCharging.upToDate(fresh, now), isTrue);
    });

    test('a bed-day already posted from another device is not posted twice', () async {
      final now = DateTime.now();
      final adm = await h.admit(0, 'G-02', DateTime(now.year, now.month, now.day - 2, 9));
      final p = await BedCharging.prepare(h.db, adm, now: now);
      expect(p.ops.length, 4);
      await h.db.batch([p.ops.first]); // someone else posted the first bed charge
      expect(await BedCharging.post(h.db, adm), 2);
      expect((await h.charges(adm)).length, 4);
      // Inserting the same bed-day again fails instead of duplicating it.
      await expectLater(h.db.batch([p.ops.first]), throwsA(isA<ValidationException>()));
    });

    test('cannot admit into an occupied bed, or admit the same patient twice', () async {
      final now = DateTime.now();
      await h.admit(0, 'G-03', now);
      await expectLater(h.admit(1, 'G-03', now), throwsA(isA<ValidationException>()));
      await expectLater(h.admit(0, 'G-04', now), throwsA(isA<ValidationException>()));
      // A bed in cleaning or maintenance is not free either.
      await IpdService.setMaintenance(h.db, await h.bed('G-05'), true);
      await expectLater(h.admit(1, 'G-05', now), throwsA(isA<ValidationException>()));
      expect((await h.bed('G-04')).str('status'), IpdVals.available);
      expect(await h.db.count(const Query(IpdCol.admissions)), 1);
    });

    test('transfer mid-stay: each day is charged at the right ward, old bed goes for cleaning', () async {
      final now = DateTime.now();
      DateTime day(int ago, [int hour = 0]) => DateTime(now.year, now.month, now.day - ago, hour);
      final adm = await h.admit(1, 'S-01', day(4, 10));
      await IpdService.transfer(h.db, adm, toBedId: h.beds['P-01']!.id, reason: 'Upgrade to private room', at: day(2, 15));
      expect((await h.bed('S-01')).str('status'), IpdVals.cleaning);
      expect((await h.bed('P-01')).str('status'), IpdVals.occupied);
      await BedCharging.post(h.db, adm);
      final beds = (await h.charges(adm)).where((c) => c.str('category') == Vals.bed).toList();
      expect([for (final c in beds) c.str('service_code')], ['BED-SEMI', 'BED-SEMI', 'BED-SEMI', 'BED-PVT']);
      expect([for (final c in beds) c.date('service_date')], [day(4), day(3), day(2), day(1)]);
      expect(beds.last.str('description'), startsWith('Bed — Private rooms — '));
      // Cannot move into an occupied bed.
      await h.admit(2, 'P-02', now);
      await expectLater(
          IpdService.transfer(h.db, (await h.db.get(IpdCol.admissions, adm.id))!, toBedId: h.beds['P-02']!.id, reason: 'x'),
          throwsA(isA<ValidationException>()));
    });

    test('discharge: posts the remaining days, frees the bed and closes the encounter', () async {
      final now = DateTime.now();
      final adm = await h.admit(0, 'ICU-01', DateTime(now.year, now.month, now.day - 3, 22));
      // Nothing posted yet: completing must post all owed days in the same step.
      await expectLater(IpdService.completeDischarge(h.db, adm), throwsA(isA<ValidationException>()),
          reason: 'the doctor has not signed off');
      final pending = await IpdService.requestDischarge(h.db, adm, type: 'normal', summary: 'Recovered', advice: 'Review in a week');
      expect(pending.str('status'), IpdVals.dischargePending);
      expect((await h.bed('ICU-01')).str('status'), IpdVals.occupied, reason: 'the patient keeps the bed until discharge');
      expect(await IpdService.completeDischarge(h.db, pending), 3);
      final done = (await h.db.get(IpdCol.admissions, adm.id))!;
      expect(done.str('status'), IpdVals.discharged);
      expect(done.date('discharged_at'), isNotNull);
      final bed = await h.bed('ICU-01');
      expect(bed.str('status'), IpdVals.cleaning);
      expect(bed.str('admission_id'), isEmpty);
      final enc = (await h.db.get(Col.encounters, adm.str('encounter_id')))!;
      expect(enc.str('status'), Vals.closed);
      expect(enc.date('ended_at'), isNotNull);
      final charges = await h.charges(adm);
      expect(charges.length, 6, reason: '3 bed-days, discharge day not charged');
      expect(charges.where((c) => c.str('category') == Vals.bed).every((c) => c.integer('amount_paise') == 900000), isTrue);
      expect(charges.where((c) => c.str('category') == Vals.nursing).every((c) => c.str('service_code') == 'NURSING-ICU'), isTrue);
      // The bed can be readied and reused; the posting job leaves the finished stay alone.
      await IpdService.markReady(h.db, bed);
      await h.admit(1, 'ICU-01', now);
      await BedCharging.postAll(h.db);
      expect((await h.charges(adm)).length, 6);
      await expectLater(IpdService.completeDischarge(h.db, done), throwsA(isA<ValidationException>()));
    });

    test('same-day discharge is charged one day', () async {
      final now = DateTime.now();
      final adm = await h.admit(2, 'G-06', DateTime(now.year, now.month, now.day));
      await IpdService.requestDischarge(h.db, adm, type: 'normal', summary: 'Day care transfusion');
      await IpdService.completeDischarge(h.db, (await h.db.get(IpdCol.admissions, adm.id))!);
      expect((await h.charges(adm)).length, 2);
    });

    test('permissions: a nurse admits and writes notes, billing cannot admit', () async {
      await addUser(h.app, 'nurse1', [Roles.nurse]);
      await addUser(h.app, 'bill1', [Roles.billing]);
      await signIn(h.app, 'nurse1');
      final adm = await IpdService.admit(h.app.db,
          patientId: h.patients[0].id, bedId: h.beds['G-07']!.id, attendingDoctorId: h.doctor.id, diagnosis: 'Pneumonia');
      await IpdService.addNote(h.app.db, admission: adm, kind: 'vitals', vitals: {'pulse': 88, 'spo2': 96}, byName: 'Nurse');
      expect(await h.db.count(Query(IpdCol.notes).eq('admission_id', adm.id)), 1);
      await signIn(h.app, 'bill1');
      await expectLater(
          IpdService.admit(h.app.db, patientId: h.patients[1].id, bedId: h.beds['G-08']!.id, attendingDoctorId: h.doctor.id),
          throwsA(isA<PermissionDeniedException>()));
      // Let the session refresh that follows a sign-in finish before the database closes.
      await pumpEventQueue();
    });

    test('unbilled bed-days agent flags a removed or missing day', () async {
      final now = DateTime.now();
      final agent = UnbilledBedDaysAgent();
      final adm = await h.admit(0, 'G-09', DateTime(now.year, now.month, now.day - 4, 11));
      await BedCharging.post(h.db, adm);
      expect((await h.runAgent(agent)).findings, isEmpty);

      // Someone archives one nursing charge: the agent notices, the job does not re-post it.
      final nursing = (await h.charges(adm)).firstWhere((c) => c.str('category') == Vals.nursing);
      await h.db.archive(Col.charges, nursing.id, reason: 'test');
      await BedCharging.post(h.db, adm);
      var report = await h.runAgent(agent);
      expect(report.findings.length, 1);
      final f = report.findings.single;
      expect(f.key, 'admission:${adm.id}');
      expect(f.severity, Severity.high);
      expect(f.amountAtRiskPaise, 50000);
      expect(f.patientId, h.patients[0].id);

      // A stay whose charges were never posted at all.
      final other = await h.admit(1, 'P-03', DateTime(now.year, now.month, now.day - 2, 9));
      report = await h.runAgent(agent);
      final g = report.findings.firstWhere((x) => x.key == 'admission:${other.id}');
      expect(g.amountAtRiskPaise, 2 * (450000 + 50000));

      // A replacement charge raised by hand for that day counts as billed.
      await h.db.insert(Col.charges, {
        'patient_id': h.patients[0].id,
        'encounter_id': adm.str('encounter_id'),
        'description': 'Nursing (re-raised)',
        'category': Vals.nursing,
        'quantity': 1,
        'amount_paise': 50000,
        'status': Vals.pending,
        'service_date': nursing.date('service_date'),
      });
      report = await h.runAgent(agent);
      expect(report.findings.map((x) => x.key), ['admission:${other.id}']);
    });

    test('long stay, turnaround and discharge delay agents', () async {
      final now = DateTime.now();
      final longStay = await h.admit(0, 'G-10', DateTime(now.year, now.month, now.day - 12, 10));
      final pending = await h.admit(1, 'G-11', DateTime(now.year, now.month, now.day - 2, 10));
      await IpdService.requestDischarge(h.db, pending,
          type: 'normal', summary: 'Better', at: now.subtract(const Duration(hours: 5)));
      await IpdService.requestDischarge(h.db, await h.admit(2, 'G-12', now), type: 'normal', summary: 'Better');
      final cleaning = await h.db.update(IpdCol.beds, h.beds['S-06']!.id,
          {'status': IpdVals.cleaning, 'status_since': now.subtract(const Duration(hours: 5))});
      await h.db.update(IpdCol.beds, h.beds['S-05']!.id,
          {'status': IpdVals.cleaning, 'status_since': now.subtract(const Duration(hours: 1))});

      expect((await h.runAgent(LongStayAgent())).findings.map((f) => f.key), ['admission:${longStay.id}']);
      expect((await h.runAgent(BedTurnaroundAgent())).findings.map((f) => f.key), ['bed:${cleaning.id}']);
      final delays = (await h.runAgent(DischargeDelayAgent())).findings;
      expect(delays.map((f) => f.key), ['admission:${pending.id}']);
      expect(delays.single.severity, Severity.medium);
    });

    test('adding a range of beds skips labels that exist', () async {
      final ward = h.wards['general']!;
      expect(IpdService.bedLabels('G-', 13, 16), ['G-13', 'G-14', 'G-15', 'G-16']);
      expect(await IpdService.addBeds(h.db, ward, IpdService.bedLabels('G-', 11, 14)), 2);
      expect(await h.db.count(Query(IpdCol.beds).eq('ward_id', ward.id)), 14);
    });
  });

  test('demo hospital: occupancy, charges and agent findings', () async {
    final app = await bootTestHospital([PatientsModule(), IpdModule()], demo: true);
    final db = app.systemDb;
    final beds = await db.query(const Query(IpdCol.beds).eq('active', true).take(100));
    int n(String s) => beds.where((b) => b.str('status') == s).length;
    expect(beds.length, 30);
    expect(n(IpdVals.occupied), 18);
    expect(n(IpdVals.cleaning), 2);
    expect(n(IpdVals.maintenance), 1);
    expect(await db.count(Query(IpdCol.admissions).isIn('status', IpdVals.current)), 18);
    expect(await db.count(const Query(IpdCol.admissions).eq('status', IpdVals.dischargePending)), 1);
    expect(await db.count(const Query(IpdCol.admissions).eq('status', IpdVals.discharged)), greaterThanOrEqualTo(18));
    expect(await db.count(const Query(IpdCol.transfers)), 1);
    // Every occupied bed points at a current admission that points back.
    for (final b in beds.where((b) => b.str('status') == IpdVals.occupied)) {
      final a = await db.get(IpdCol.admissions, b.str('admission_id'));
      expect(a?.str('bed_id'), b.id);
    }
    expect(await db.count(const Query(Col.charges).eq('source_module', 'ipd')), greaterThan(150));
    final ctx = AgentContext(db: ReadDb(app.store), settings: app.settings);
    final unbilled = await UnbilledBedDaysAgent().run(ctx);
    expect(unbilled.findings.length, 1, reason: 'only the cancelled demo charge');
    expect((await BedTurnaroundAgent().run(ctx)).findings.length, 1);
    expect((await DischargeDelayAgent().run(ctx)).findings.length, 1);
    expect((await LongStayAgent().run(ctx)).findings, isNotEmpty);
    await app.close();
  });
}

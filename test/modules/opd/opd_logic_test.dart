import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/opd/agents/critical_vitals_agent.dart';
import 'package:kendra_hms/modules/opd/agents/unsigned_notes_agent.dart';
import 'package:kendra_hms/modules/opd/clinical.dart';
import 'package:kendra_hms/modules/opd/opd_module.dart';
import 'package:kendra_hms/modules/opd/opd_schema.dart';
import 'package:kendra_hms/modules/opd/opd_service.dart';
import 'package:kendra_hms/modules/opd/screens/opd_widgets.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

Future<Rec> _patient(AppServices app, String name, {String allergies = ''}) => app.systemDb.insert(Col.patients, {
      'uhid': 'TH-${name.hashCode.abs()}',
      'first_name': name.split(' ').first,
      'last_name': name.split(' ').last,
      'full_name': name,
      'gender': 'male',
      'age_years': 40,
      'allergies': allergies,
    });

Future<Rec> _doctor(AppServices app, String username, String name, {int? fee, String dept = 'General Medicine'}) =>
    addUser(app, username, [Roles.doctor], extra: {
      'display_name': name,
      'is_clinician': true,
      'department': dept,
      'consultation_fee_paise': ?fee,
    });

Map<String, Object?> _med(String name, {String? generic, String freq = '1-0-1', int days = 5, int? qty}) => {
      'medicine_id': null,
      'drug_name': name,
      'generic_name': generic,
      'dose': '1 tablet',
      'frequency': freq,
      'duration_days': days,
      'route': 'Oral',
      'instructions': 'After food',
      'quantity': qty ?? Rx.quantity(frequency: freq, days: days, form: 'tablet'),
    };

Future<int> _count(AppServices app, Query q) => app.readDb.count(q);

void main() {
  group('vitals', () {
    test('critical thresholds follow the agreed limits', () {
      bool crit(Map<String, Object?> v) => Vitals.critical(v).isNotEmpty;
      expect(crit({'spo2': 89}), isTrue);
      expect(crit({'spo2': 90}), isFalse);
      expect(crit({'bp_sys': 180, 'bp_dia': 100}), isTrue);
      expect(crit({'bp_sys': 179, 'bp_dia': 100}), isFalse);
      expect(crit({'bp_sys': 90, 'bp_dia': 60}), isTrue);
      expect(crit({'bp_sys': 91, 'bp_dia': 60}), isFalse);
      expect(crit({'bp_sys': 150, 'bp_dia': 120}), isTrue);
      expect(crit({'bp_sys': 150, 'bp_dia': 119}), isFalse);
      expect(crit({'pulse': 131}), isTrue);
      expect(crit({'pulse': 130}), isFalse);
      expect(crit({'pulse': 44}), isTrue);
      expect(crit({'pulse': 45}), isFalse);
      expect(crit({'temp_c': 39.5}), isTrue);
      expect(crit({'temp_c': 39.4}), isFalse);
      expect(Vitals.critical({'spo2': 88, 'pulse': 112}), ['SpO2 88%']);
    });

    test('abnormal levels, BMI, BP and °F parsing', () {
      expect(Vitals.level(VitalKeys.spo2, 93), VitalLevel.abnormal);
      expect(Vitals.level(VitalKeys.bpSys, 145), VitalLevel.abnormal);
      expect(Vitals.level(VitalKeys.pulse, 80), VitalLevel.normal);
      expect(Vitals.bmi(70, 175), 22.9);
      expect(Vitals.bmi(70, null), isNull);
      expect(Vitals.parseBp('120/80'), (120, 80));
      expect(Vitals.parseBp('120 / 80'), (120, 80));
      expect(Vitals.parseBp('120'), isNull);
      expect(Vitals.tempToC(101), 38.3);
      expect(Vitals.tempToC(37.2), 37.2);
      final clean = Vitals.clean({'weight_kg': 70, 'height_cm': 175, 'pulse': '', 'spo2': '98'});
      expect(clean, {'spo2': 98, 'weight_kg': 70, 'height_cm': 175, 'bmi': 22.9});
    });
  });

  group('prescription helpers', () {
    test('quantity is worked out from frequency, days, dose and form', () {
      expect(Rx.quantity(frequency: '1-0-1', days: 5, form: 'tablet'), 10);
      expect(Rx.quantity(frequency: '1-1-1', days: 3, form: 'tablet'), 9);
      expect(Rx.quantity(frequency: '1-0-0', days: 30, form: 'tablet'), 30);
      expect(Rx.quantity(frequency: '1-0-1', days: 5, form: 'tablet', dose: '2 tablets'), 20);
      expect(Rx.quantity(frequency: '½-0-½', days: 10, form: 'tablet'), 10);
      expect(Rx.quantity(frequency: 'BD', days: 7, form: 'capsule'), 14);
      expect(Rx.quantity(frequency: '1-1-1', days: 5, form: 'syrup'), 1, reason: 'one bottle');
      expect(Rx.quantity(frequency: '1-0-1', days: 7, name: 'Volini Gel'), 1, reason: 'one tube');
      expect(Rx.quantity(frequency: 'SOS', days: 3, form: 'tablet'), 3);
      expect(Rx.quantity(frequency: 'SOS', form: 'tablet'), 5);
      expect(Rx.quantity(frequency: '1-0-1', form: 'tablet'), isNull, reason: 'no duration yet');
    });

    test('allergy matching knows drug classes and ignores "no known allergies"', () {
      expect(Allergy.match('Penicillin', drugName: 'Augmentin 625', genericName: 'Amoxicillin + Clavulanic acid'), 'Penicillin');
      expect(Allergy.match('penicillin allergy', drugName: 'Ampicillin 500'), 'penicillin allergy');
      expect(Allergy.match('Sulfa drugs', drugName: 'Bactrim DS', genericName: 'Sulfamethoxazole + Trimethoprim'), 'Sulfa drugs');
      expect(Allergy.match('Paracetamol', drugName: 'Dolo 650', genericName: 'Paracetamol'), 'Paracetamol');
      expect(Allergy.match('Dust, Ibuprofen', drugName: 'Combiflam', genericName: 'Ibuprofen + Paracetamol'), 'Ibuprofen');
      expect(Allergy.match('Peanuts', drugName: 'Dolo 650', genericName: 'Paracetamol'), isNull);
      expect(Allergy.match('Penicillin', drugName: 'Dolo 650', genericName: 'Paracetamol'), isNull);
      expect(Allergy.match('', drugName: 'Augmentin 625', genericName: 'Amoxicillin'), isNull);
      expect(Allergy.match('No known allergies', drugName: 'Augmentin 625', genericName: 'Amoxicillin'), isNull);
      expect(Allergy.match('NKDA', drugName: 'Augmentin 625'), isNull);
      expect(Allergy.match('None', drugName: 'Azithral 500', genericName: 'Azithromycin'), isNull);
    });

    test('one-tap phrases append naturally', () {
      expect(PhraseField.appendPhrase('', 'Fever'), 'Fever');
      expect(PhraseField.appendPhrase('Fever', 'Cough'), 'Fever, cough');
      expect(PhraseField.appendPhrase('Fever, cough', 'since 2 days'), 'Fever, cough since 2 days');
      expect(PhraseField.appendPhrase('Afebrile', 'P/A soft, non-tender'), 'Afebrile, P/A soft, non-tender');
      expect(PhraseField.appendPhrase('Fever, cough', 'Cough'), 'Fever, cough', reason: 'no duplicates');
      expect(PhraseField.removePhrase('Fever, cough', 'Cough'), 'Fever');
      expect(PhraseField.removePhrase('Fever, cough', 'Fever'), 'Cough');
      expect(PhraseField.removePhrase('Fever, cough, cold', 'Cough'), 'Fever, cold');
    });
  });

  group('queue and consultation', () {
    late AppServices app;
    late Rec doc;
    late Rec doc2;
    late Rec ravi;
    late Rec sita;

    setUp(() async {
      app = await bootTestHospital([PatientsModule(), OpdModule()]);
      doc = await _doctor(app, 'drtest', 'Dr. Test Doctor', fee: 60000);
      doc2 = await _doctor(app, 'drsecond', 'Meera Rao');
      await addUser(app, 'nurse1', [Roles.nurse], extra: {'display_name': 'Nurse One'});
      ravi = await _patient(app, 'Ravi Kumar', allergies: 'Penicillin');
      sita = await _patient(app, 'Sita Devi');
    });

    tearDown(() => app.close());

    test('walk-ins get the next token of the day, per doctor', () async {
      await signIn(app, 'drtest');
      final (a, aNew) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: doc);
      final (b, _) = await OpdService.addWalkIn(app.db, patientId: sita.id, doctor: doc);
      final (c, _) = await OpdService.addWalkIn(app.db, patientId: sita.id, doctor: doc2);
      final (again, againNew) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: doc);
      expect(aNew, isTrue);
      expect(b.integer('token_no'), a.integer('token_no') + 1);
      expect(c.integer('token_no'), 1, reason: 'each doctor has their own tokens');
      expect(againNew, isFalse, reason: 'already in the queue today');
      expect(again.id, a.id);
      expect(a.str('type'), Vals.opd);
      expect(a.str('status'), Vals.open);
      expect(a.str('queue_status'), Vals.waiting);
      expect(a.str('source_module'), 'opd');
      expect(a.date('checked_in_at'), isNotNull);

      expect((await OpdService.nextWaiting(app.readDb, doc.id))!.id, a.id);
      final note = await OpdService.start(app.db, a, doctor: doc);
      expect(note.str('status'), ConsultStatus.draft);
      final started = (await app.readDb.get(Col.encounters, a.id))!;
      expect(started.str('queue_status'), Vals.withDoctor);
      expect(started.date('called_at'), isNotNull);
      expect((await OpdService.nextWaiting(app.readDb, doc.id))!.id, b.id);

      await OpdService.markLeft(app.db, b);
      final left = (await app.readDb.get(Col.encounters, b.id))!;
      expect(left.str('queue_status'), Vals.left);
      expect(left.str('status'), Vals.cancelled);
      expect(await OpdService.nextWaiting(app.readDb, doc.id), isNull);
      await OpdService.backToQueue(app.db, left);
      expect((await OpdService.nextWaiting(app.readDb, doc.id))!.id, b.id);
    });

    test('finishing writes one charge, one prescription, the orders, and closes the visit — once', () async {
      await signIn(app, 'drtest');
      final me = app.auth.session!.user;
      final (enc, _) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: me);
      final note = await OpdService.start(app.db, enc, doctor: me);
      await OpdService.saveDraft(app.db, note.id, {
        'chief_complaint': 'Fever since 2 days',
        'diagnosis': 'Viral fever',
        'icd_code': 'B34.9',
        'rx_draft': [
          _med('Dolo 650', generic: 'Paracetamol', freq: '1-1-1', days: 3),
          _med('Levocet 5', generic: 'Levocetirizine', freq: '0-0-1'),
        ],
        'orders_draft': [
          {'service_code': null, 'name': 'Complete blood count (CBC)', 'order_type': 'lab', 'priority': 'urgent'},
          {'service_code': null, 'name': 'X-ray chest PA view', 'order_type': 'radiology', 'priority': 'routine'},
        ],
      });

      final r = await OpdService.finish(app.db, note.id, signer: me);
      expect(r.alreadySigned, isFalse);
      expect(r.medicineCount, 2);
      expect(r.orderCount, 2);
      expect(r.chargePaise, 60000);

      final charges = await app.readDb.query(Query(Col.charges).eq('encounter_id', enc.id));
      expect(charges, hasLength(1));
      final ch = charges.single;
      expect(ch.str('service_code'), 'CONSULT');
      expect(ch.str('description'), 'Consultation — Dr. Test Doctor');
      expect(ch.str('category'), Vals.consultation);
      expect(ch.integer('quantity'), 1);
      expect(ch.integer('unit_price_paise'), 60000);
      expect(ch.integer('amount_paise'), 60000);
      expect(ch.str('status'), Vals.pending);
      expect(ch.str('source_module'), 'opd');
      expect(ch.str('source_collection'), OpdCol.consultations);
      expect(ch.str('source_id'), note.id);
      expect(ch.str('ordered_by'), me.id);
      expect(ch.date('service_date'), isNotNull);

      final rx = await app.readDb.query(Query(Col.prescriptions).eq('encounter_id', enc.id));
      expect(rx, hasLength(1));
      expect(rx.single.str('status'), Vals.active);
      expect(rx.single.str('doctor_id'), me.id);
      final items = rx.single.maps('items');
      expect(items.map((i) => i['drug_name']), ['Dolo 650', 'Levocet 5']);
      expect(items.first['quantity'], 9);
      expect(items.first.containsKey('medicine_id'), isTrue);

      final orders = await app.readDb.query(Query(Col.serviceOrders).eq('encounter_id', enc.id).sort('name'));
      expect(orders, hasLength(2));
      expect(orders.map((o) => o.str('order_type')), ['lab', 'radiology']);
      expect(orders.first.str('status'), Vals.ordered);
      expect(orders.first.str('priority'), 'urgent');
      expect(orders.first.str('ordered_by'), me.id);
      expect(orders.first.str('patient_id'), ravi.id);
      expect(orders.first.str('clinical_notes'), 'Viral fever');

      final closed = (await app.readDb.get(Col.encounters, enc.id))!;
      expect(closed.str('status'), Vals.closed);
      expect(closed.str('queue_status'), Vals.done);
      expect(closed.date('ended_at'), isNotNull);

      final signed = (await app.readDb.get(OpdCol.consultations, note.id))!;
      expect(signed.str('status'), ConsultStatus.signed);
      expect(signed.str('signed_by'), me.id);
      expect(signed.date('signed_at'), isNotNull);
      expect(signed.str('prescription_id'), rx.single.id);

      // Finishing again (double tap, second device) adds nothing.
      final again = await OpdService.finish(app.db, note.id, signer: me);
      expect(again.alreadySigned, isTrue);
      expect(await _count(app, Query(Col.charges).eq('encounter_id', enc.id)), 1);
      expect(await _count(app, Query(Col.prescriptions).eq('encounter_id', enc.id)), 1);
      expect(await _count(app, Query(Col.serviceOrders).eq('encounter_id', enc.id)), 2);
      await expectLater(OpdService.saveDraft(app.db, note.id, {'diagnosis': 'x'}), throwsA(isA<ValidationException>()));
    });

    test('two finishes at the same moment still make one charge', () async {
      await signIn(app, 'drtest');
      final me = app.auth.session!.user;
      final (enc, _) = await OpdService.addWalkIn(app.db, patientId: sita.id, doctor: me);
      final note = await OpdService.start(app.db, enc, doctor: me);
      await OpdService.saveDraft(app.db, note.id, {'diagnosis': 'Acute gastritis', 'rx_draft': [_med('Pan 40')]});
      final outcomes = await Future.wait([
        for (var i = 0; i < 2; i++)
          OpdService.finish(app.db, note.id, signer: me).then((_) => 'ok', onError: (Object e) => e.runtimeType.toString()),
      ]);
      expect(outcomes, contains('ok'));
      expect(await _count(app, Query(Col.charges).eq('source_id', note.id)), 1);
      expect(await _count(app, Query(Col.prescriptions).eq('encounter_id', enc.id)), 1);
    });

    test('a finish with no medicines or tests still charges and closes', () async {
      await signIn(app, 'drsecond');
      final me = app.auth.session!.user;
      final (enc, _) = await OpdService.addWalkIn(app.db, patientId: sita.id, doctor: me);
      final note = await OpdService.start(app.db, enc, doctor: me);
      await OpdService.saveDraft(app.db, note.id, {'diagnosis': 'Routine check-up'});
      final r = await OpdService.finish(app.db, note.id, signer: me);
      expect(r.prescriptionId, isNull);
      expect(r.chargePaise, 50000, reason: 'no fee set and no CONSULT price: ₹500');
      expect(await _count(app, Query(Col.prescriptions).eq('encounter_id', enc.id)), 0);
      expect((await app.readDb.get(Col.encounters, enc.id))!.str('status'), Vals.closed);
      final ch = (await app.readDb.first(Query(Col.charges).eq('source_id', note.id)))!;
      expect(ch.str('description'), 'Consultation — Dr. Meera Rao');

      // With a CONSULT price on the price list, that is the fallback.
      await app.systemDb.insert(Col.services,
          {'code': 'CONSULT', 'name': 'Consultation', 'category': Vals.consultation, 'price_paise': 45000, 'active': true});
      expect(await OpdService.consultationFee(app.readDb, me), 45000);
      expect(await OpdService.consultationFee(app.readDb, doc), 60000);
    });

    test('amending needs a reason, records old and new, and only the signer may', () async {
      await signIn(app, 'drtest');
      final me = app.auth.session!.user;
      final (enc, _) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: me);
      final draft = await OpdService.start(app.db, enc, doctor: me);
      await expectLater(
          OpdService.amend(app.db, draft, {'diagnosis': 'X'}, reason: 'Typing error', byName: me.str('display_name')),
          throwsA(isA<ValidationException>()),
          reason: 'drafts are edited, not amended');
      await OpdService.saveDraft(app.db, draft.id, {'diagnosis': 'Viral fever', 'examination': 'Throat congested'});
      await OpdService.finish(app.db, draft.id, signer: me);
      final signed = (await app.readDb.get(OpdCol.consultations, draft.id))!;

      await expectLater(
          OpdService.amend(app.db, signed, {'diagnosis': 'Dengue fever'}, reason: '  ', byName: 'Dr. Test Doctor'),
          throwsA(isA<ValidationException>()));
      await expectLater(
          OpdService.amend(app.db, signed, {'diagnosis': 'Viral fever'}, reason: 'No change', byName: 'Dr. Test Doctor'),
          throwsA(isA<ValidationException>()),
          reason: 'nothing changed');

      final updated = await OpdService.amend(
        app.db,
        signed,
        {'diagnosis': 'Dengue fever', 'icd_code': 'A90', 'examination': 'Throat congested'},
        reason: 'Lab result reviewed',
        byName: 'Dr. Test Doctor',
      );
      expect(updated.str('diagnosis'), 'Dengue fever');
      expect(updated.str('status'), ConsultStatus.signed);
      expect(updated.date('amended_at'), isNotNull);
      final a = (await app.readDb.first(Query(OpdCol.amendments).eq('consultation_id', signed.id)))!;
      expect(a.str('reason'), 'Lab result reviewed');
      expect(a.str('amended_by_name'), 'Dr. Test Doctor');
      expect(a.str('patient_id'), ravi.id);
      expect(a.maps('changes'), [
        {'field': 'diagnosis', 'old': 'Viral fever', 'new': 'Dengue fever'},
        {'field': 'icd_code', 'old': null, 'new': 'A90'},
      ]);

      await signIn(app, 'drsecond');
      await expectLater(
          OpdService.amend(app.db, updated, {'diagnosis': 'Typhoid fever'}, reason: 'Second opinion', byName: 'Dr. Meera Rao'),
          throwsA(isA<PermissionDeniedException>()));
    });

    test('nurse vitals open a draft; the agents flag critical vitals and old drafts', () async {
      await signIn(app, 'drtest');
      final (enc, _) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: doc);
      await signIn(app, 'nurse1');
      expect(app.auth.can(OpdPerms.vitals), isTrue);
      expect(app.auth.can(OpdPerms.consult), isFalse);
      final c = await OpdService.recordVitals(app.db, enc, {'bp_sys': 130, 'bp_dia': 84, 'spo2': 88, 'pulse': 104},
          byName: 'Nurse One');
      expect(c.str('status'), ConsultStatus.draft);
      expect(c.str('doctor_id'), doc.id);
      expect(c.str('vitals_by_name'), 'Nurse One');
      expect(c.date('vitals_at'), isNotNull);

      final ctx = AgentContext(db: app.readDb, settings: app.settings);
      final crit = await CriticalVitalsAgent().run(ctx);
      expect(crit.findings, hasLength(1));
      final f = crit.findings.single;
      expect(f.severity, Severity.high);
      expect(f.title, 'Critical vitals: Ravi Kumar');
      expect(f.summary, contains('SpO2 88%'));
      expect(f.patientId, ravi.id);
      expect(f.evidence.single.routeId, 'opd.consult');

      expect((await UnsignedNotesAgent().run(ctx)).findings, isEmpty, reason: 'only a few minutes old');
      final later = AgentContext(db: app.readDb, settings: app.settings, now: DateTime.now().add(const Duration(hours: 13)));
      final unsigned = await UnsignedNotesAgent().run(later);
      expect(unsigned.findings, hasLength(1));
      expect(unsigned.findings.single.severity, Severity.low);
      expect(unsigned.findings.single.subjectKey, 'doctor:${doc.id}');
      expect(unsigned.findings.single.evidence.single.routeId, 'opd.consult');
      expect(unsigned.findings.single.evidence.single.routeArgs, {'encounterId': enc.id});
      expect((await CriticalVitalsAgent().run(
              AgentContext(db: app.readDb, settings: app.settings, now: DateTime.now().add(const Duration(hours: 25)))))
          .findings, isEmpty, reason: 'only the last 24 hours count');

      // A patient who left has nothing to sign.
      await OpdService.markLeft(app.db, enc);
      expect((await UnsignedNotesAgent().run(later)).findings, isEmpty);
    });

    test('start for patient reuses today\'s open visit', () async {
      await signIn(app, 'drtest');
      final me = app.auth.session!.user;
      final e1 = await OpdService.startForPatient(app.db, ravi, me);
      final e2 = await OpdService.startForPatient(app.db, ravi, me);
      expect(e2.id, e1.id);
      expect(await _count(app, Query(Col.encounters).eq('patient_id', ravi.id)), 1);
      expect(await _count(app, Query(OpdCol.consultations).eq('encounter_id', e1.id)), 1);
      expect((await app.readDb.get(Col.encounters, e1.id))!.str('queue_status'), Vals.withDoctor);
    });

    test('repeat last prescription and frequent diagnoses', () async {
      await signIn(app, 'drtest');
      final me = app.auth.session!.user;
      for (final dx in ['Viral fever', 'Viral fever', 'Acute gastritis']) {
        final (enc, _) = await OpdService.addWalkIn(app.db, patientId: ravi.id, doctor: me);
        final note = await OpdService.start(app.db, enc, doctor: me);
        await OpdService.saveDraft(app.db, note.id, {
          'diagnosis': dx,
          'rx_draft': [_med(dx == 'Viral fever' ? 'Dolo 650' : 'Pan 40')],
        });
        await OpdService.finish(app.db, note.id, signer: me);
      }
      final freq = await OpdService.frequentDiagnoses(app.readDb, me.id);
      expect(freq.first.name, 'Viral fever');
      expect(freq.map((d) => d.name), containsAll(['Viral fever', 'Acute gastritis']));
      final last = await OpdService.lastPrescription(app.readDb, ravi.id);
      expect(last, isNotNull);
      final usual = await OpdService.usualPrescription(app.readDb, me.id, 'Viral fever');
      expect(usual.single['drug_name'], 'Dolo 650');
    });
  });

  test('demo data: signed notes with charges, a queue for Dr. Khan, and both agents fire', () async {
    final app = await bootTestHospital([PatientsModule(), OpdModule()], demo: true);
    final signed = await app.readDb.count(const Query(OpdCol.consultations).eq('status', ConsultStatus.signed));
    expect(signed, greaterThanOrEqualTo(20));
    expect(await app.readDb.count(const Query(Col.charges).eq('source_collection', OpdCol.consultations)), signed);
    final closed = await app.readDb.query(const Query(Col.encounters).eq('type', 'opd').eq('status', 'closed').take(500));
    final noted = (await app.readDb.query(const Query(OpdCol.consultations).take(1000))).map((c) => c.str('encounter_id')).toSet();
    expect(closed.where((e) => !noted.contains(e.id)), isEmpty, reason: 'every finished visit has a note');
    expect(await app.readDb.count(const Query(Col.prescriptions)), greaterThan(10));
    expect(await app.readDb.count(const Query(Col.serviceOrders)), greaterThan(0));

    final khan = (await app.readDb.first(const Query(Col.users).eq('username', 'drkhan')))!;
    expect(await OpdService.nextWaiting(app.readDb, khan.id), isNotNull);

    final ctx = AgentContext(db: app.readDb, settings: app.settings);
    expect((await UnsignedNotesAgent().run(ctx)).findings, isNotEmpty);
    final crit = (await CriticalVitalsAgent().run(ctx)).findings;
    expect(crit, hasLength(1));
    expect(crit.single.summary, contains('SpO2 88%'));
    expect(await app.readDb.count(const Query(OpdCol.amendments)), 1);
    await app.close();
  });
}

// The whole hospital working together, with every installed module:
// register → book and check in → vitals → consult → lab → pharmacy → bill →
// approvals → agents. Each step is done by the person whose job it is, through
// the same services the screens call, so permissions are checked too.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';
import 'package:kendra_hms/modules/appointments/appointment_service.dart';
import 'package:kendra_hms/modules/billing/billing_schema.dart';
import 'package:kendra_hms/modules/billing/billing_service.dart';
import 'package:kendra_hms/modules/lab/lab_service.dart';
import 'package:kendra_hms/modules/opd/opd_schema.dart';
import 'package:kendra_hms/modules/opd/opd_service.dart';
import 'package:kendra_hms/modules/patients/patient_service.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_schema.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_service.dart';

import '../helpers.dart';

const _billMatching = 'billing.bill_matching';

/// A new hospital with every module and one person per job.
Future<AppServices> _hospital() async {
  final app = await bootTestHospital(installedModules());
  // Agents are run by hand below, so their timers don't race the test.
  app.agents!.dispose();
  await addUser(app, 'reception', [Roles.receptionist]);
  await addUser(app, 'nurse', [Roles.nurse]);
  await addUser(app, 'doctor', [Roles.doctor], extra: {
    'display_name': 'Dr. Meera Joshi',
    'is_clinician': true,
    'department': 'General Medicine',
    'consultation_fee_paise': 60000,
  });
  await addUser(app, 'labtech', [Roles.labTech]);
  await addUser(app, 'patho', [Roles.pathologist]);
  await addUser(app, 'pharma', [Roles.pharmacist]);
  await addUser(app, 'cashier', [Roles.billing], extra: {'discount_limit_paise': 20000});
  await addUser(app, 'board1', [Roles.board]);
  return app;
}

Future<Rec> _user(AppServices app, String username) async =>
    (await app.readDb.first(Query(Col.users).eq('username', username)))!;

Future<Rec> _get(AppServices app, String collection, String id) async => (await app.readDb.get(collection, id))!;

Future<List<Rec>> _openFindings(AppServices app, String patientId) => app.readDb.query(
    Query(Col.findings).eq('patient_id', patientId).eq('status', 'open').take(50));

/// Stock for [product]: the pharmacist receives 100 units from a supplier.
Future<void> _stock(AppServices app, Rec product) async {
  final supplier = await app.db.insert(PCol.suppliers, {'name': 'MedLine Distributors', 'active': true});
  await PharmacyService.receive(app.db,
      supplierId: supplier.id,
      byName: 'Pharmacist',
      lines: [
        ReceiptLine(
          productId: product.id,
          name: product.str('name'),
          batchNo: 'E2E-01',
          expiry: DateTime.now().add(const Duration(days: 400)),
          qty: 100,
          costPaise: 150,
          mrpPaise: product.integer('mrp_paise', 300),
        ),
      ]);
}

/// The doctor signs a note with one medicine and one lab test.
Future<FinishResult> _consult(AppServices app, Rec encounter, Rec product, {DateTime? at}) async {
  await signIn(app, 'doctor');
  final doctor = await _user(app, 'doctor');
  final note = await OpdService.start(app.db, encounter, doctor: doctor, now: at);
  await OpdService.saveDraft(app.db, note.id, {
    'chief_complaint': 'Fever for 3 days',
    'diagnosis': 'Viral fever',
    'rx_draft': [
      {
        'medicine_id': product.strOrNull('medicine_id'),
        'drug_name': product.str('name'),
        'generic_name': product.strOrNull('generic_name'),
        'dose': '1 tablet',
        'frequency': '1-0-1',
        'duration_days': 5,
        'route': 'Oral',
        'instructions': 'After food',
        'quantity': 10,
      },
    ],
    'orders_draft': [
      {'name': 'Blood sugar, random (RBS)', 'service_code': 'LAB-RBS', 'order_type': Vals.lab, 'priority': 'routine'},
    ],
  });
  return OpdService.finish(app.db, note.id, signer: doctor, now: at);
}

/// Lab: the technician collects and enters, the pathologist verifies.
Future<Rec> _lab(AppServices app, String encounterId, {DateTime? at}) async {
  final order = (await app.readDb.first(Query(Col.serviceOrders).eq('encounter_id', encounterId)))!;
  await signIn(app, 'labtech');
  final samples = await LabService.collect(app.db, [order], at: at);
  expect(samples, hasLength(1));
  final tests = await LabService.testsByCode(app.readDb);
  await LabService.saveResults(app.db,
      order: await _get(app, Col.serviceOrders, order.id), test: tests['LAB-RBS'], raw: {'glu_r': '112'}, at: at);
  await expectLater(LabService.verify(app.db, order: order), throwsA(isA<PermissionDeniedException>()));
  await signIn(app, 'patho');
  await LabService.verify(app.db, order: order, at: at);
  return _get(app, Col.serviceOrders, order.id);
}

void main() {
  test('one patient through the whole hospital, then the agents check it', () async {
    final app = await _hospital();
    addTearDown(app.close);
    final products = await app.readDb.query(const Query(PCol.products).isNotNull('medicine_id').sort('name').take(1));
    final product = products.single;
    await signIn(app, 'pharma');
    await _stock(app, product);

    // 1. Front desk registers the patient and checks them in for a booking.
    await signIn(app, 'reception');
    final patient = await PatientService.register(app.db, app.settings, {
      'first_name': 'Sunita',
      'last_name': 'Rao',
      'gender': 'female',
      'age_years': 42,
      'phone': '9876500001',
    });
    expect(patient.str('uhid'), startsWith('TH-'));
    final doctor = await _user(app, 'doctor');
    final appt = await AppointmentService.book(app.db, patientId: patient.id, doctorId: doctor.id, start: DateTime.now());
    final checkIn = await AppointmentService.checkIn(app.db, appt);
    final encounter = checkIn.encounter;
    expect(encounter.integer('token_no'), 1);
    expect(encounter.str('queue_status'), Vals.waiting);
    // Reception cannot sign clinical notes.
    await expectLater(
        app.db.insert(OpdCol.consultations, {
          'encounter_id': encounter.id,
          'patient_id': patient.id,
          'doctor_id': doctor.id,
          'status': ConsultStatus.signed,
        }),
        throwsA(isA<PermissionDeniedException>()));

    // 2. The nurse records vitals; 3. the doctor sees the patient.
    await signIn(app, 'nurse');
    await OpdService.recordVitals(app.db, encounter, {'pulse': 92, 'spo2': 97, 'temp_c': 38.4}, byName: 'Nurse');
    final finished = await _consult(app, encounter, product);
    expect(finished.chargePaise, 60000);
    expect(finished.medicineCount, 1);
    expect(finished.orderCount, 1);
    expect((await _get(app, Col.encounters, encounter.id)).str('status'), Vals.closed);
    // The appointment follows the visit (done in the background by Appointments).
    await AppointmentService.syncWithEncounters(app.systemDb);
    expect((await _get(app, appt.collection, appt.id)).str('status'), ApptStatus.completed);

    // 4. Lab.
    final order = await _lab(app, encounter.id);
    expect(order.str('status'), Vals.verified);
    expect(order.strOrNull('charge_id'), isNotNull);

    // 5. Pharmacy dispenses the prescription, first-expiry-first-out.
    await signIn(app, 'pharma');
    final rx = await _get(app, Col.prescriptions, finished.prescriptionId!);
    final fefo = PharmacyService.pickFefo(await PharmacyService.stockBatches(app.readDb, product.id), 10);
    expect(fefo.shortBy, 0);
    await PharmacyService.dispense(app.db,
        patientId: patient.id,
        prescription: rx,
        byName: 'Pharmacist',
        lines: [DispenseLine(product: product, picks: fefo.picks, rxIndex: 0)]);
    expect((await _get(app, Col.prescriptions, rx.id)).str('status'), Vals.dispensed);

    // 6. Billing: the bill builds itself from what each department posted.
    await signIn(app, 'cashier');
    final ready = (await BillingService.readyToBill(app.readDb)).where((r) => r.patient.id == patient.id).single;
    expect(ready.categories, containsAll(['Consultation', 'Lab', 'Pharmacy']));
    final medicines = 10 * product.integer('mrp_paise', 300);
    final rbsPrice = (await app.readDb.first(const Query(Col.services).eq('code', 'LAB-RBS')))!.integer('price_paise');
    expect(ready.total, 60000 + rbsPrice + medicines);
    var bill = await BillingService.createDraft(app.db, patient.id);
    expect(bill.integer('gross_paise'), ready.total);

    // A discount above the cashier's ₹200 limit waits for the board…
    final asked = await BillingService.requestDiscount(app, bill.id, 30000, 'Hospital staff family');
    expect(asked.applied, isFalse);
    await expectLater(app.approvals.approve(asked.approval), throwsA(isA<PermissionDeniedException>()));
    await expectLater(BillingService.finalise(app.db, bill.id), throwsA(isA<ValidationException>()));
    // …and one board member approves it (below the two-person limit).
    await signIn(app, 'board1');
    final decided = await app.approvals.approve(await _get(app, Col.approvals, asked.approval.id));
    expect(decided.str('status'), 'applied');

    await signIn(app, 'cashier');
    bill = await BillingService.finalise(app.db, bill.id);
    expect(bill.str('number'), isNot(startsWith('DRAFT')));
    expect(bill.integer('net_paise'), ready.total - 30000);
    await BillingService.takePayment(app.db, bill.id, [PaymentEntry('cash', bill.integer('balance_paise'))]);
    bill = await _get(app, BillCol.invoices, bill.id);
    expect(bill.integer('balance_paise'), 0);
    final charges = await app.readDb.query(Query(Col.charges).eq('patient_id', patient.id).take(20));
    expect(charges.map((c) => c.str('status')).toSet(), {Vals.billed});
    // A final bill is never edited.
    final service = (await app.readDb.first(const Query(Col.services).eq('code', 'LAB-RBS')))!;
    await expectLater(BillingService.addManualLine(app.db, bill.id, service: service), throwsA(isA<ValidationException>()));

    // 7. Every agent runs over the finished journey: none fails and none
    // raises a false alarm about this patient.
    await app.agents!.runAll();
    for (final e in app.agents!.status.value.entries) {
      expect(e.value.lastError, isNull, reason: '${e.key} failed');
    }
    expect(await _openFindings(app, patient.id), isEmpty);

    // 8. Every step above is in the audit log, and the chain is intact.
    final audit = await app.store.verifyAudit();
    expect(audit.ok, isTrue, reason: audit.message);
  });

  test('work done but never billed is flagged, and clears itself once billed', () async {
    final app = await _hospital();
    addTearDown(app.close);
    final product = (await app.readDb.query(const Query(PCol.products).isNotNull('medicine_id').sort('name').take(1))).single;
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));

    await signIn(app, 'reception');
    final patient = await PatientService.register(app.db, app.settings, {'first_name': 'Ravi', 'last_name': 'Kumar', 'gender': 'male', 'age_years': 35});
    final doctor = await _user(app, 'doctor');
    final visit = await AppointmentService.walkIn(app.db, patientId: patient.id, doctorId: doctor.id, now: twoDaysAgo);
    await _consult(app, visit.encounter, product, at: twoDaysAgo);
    await _lab(app, visit.encounter.id, at: twoDaysAgo);

    // Nobody billed it: the bill-matching agent flags each charge.
    await app.agents!.runById(_billMatching);
    final leaks = await _openFindings(app, patient.id);
    expect(leaks.map((f) => f.str('category')).toSet(), {'leakage'});
    expect(leaks, hasLength(2)); // consultation + lab test
    expect(leaks.every((f) => f.str('agent_id') == _billMatching), isTrue);
    // Agents only read: they never touch the charges.
    expect((await app.readDb.query(Query(Col.charges).eq('patient_id', patient.id).take(10))).every((c) => c.str('status') == Vals.pending),
        isTrue);

    // The board sees them; the cashier bills the patient.
    await signIn(app, 'board1');
    expect(app.auth.can(CorePerms.towerDecide), isTrue);
    await signIn(app, 'cashier');
    final draft = await BillingService.createDraft(app.db, patient.id);
    await BillingService.finalise(app.db, draft.id);

    await app.agents!.runById(_billMatching);
    expect(await _openFindings(app, patient.id), isEmpty);
    final after = await app.readDb.query(Query(Col.findings).eq('patient_id', patient.id).take(10));
    expect(after.map((f) => f.str('status')).toSet(), {'cleared'});
  });

  test('the demo hospital runs with every module: agents work and every role can sign in', () async {
    final app = await bootTestHospital(installedModules(), demo: true);
    addTearDown(app.close);
    app.agents!.dispose();
    expect(app.registry.active.map((m) => m.id),
        ['patients', 'appointments', 'opd', 'lab', 'pharmacy', 'ipd', 'billing', 'tower', 'dashboard', 'admin']);

    await app.agents!.runAll();
    final failed = {
      for (final e in app.agents!.status.value.entries)
        if (e.value.lastError != null) e.key: e.value.lastError,
    };
    expect(failed, isEmpty);
    final findings = await app.readDb.query(const Query(Col.findings).eq('status', 'open').take(500));
    // The demo gives several departments' agents something to report.
    expect(findings.map((f) => f.str('module_id')).toSet().length, greaterThanOrEqualTo(4));

    for (final (username, _, _, _) in demoStaff) {
      await signInDemo(app, username);
      final screens = app.registry.routes.where((r) => r.showInNav && (r.permission == null || app.auth.can(r.permission!)));
      expect(screens, isNotEmpty, reason: '$username has no screens');
    }
    expect((await app.store.verifyAudit()).ok, isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/dashboard/dashboard_metrics.dart';
import 'package:kendra_hms/modules/dashboard/dashboard_module.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

/// A small, known day at the hospital.
class _Data {
  late List<Rec> patients;
  late Rec doctor;
  final opdToday = <String>[];
  final inpatients = <String>[];
  final chargesToday = <String>[];
  final labToday = <String>[];
}

Future<_Data> _seed(AppServices app) async {
  final db = app.systemDb;
  final d = _Data();
  d.doctor = await addUser(app, 'drtest', [Roles.doctor], extra: {'is_clinician': true, 'department': 'Medicine'});
  d.patients = [
    for (final (i, name) in ['Asha Rao', 'Vijay Kumar', 'Nisha Patil'].indexed)
      await db.insert(Col.patients, {'uhid': 'TH-26-00000${i + 1}', 'first_name': name.split(' ').first, 'full_name': name}),
  ];
  final now = DateTime.now();
  final today = startOfDay(now);
  final at10 = today.add(const Duration(hours: 10));
  final yesterday = at10.subtract(const Duration(days: 1));
  String p(int i) => d.patients[i % 3].id;

  Future<String> enc(String type, String status, DateTime started, int i) async => (await db.insert(Col.encounters, {
        'patient_id': p(i),
        'type': type,
        'status': status,
        'doctor_id': d.doctor.id,
        'department': 'Medicine',
        'started_at': started,
        'queue_status': type == Vals.opd ? Vals.done : null,
      }))
          .id;

  d.opdToday.add(await enc(Vals.opd, Vals.closed, at10, 0));
  d.opdToday.add(await enc(Vals.opd, Vals.open, at10.add(const Duration(minutes: 20)), 1));
  await enc(Vals.opd, Vals.cancelled, at10, 2); // cancelled: not a visit
  await enc(Vals.opd, Vals.closed, yesterday, 0); // yesterday
  await enc(Vals.emergency, Vals.open, at10, 1); // not OPD
  d.inpatients.add(await enc(Vals.ipd, Vals.open, today.subtract(const Duration(days: 5)), 0));
  d.inpatients.add(await enc(Vals.ipd, Vals.open, at10, 1));
  await enc(Vals.ipd, Vals.closed, today.subtract(const Duration(days: 9)), 2); // discharged

  Future<String> charge(String cat, int paise, DateTime day, {String status = Vals.pending, int i = 0}) async =>
      (await db.insert(Col.charges, {
        'patient_id': p(i),
        'description': '$cat service',
        'category': cat,
        'amount_paise': paise,
        'status': status,
        'service_date': day,
        'source_module': cat == Vals.consultation ? 'opd' : cat,
      }))
          .id;

  d.chargesToday.add(await charge(Vals.consultation, 50000, at10));
  final lab1 = await charge(Vals.lab, 35000, at10, status: Vals.billed, i: 1);
  final lab2 = await charge(Vals.lab, 15000, at10.add(const Duration(hours: 1)), i: 2);
  d.chargesToday.addAll([lab1, lab2]);
  d.labToday.addAll([lab1, lab2]);
  await charge(Vals.pharmacy, 12000, at10, status: Vals.cancelled); // cancelled: left out
  await charge(Vals.bed, 200000, yesterday);
  await charge(Vals.procedure, 500000, at10.subtract(const Duration(days: 10)));
  await charge(Vals.radiology, 999, at10.subtract(const Duration(days: 20))); // outside 14 days

  await db.batch([
    InsertOp(Col.findings, {'agent_id': 'x.a', 'fingerprint': 'x.a:1', 'title': 'A', 'severity': 'high', 'status': 'open'}),
    InsertOp(Col.findings, {'agent_id': 'x.a', 'fingerprint': 'x.a:2', 'title': 'B', 'severity': 'low', 'status': 'open'}),
    InsertOp(Col.findings, {'agent_id': 'x.a', 'fingerprint': 'x.a:3', 'title': 'C', 'severity': 'high', 'status': 'dismissed'}),
  ]);
  return d;
}

void main() {
  test('KPIs are computed from the core tables', () async {
    final app = await bootTestHospital([PatientsModule(), DashboardModule()]);
    await _seed(app);
    final k = await DashboardMetrics.load(app.readDb, findings: true);

    expect(k.patientsToday, 3);
    expect(k.opdToday, 2, reason: 'cancelled, yesterday\'s and emergency visits are left out');
    expect(k.inpatientsNow, 2, reason: 'discharged patients are left out');
    expect(k.revenueTodayPaise, 100000, reason: 'cancelled charges are left out');
    expect(k.chargesToday, 3);

    expect(k.trend, hasLength(14));
    expect(k.trend.last.$1, startOfDay(DateTime.now()));
    expect(k.trend.last.$2, 100000);
    expect(k.trend[12].$2, 200000);
    expect(k.trend[3].$2, 500000);
    expect(k.trend.fold<int>(0, (a, t) => a + t.$2), 800000, reason: 'older than 14 days is left out');

    expect({for (final (c, v) in k.mix) c: v}, {Vals.lab: 50000, Vals.consultation: 50000});
    expect(k.openFindings, {'high': 1, 'low': 1});
    expect(k.openFindingsTotal, 2);

    final noFindings = await DashboardMetrics.load(app.readDb);
    expect(noFindings.openFindings, isEmpty);
    await app.close();
  });

  test('drill-down lists the records behind each number, with a total', () async {
    final app = await bootTestHospital([PatientsModule(), DashboardModule()]);
    final d = await _seed(app);
    final db = app.readDb;

    final today = await DashboardMetrics.drilldown(db, {'metric': Metrics.charges, 'day': dayKey(DateTime.now())});
    expect(today.rows.map((r) => r.id).toSet(), d.chargesToday.toSet());
    expect(today.count, 3);
    expect(today.totalPaise, 100000);
    expect(today.rows.fold<int>(0, (a, r) => a + (r.amountPaise ?? 0)), today.totalPaise);
    expect(today.columns.map((c) => c.label), ['Patient', 'Service', 'Category', 'From', 'When', 'Amount']);
    final consult = today.rows.firstWhere((r) => r.id == d.chargesToday.first);
    expect(consult.cells.first, contains('Asha Rao'));
    expect(consult.cells.last, '₹500.00');
    expect(consult.patientId, d.patients.first.id);

    final revenue = await DashboardMetrics.drilldown(db, {'metric': Metrics.revenueToday});
    expect(revenue.totalPaise, 100000, reason: 'revenue_today is today\'s charges');

    final lab = await DashboardMetrics.drilldown(db, {'metric': Metrics.charges, 'day': dayKey(DateTime.now()), 'category': Vals.lab});
    expect(lab.rows.map((r) => r.id).toSet(), d.labToday.toSet());
    expect(lab.totalPaise, 50000);
    expect(lab.title, 'Lab tests');

    final fortnight = await DashboardMetrics.drilldown(db, {'metric': Metrics.charges, 'days': 14});
    expect(fortnight.count, 5);
    expect(fortnight.totalPaise, 800000);

    final opd = await DashboardMetrics.drilldown(db, {'metric': Metrics.opdToday});
    expect(opd.rows.map((r) => r.id).toSet(), d.opdToday.toSet());
    expect(opd.count, 2);
    expect(opd.totalPaise, isNull);
    expect(opd.rows.first.cells[1], 'Drtest');

    final ipd = await DashboardMetrics.drilldown(db, {'metric': Metrics.inpatients});
    expect(ipd.rows.map((r) => r.id).toSet(), d.inpatients.toSet());
    expect(ipd.rows.first.cells.last, '5 days', reason: 'oldest admission first');
    expect(ipd.rows.last.cells.last, 'Admitted today');

    final reg = await DashboardMetrics.drilldown(db, {'metric': Metrics.patientsToday});
    expect(reg.rows.map((r) => r.id).toSet(), {for (final p in d.patients) p.id});
    expect(reg.count, 3);
    await app.close();
  });

  test('money needs dashboard.view; everyone has a home screen', () async {
    final app = await bootTestHospital([PatientsModule(), DashboardModule()]);
    await addUser(app, 'desk', [Roles.receptionist]);
    await addUser(app, 'acct', [Roles.accountant]);
    final home = app.registry.route('dashboard.home')!;
    expect(home.permission, isNull);
    expect(home.section, NavSection.home);
    expect(Metrics.isFinancial(Metrics.charges), isTrue);
    expect(Metrics.isFinancial(Metrics.opdToday), isFalse);

    await signIn(app, 'desk');
    expect(app.auth.can(DashboardPerms.view), isFalse);
    expect(app.nav.canOpen('dashboard.home'), isTrue);
    await signIn(app, 'acct');
    expect(app.auth.can(DashboardPerms.view), isTrue);
    await app.close();
  });
}

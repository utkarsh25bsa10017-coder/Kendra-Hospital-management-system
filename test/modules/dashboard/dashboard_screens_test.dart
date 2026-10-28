// Renders the home screen and drill-downs to build/screens/dashboard_<size>_*.png.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/dashboard/dashboard_module.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';
import 'package:kendra_hms/modules/tower/tower_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

final _seeded = <AppServices>{};

/// A believable fortnight: OPD visits today, a few inpatients and charges
/// for the last 14 days (other modules would normally write these).
Future<Map<String, Object?>> _activity(AppServices app) async {
  if (!_seeded.add(app)) return const {};
  final db = app.systemDb;
  final rnd = Random(11);
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(30));
  final doctors = await db.query(const Query(Col.users).eq('is_clinician', true).take(10));
  final now = DateTime.now();
  final today = startOfDay(now);
  final ops = <WriteOp>[];
  Rec pt(int i) => patients[i % patients.length];
  Rec dr(int i) => doctors[i % doctors.length];

  for (var i = 0; i < 9; i++) {
    final d = dr(i);
    ops.add(InsertOp(Col.encounters, {
      'patient_id': pt(i).id,
      'type': Vals.opd,
      'status': i < 6 ? Vals.closed : Vals.open,
      'doctor_id': d.id,
      'department': d.str('department'),
      'started_at': today.add(Duration(hours: 9, minutes: 25 * i)),
      'queue_status': i < 6 ? Vals.done : (i == 6 ? Vals.withDoctor : Vals.waiting),
      'token_no': i + 1,
    }));
  }
  for (var i = 0; i < 4; i++) {
    ops.add(InsertOp(Col.encounters, {
      'patient_id': pt(20 + i).id,
      'type': Vals.ipd,
      'status': Vals.open,
      'doctor_id': dr(i + 1).id,
      'department': dr(i + 1).str('department'),
      'started_at': today.subtract(Duration(days: 1 + i * 2, hours: -11)),
    }));
  }

  const services = <(String, String, int, int)>[
    (Vals.consultation, 'Consultation', 50000, 70000),
    (Vals.lab, 'Complete blood count', 35000, 35000),
    (Vals.lab, 'Lipid profile', 85000, 85000),
    (Vals.lab, 'HbA1c', 60000, 60000),
    (Vals.pharmacy, 'Medicines', 8000, 65000),
    (Vals.radiology, 'X-ray chest', 45000, 45000),
    (Vals.radiology, 'Ultrasound abdomen', 120000, 120000),
    (Vals.bed, 'General ward bed-day', 250000, 250000),
    (Vals.nursing, 'Nursing care', 60000, 60000),
  ];
  const source = {
    Vals.consultation: 'opd',
    Vals.lab: 'lab',
    Vals.pharmacy: 'pharmacy',
    Vals.radiology: 'lab',
    Vals.bed: 'ipd',
    Vals.nursing: 'ipd',
    Vals.procedure: 'ipd',
  };
  for (var d = 13; d >= 0; d--) {
    final day = today.subtract(Duration(days: d));
    final n = 6 + rnd.nextInt(6) + (day.weekday == DateTime.sunday ? -3 : 0);
    for (var j = 0; j < n; j++) {
      final (cat, name, lo, hi) = services[rnd.nextInt(services.length)];
      ops.add(InsertOp(Col.charges, {
        'patient_id': pt(j + d).id,
        'description': name,
        'category': cat,
        'amount_paise': lo + (hi > lo ? rnd.nextInt(hi - lo) ~/ 1000 * 1000 : 0),
        'status': d > 2 ? Vals.billed : Vals.pending,
        'service_date': day.add(Duration(hours: 9, minutes: 37 * j)),
        'source_module': source[cat],
      }));
    }
    if (d % 5 == 1) {
      ops.add(InsertOp(Col.charges, {
        'patient_id': pt(d).id,
        'description': 'Knee arthroscopy',
        'category': Vals.procedure,
        'amount_paise': 4200000,
        'status': Vals.billed,
        'service_date': day.add(const Duration(hours: 14)),
        'source_module': 'ipd',
      }));
    }
  }
  // One cancelled today, which the numbers must leave out.
  ops.add(InsertOp(Col.charges, {
    'patient_id': pt(3).id,
    'description': 'MRI brain',
    'category': Vals.radiology,
    'amount_paise': 650000,
    'status': Vals.cancelled,
    'cancel_reason': 'Machine down',
    'service_date': today.add(const Duration(hours: 10)),
    'source_module': 'lab',
  }));
  await db.batch(ops);
  return const {};
}

Map<String, Object?> _today(String metric) => {'metric': metric, 'day': dayKey(DateTime.now())};

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('dashboard $name owner', (t) => captureScreens(t,
        prefix: 'dashboard_$name',
        size: size,
        modules: [PatientsModule(), DashboardModule()],
        username: 'owner',
        specs: [
          ShotSpec('home', 'dashboard.home', args: _activity),
          ShotSpec('drill_services', 'dashboard.drilldown', args: (app) async => _today('charges')),
          ShotSpec('drill_opd', 'dashboard.drilldown', args: (app) async => const {'metric': 'opd_today'}),
          if (name != 'tablet') ShotSpec('drill_inpatients', 'dashboard.drilldown', args: (app) async => const {'metric': 'inpatients'}),
          if (name == 'desktop') ShotSpec('drill_fortnight', 'dashboard.drilldown', args: (app) async => const {'metric': 'charges', 'days': 14}),
        ]));

    testWidgets('dashboard $name reception', (t) => captureScreens(t,
        prefix: 'dashboard_${name}_reception',
        size: size,
        modules: [PatientsModule(), DashboardModule()],
        username: 'reception',
        specs: [
          ShotSpec('home', 'dashboard.home', args: _activity, after: (t, app) async {
            // Front desk sees counts, never money.
            expect(find.text('Services delivered today'), findsNothing);
            expect(find.text('Registered today'), findsOneWidget);
          }),
          if (name == 'phone') ShotSpec('drill_patients', 'dashboard.drilldown', args: (app) async => const {'metric': 'patients_today'}),
          if (name == 'phone') ShotSpec('drill_money_refused', 'dashboard.drilldown', args: (app) async => _today('charges')),
        ]));
  }

  // With the control tower installed its cards appear, and the dashboard
  // doesn't show findings twice.
  testWidgets('dashboard desktop with tower', (t) async {
    final tower = TowerModule();
    await captureScreens(t,
        prefix: 'dashboard_desktop',
        size: desktopSize,
        modules: [PatientsModule(), tower, DashboardModule()],
        username: 'owner',
        specs: [ShotSpec('home_with_tower', 'dashboard.home', args: _activity)]);
    tower.briefingJob?.stop();
  });
}

// Renders the IPD screens to build/screens/ipd_<size>_*.png for review.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/ipd/ipd_module.dart';
import 'package:kendra_hms/modules/ipd/ipd_schema.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

Future<Rec> _bed(AppServices app, String label) async => (await app.store.query(Query(IpdCol.beds).eq('label', label).take(1))).first;

Future<Rec> _admissionIn(AppServices app, String label) async => (await app.store.get(IpdCol.admissions, (await _bed(app, label)).str('admission_id')))!;

/// A patient who is not in hospital now.
Future<String> _freePatient(AppServices app) async {
  final inside = {
    for (final a in await app.store.query(Query(IpdCol.admissions).isIn('status', IpdVals.current).take(100))) a.str('patient_id'),
  };
  final all = await app.store.query(const Query(Col.patients).sort('created_at').take(100));
  return all.firstWhere((p) => !inside.contains(p.id) && p.str('allergies').isNotEmpty, orElse: () => all.firstWhere((p) => !inside.contains(p.id))).id;
}

/// A current admission whose patient has a recorded allergy (for the banner).
Future<Rec> _withAllergy(AppServices app) async {
  final current = await app.store.query(Query(IpdCol.admissions).eq('status', IpdVals.admitted).sort('admitted_at').take(100));
  for (final a in current) {
    final p = await app.store.get(Col.patients, a.str('patient_id'));
    if ((p?.str('allergies') ?? '').isNotEmpty) return a;
  }
  return current.first;
}

final _mainSpecs = [
  const ShotSpec('beds', 'ipd.beds'),
  ShotSpec('admit', 'ipd.admit',
      args: (app) async => {'patientId': await _freePatient(app), 'bedId': (await _bed(app, 'G-04')).id}),
  ShotSpec('admit_empty', 'ipd.admit'),
  ShotSpec('admission_notes', 'ipd.admission', args: (app) async => {'id': (await _withAllergy(app)).id}),
  ShotSpec('admission_charges', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'P-02')).id, 'tab': 'charges'}),
  ShotSpec('admission_transfer', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'P-02')).id, 'tab': 'transfer'}),
  ShotSpec('discharge_signoff', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'G-01')).id, 'tab': 'discharge'}),
  ShotSpec('discharge_pending', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'G-07')).id, 'tab': 'discharge'}),
  const ShotSpec('admissions', 'ipd.admissions'),
  ShotSpec('patient_tab', 'patients.profile',
      args: (app) async => {'id': (await _admissionIn(app, 'ICU-01')).str('patient_id')},
      after: (t, app) async {
        await t.tap(find.widgetWithText(Tab, 'Admissions'));
        await t.pump(const Duration(milliseconds: 400));
      }),
];

final _nurseSpecs = [
  ShotSpec('nurse_notes', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'ICU-01')).id}),
  ShotSpec('nurse_discharge', 'ipd.admission', args: (app) async => {'id': (await _admissionIn(app, 'G-01')).id, 'tab': 'discharge'}),
];

/// Shows IPD's dashboard cards the way a dashboard would (there is no
/// dashboard module in this test).
class _CardsModule extends HmsModule {
  @override
  String get id => 'ipdcards';
  @override
  String get name => 'Cards';
  @override
  String get description => '';
  @override
  IconData get icon => Icons.dashboard_outlined;
  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'ipdcards.home',
          title: 'Cards',
          icon: Icons.dashboard_outlined,
          showInNav: false,
          builder: (c, a) {
            final cards = IpdModule().dashboardCards;
            return PageScaffold(
              title: 'Dashboard cards',
              body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                cards.first.builder(c),
                Gap.v16,
                ResponsiveGrid(minWidth: 300, maxColumns: 2, children: [for (final d in cards.skip(1)) d.builder(c)]),
              ]),
            );
          },
        ),
      ];
}

/// Dialogs open on the root navigator and survive switching screens.
Future<void> _closeDialogs(WidgetTester t) async {
  final d = find.byType(Dialog);
  if (d.evaluate().isEmpty) return;
  Navigator.of(t.element(d.first)).pop();
  await t.pump(const Duration(milliseconds: 400));
}

final _adminSpecs = [
  const ShotSpec('cards', 'ipdcards.home'),
  const ShotSpec('wards', 'ipd.wards'),
  ShotSpec('ward_edit', 'ipd.wards', after: (t, app) async {
    await _closeDialogs(t);
    await t.tap(find.byTooltip('Edit ward').first);
    await t.pump(const Duration(milliseconds: 400));
  }),
  ShotSpec('wards_add_beds', 'ipd.wards', after: (t, app) async {
    await _closeDialogs(t);
    await t.tap(find.text('Add beds').first);
    await t.pump(const Duration(milliseconds: 400));
  }),
];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('ipd $name', (t) async {
      await captureScreens(t,
          prefix: 'ipd_$name', size: size, modules: [PatientsModule(), IpdModule()], specs: _mainSpecs, username: 'board');
    });
    testWidgets('ipd $name nurse', (t) async {
      await captureScreens(t,
          prefix: 'ipd_$name', size: size, modules: [PatientsModule(), IpdModule()], specs: _nurseSpecs, username: 'nurse');
    });
    testWidgets('ipd $name admin', (t) async {
      await captureScreens(t,
          prefix: 'ipd_$name', size: size, modules: [PatientsModule(), IpdModule(), _CardsModule()], specs: _adminSpecs, username: 'admin');
    });
  }
}

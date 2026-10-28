// Renders the lab screens to build/screens/lab_<size>_*.png for review.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/lab/lab_module.dart';
import 'package:kendra_hms/modules/lab/lab_schema.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

Future<Map<String, Object?>> _order(AppServices app, String status, String code, {bool report = false}) async {
  final o = await app.store.query(Query(Col.serviceOrders).eq('status', status).eq('service_code', code).sort('ordered_at').take(1));
  return {'id': o.first.id, if (report) 'report': true};
}

Future<Map<String, Object?>> _resultOrder(AppServices app, Query q, {bool report = false}) async {
  final r = await app.store.query(q.take(1));
  return {'id': r.first.str('order_id'), if (report) 'report': true};
}

/// The patient with the most lab orders (the diabetic follow-up).
Future<Map<String, Object?>> _busiestPatient(AppServices app) async {
  final rows = await app.store.aggregate(AggQuery(Col.serviceOrders, groupBy: 'patient_id'));
  rows.sort((a, b) => b.count.compareTo(a.count));
  return {'id': rows.first.key};
}

Future<Map<String, Object?>> _firstPatient(AppServices app) async =>
    {'patientId': (await app.store.query(const Query(Col.patients).sort('created_at').take(1))).first.id};

void _scroll(WidgetTester tester, double fraction) {
  for (final s in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
    final p = s.position;
    if (p.axis == Axis.vertical && p.maxScrollExtent > 0) p.jumpTo(p.maxScrollExtent * fraction);
  }
}

Future<void> _type(WidgetTester tester, Map<String, String> values) async {
  for (final e in values.entries) {
    await tester.enterText(find.byKey(ValueKey('lab.value.${e.key}')), e.value);
    await tester.pump();
  }
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

final _labSpecs = [
  const ShotSpec('worklist_collect', 'lab.worklist', args: _collectTab),
  const ShotSpec('worklist_progress', 'lab.worklist', args: _progressTab),
  const ShotSpec('worklist_done', 'lab.worklist', args: _doneTab),
  ShotSpec('result_entry', 'lab.order', args: (app) => _order(app, Vals.collected, 'LAB-CBC'), after: (t, app) async {
    await _type(t, {'hb': '16.4', 'pcv': '49.5', 'wbc': '3,100', 'plt': '18,000', 'rbc': '5.42'});
    _scroll(t, 0);
  }),
  ShotSpec('result_entry_lower', 'lab.order', args: (app) => _order(app, Vals.collected, 'LAB-CBC'), after: (t, app) async {
    await _type(t, {'hb': '16.4', 'pcv': '49.5', 'wbc': '3,100', 'plt': '18,000', 'neut': '41', 'lymph': '47'});
    _scroll(t, 0.75);
  }),
  ShotSpec('result_entry_urine', 'lab.order', args: (app) => _order(app, Vals.collected, 'LAB-URINE-R'), after: (t, app) async {
    await _tapText(t, 'Dark yellow');
    await _tapText(t, 'Slightly turbid');
    await _type(t, {'sg': '1.025', 'ph': '6.0', 'pus': '14'});
    _scroll(t, 0.25);
  }),
  ShotSpec('report', 'lab.order',
      args: (app) => _resultOrder(app, const Query(LabCol.results).contains('comments', 'confirmed on smear'), report: true)),
  ShotSpec('patient_lab_tab', 'patients.profile', args: _busiestPatient, after: (t, app) => _tapText(t, 'Lab reports')),
];

final _pathologySpecs = [
  const ShotSpec('worklist_verify', 'lab.worklist', args: _verifyTab),
  ShotSpec('verify', 'lab.order', args: (app) => _order(app, Vals.resulted, 'LAB-CBC')),
  const ShotSpec('tests', 'lab.tests'),
  ShotSpec('test_editor', 'lab.tests', after: (t, app) => _tapText(t, 'Complete blood count (CBC)')),
];

final _doctorSpecs = [
  ShotSpec('new_order', 'lab.new_order', args: _firstPatient, after: (t, app) => _tapText(t, 'Fever panel · 5')),
  ShotSpec('critical_ack', 'lab.order',
      args: (app) => _resultOrder(
          app,
          const Query(LabCol.results)
              .eq('critical', true)
              .eq('status', ResultStatus.verified)
              .isNull('acknowledged_at')
              .sort('verified_at', desc: true))),
];

Future<Map<String, Object?>> _collectTab(AppServices app) async => {'tab': 'collect'};
Future<Map<String, Object?>> _progressTab(AppServices app) async => {'tab': 'progress'};
Future<Map<String, Object?>> _doneTab(AppServices app) async => {'tab': 'done'};
Future<Map<String, Object?>> _verifyTab(AppServices app) async => {'tab': 'verify'};

/// Test-only screen that lays out the lab's dashboard cards (the dashboard
/// module is not part of these tests).
class _CardsPreview extends HmsModule {
  @override
  String get id => 'labpreview';
  @override
  String get name => 'Preview';
  @override
  String get description => '';
  @override
  IconData get icon => Icons.dashboard_outlined;
  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'labpreview.cards',
          title: 'Cards',
          icon: Icons.dashboard_outlined,
          showInNav: false,
          builder: (c, a) => PageScaffold(
            title: 'Dashboard cards',
            body: ResponsiveGrid(
              minWidth: 260,
              maxColumns: 3,
              children: [for (final card in c.app.registry.dashboardCards) card.builder(c)],
            ),
          ),
        ),
      ];
}

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('lab $name · technician', (t) => captureScreens(t,
        prefix: 'lab_$name', size: size, modules: [PatientsModule(), LabModule()], specs: _labSpecs, username: 'lab'));
    testWidgets('lab $name · pathologist', (t) => captureScreens(t,
        prefix: 'lab_$name', size: size, modules: [PatientsModule(), LabModule()], specs: _pathologySpecs, username: 'pathology'));
    testWidgets('lab $name · doctor', (t) => captureScreens(t,
        prefix: 'lab_$name', size: size, modules: [PatientsModule(), LabModule()], specs: _doctorSpecs, username: 'drkhan'));
    testWidgets('lab $name · dashboard cards', (t) => captureScreens(t,
        prefix: 'lab_$name',
        size: size,
        modules: [PatientsModule(), LabModule(), _CardsPreview()],
        specs: const [ShotSpec('cards', 'labpreview.cards')],
        username: 'board'));
  }
}

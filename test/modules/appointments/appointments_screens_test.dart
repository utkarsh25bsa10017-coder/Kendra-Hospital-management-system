// Renders the appointment screens to build/screens/appointments_<size>_*.png.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/appointments/appointments_module.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

typedef _Args = Future<Map<String, Object?>> Function(AppServices app);

/// Test-only screen that shows every module's dashboard cards.
class _CardsModule extends HmsModule {
  @override
  String get id => 'zz_cards';
  @override
  String get name => 'Cards';
  @override
  String get description => '';
  @override
  IconData get icon => Icons.dashboard_outlined;
  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'zz_cards.home',
          title: 'Dashboard cards',
          icon: Icons.dashboard_outlined,
          showInNav: false,
          builder: (c, a) => PageScaffold(
            title: 'Dashboard cards',
            body: ResponsiveGrid(
              minWidth: 280,
              children: [for (final card in c.app.registry.dashboardCards) card.builder(c)],
            ),
          ),
        ),
      ];
}

/// Closes dialogs and full-screen pages left open by the previous shot.
_Args _fresh([_Args? inner]) => (app) async {
      final ctx = app.nav.contentKey.currentContext;
      if (ctx != null) Navigator.of(ctx, rootNavigator: true).popUntil((r) => r.isFirst);
      return inner == null ? const {} : await inner(app);
    };

Future<Map<String, Object?>> _regular(AppServices app) async {
  final done = await app.store
      .query(const Query('appointments').eq('status', 'completed').sort('start_at', desc: true).take(1));
  return {'id': done.first.str('patient_id')};
}

Future<Map<String, Object?>> _bookFor(AppServices app) async => {'patientId': (await _regular(app))['id']};

/// The button labelled [label] (not some other text that happens to match).
Finder _button(String label) => find
    .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton || w is FloatingActionButton))
    .first;

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

List<ShotSpec> _specs(bool desktop) => [
      const ShotSpec('today', 'appointments.today'),
      if (!desktop)
        ShotSpec('today_slots', 'appointments.today', after: (t, app) => _tap(t, find.text('Slots'))),
      ShotSpec('book', 'appointments.book', args: _bookFor),
      const ShotSpec('book_new', 'appointments.book'),
      const ShotSpec('queue', 'appointments.queue'),
      const ShotSpec('board', 'appointments.board'),
      const ShotSpec('schedules', 'appointments.schedules'),
      ShotSpec('patient_tab', 'patients.profile',
          args: _regular, after: (t, app) => _tap(t, find.widgetWithText(Tab, 'Appointments'))),
      // Dialogs and sheets: each one starts by closing the previous.
      ShotSpec('schedule_session', 'appointments.schedules',
          args: _fresh(), after: (t, app) => _tap(t, find.text('Add session').first)),
      ShotSpec('walk_in', 'appointments.today', args: _fresh(), after: (t, app) async {
        await _tap(t, _button('Walk-in'));
        await _tap(t, find.byType(ListTile).first);
      }),
      ShotSpec('reschedule', 'appointments.today', args: _fresh(), after: (t, app) async {
        await _tap(t, find.byTooltip('More actions').first);
        await _tap(t, find.text('Reschedule').last);
      }),
      ShotSpec('check_in', 'appointments.today',
          args: _fresh(), after: (t, app) => _tap(t, _button('Check in'))),
      ShotSpec('cancel', 'appointments.today', args: _fresh(), after: (t, app) async {
        await _tap(t, find.byTooltip('More actions').first);
        await _tap(t, find.text('Cancel').last);
      }),
      ShotSpec('board_full', 'appointments.board',
          args: _fresh(), after: (t, app) => _tap(t, _button('Full screen'))),
    ];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('appointments $name', (t) => captureScreens(t,
        prefix: 'appointments_$name',
        size: size,
        modules: [PatientsModule(), AppointmentsModule()],
        username: 'reception',
        specs: _specs(name == 'desktop')));
  }

  // The dashboard tile, through a test-only screen that lists every card.
  for (final (name, size) in [('desktop', desktopSize), ('phone', phoneSize)]) {
    testWidgets('appointments dashboard card $name', (t) => captureScreens(t,
        prefix: 'appointments_${name}_extra',
        size: size,
        modules: [PatientsModule(), AppointmentsModule(), _CardsModule()],
        username: 'reception',
        specs: const [ShotSpec('dashboard_card', 'zz_cards.home')]));
  }
}

// Renders every Administration screen to build/screens/admin_<size>_*.png.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/admin/admin_module.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

/// Stand-ins so the Modules screen shows dependencies and an "off" switch.
class _SampleModule extends HmsModule {
  _SampleModule(this.id, this.name, this.description, {this.enabledByDefault = true});
  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final bool enabledByDefault;
  @override
  IconData get icon => Icons.science_outlined;
  @override
  List<String> get dependsOn => const ['patients'];
}

Future<Map<String, Object?>> _drKhan(AppServices app) async =>
    {'id': (await app.store.query(const Query(Col.users).eq('username', 'drkhan').take(1))).first.id};

/// Lets real I/O (network interfaces, files) finish, then redraws.
Future<void> _settle(WidgetTester t, AppServices app) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<Map<String, Object?>> _withHub(AppServices app) async {
  try {
    await app.startHub();
  } catch (_) {
    // Port 8787 is busy on this machine: use another one for the picture.
    await app.hub?.stop();
    app.hub = null;
    app.config.hubPort = 18787;
    await app.startHub();
  }
  return const {};
}

Future<void> _checkIntegrity(WidgetTester t, AppServices app) async {
  await t.tap(find.text('Check integrity'));
  await t.pump();
  await _settle(t, app);
}

Future<void> _openAddStaff(WidgetTester t, AppServices app) async {
  await t.tap(find.text('Add staff').first);
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
  await t.enterText(find.widgetWithText(TextFormField, 'Full name'), 'Dr. Meera Joshi');
  await t.pump();
  await t.tap(find.widgetWithText(FilterChip, 'Doctor'));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _createStaff(WidgetTester t, AppServices app) async {
  if (find.text('Create account').evaluate().isEmpty) await _openAddStaff(t, app);
  await t.ensureVisible(find.text('Create account'));
  await t.pump();
  await t.tap(find.text('Create account'));
  await t.pump();
  await _settle(t, app);
}

final specs = [
  const ShotSpec('users', 'admin.users'),
  ShotSpec('user', 'admin.user', args: _drKhan),
  const ShotSpec('roles', 'admin.roles'),
  ShotSpec('role', 'admin.role', args: (_) async => {'id': Roles.receptionist}),
  const ShotSpec('settings', 'admin.settings'),
  const ShotSpec('modules', 'admin.modules'),
  ShotSpec('network', 'admin.network', args: _withHub, after: _settle),
  ShotSpec('backup', 'admin.backup', after: _settle),
  ShotSpec('audit', 'admin.audit', after: _checkIntegrity),
  ShotSpec('about', 'admin.about', after: _settle),
  // Last: on wide screens the form is a dialog that stays open.
  ShotSpec('add_staff', 'admin.users', after: _openAddStaff),
  ShotSpec('staff_created', 'admin.users', after: _createStaff),
];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('admin $name', (t) => captureScreens(t,
        prefix: 'admin_$name',
        size: size,
        modules: [
          PatientsModule(),
          AdminModule(),
          _SampleModule('lab', 'Laboratory', 'Lab orders, samples and reports.'),
          _SampleModule('pharmacy', 'Pharmacy', 'Dispensing and medicine stock.', enabledByDefault: false),
        ],
        specs: specs));
  }
}

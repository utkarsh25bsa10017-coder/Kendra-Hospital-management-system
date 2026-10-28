// Renders the control tower to build/screens/tower_<size>_*.png.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';
import 'package:kendra_hms/modules/tower/briefing.dart';
import 'package:kendra_hms/modules/tower/tower_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';
import 'fake_checks_module.dart';

Future<Map<String, Object?>> _critical(AppServices app) async => {
      'id': (await app.store.query(const Query(Col.findings).eq('status', 'open').eq('severity', 'critical').take(1)))
          .single
          .id,
    };

Future<Map<String, Object?>> _dismissed(AppServices app) async => {
      'id': (await app.store.query(const Query(Col.findings).eq('status', 'dismissed').sort('decided_at').take(1))).single.id,
    };

Future<Map<String, Object?>> _withBriefing(AppServices app) async {
  await Briefings.create(app, app.systemDb);
  return const {};
}

Future<void> _tap(WidgetTester t, String text) async {
  await t.tap(find.text(text).first);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

List<ShotSpec> _specs(String size) => [
      const ShotSpec('home', 'tower.home'),
      const ShotSpec('findings', 'tower.findings'),
      if (size == 'desktop')
        ShotSpec('finding_decided', 'tower.findings', args: _dismissed)
      else
        ShotSpec('finding', 'tower.findings', args: _critical),
      const ShotSpec('approvals', 'tower.approvals'),
      if (size != 'tablet') ShotSpec('approvals_history', 'tower.approvals', after: (t, app) => _tap(t, 'History')),
      const ShotSpec('proposals', 'tower.proposals'),
      if (size == 'desktop') ShotSpec('proposals_history', 'tower.proposals', after: (t, app) => _tap(t, 'History')),
      const ShotSpec('agents', 'tower.agents'),
      ShotSpec('briefing', 'tower.briefing', args: _withBriefing),
      // Last, because the dialog stays open.
      if (size != 'tablet') ShotSpec('dismiss', 'tower.findings', args: _critical, after: (t, app) => _tap(t, 'Dismiss')),
    ];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('tower $name', (t) async {
      final tower = TowerModule();
      await captureScreens(
        t,
        prefix: 'tower_$name',
        size: size,
        modules: [PatientsModule(), tower, FakeChecksModule()],
        username: 'board',
        specs: _specs(name),
      );
      tower.briefingJob?.stop();
    });
  }
}

// Renders key screens to build/screens/*.png so the UI can be reviewed on a
// machine without a display. Run: flutter test test/screens
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';

import 'capture.dart';
import 'shots.dart';

Future<Map<String, Object?>> _firstPatient(AppServices app) async =>
    {'id': (await app.store.query(const Query(Col.patients).sort('created_at').take(1))).first.id};

final specs = [
  const ShotSpec('patients', 'patients.list'),
  ShotSpec('patient_profile', 'patients.profile', args: _firstPatient),
  const ShotSpec('patient_register', 'patients.register'),
];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets(name, (t) => captureScreens(t,
        prefix: 'app_$name', size: size, modules: installedModules(), specs: specs, includeLoginAndTour: true));
  }
}

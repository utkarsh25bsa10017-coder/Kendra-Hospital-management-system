// Renders every screen each demo role can open, to build/screens/role_*.png,
// so the whole app can be reviewed per job. Run: flutter test test/screens/roles_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';

import 'capture.dart';
import 'shots.dart';

/// Nav screens each demo user would see, worked out from their roles.
List<ShotSpec> _screensFor(String username) {
  final modules = installedModules();
  final roles = demoStaff.firstWhere((s) => s.$1 == username).$3;
  final perms = <String>{
    for (final d in [...CorePerms.defs, for (final m in modules) ...m.permissions])
      if (roles.contains(Roles.owner) || d.roles.any(roles.contains)) d.id,
  };
  return [
    for (final m in modules)
      for (final r in m.routes)
        if (r.showInNav && (r.permission == null || perms.contains(r.permission))) ShotSpec(r.id.replaceAll('.', '_'), r.id),
  ];
}

void main() {
  setUpAll(loadFonts);

  for (final (username, _, _, _) in demoStaff) {
    testWidgets('role $username', (t) => captureScreens(t,
        prefix: 'role_$username',
        size: desktopSize,
        modules: installedModules(),
        username: username,
        specs: _screensFor(username)));
  }

  // The busiest roles on a phone, where the layout changes most.
  for (final username in ['reception', 'drkhan', 'board']) {
    testWidgets('phone $username', (t) => captureScreens(t,
        prefix: 'role_phone_$username',
        size: phoneSize,
        modules: installedModules(),
        username: username,
        specs: _screensFor(username).take(4).toList()));
  }
}

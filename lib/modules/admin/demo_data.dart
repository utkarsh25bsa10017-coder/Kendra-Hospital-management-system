import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/setup/setup_service.dart' show demoPassword;

import 'backup_service.dart';

/// A new receptionist who has not signed in yet (so the staff list shows a
/// temporary password), and one backup of the finished demo hospital so the
/// backup list is not empty.
Future<void> seedDemoAdmin(ModuleContext ctx) async {
  final app = ctx.services;
  try {
    await app.auth.backend.createUser(
      null,
      {
        'username': 'ravi.kumar',
        'display_name': 'Ravi Kumar',
        'role_ids': [Roles.receptionist],
        'department': 'Front office',
        'phone': '9822012345',
        'must_change_password': true,
      },
      demoPassword,
    );
  } catch (_) {
    // Already there.
  }
  if (app.local != null) {
    await Backups.backupNow(app, kind: BackupKind.automatic, db: ctx.systemDb);
  }
}

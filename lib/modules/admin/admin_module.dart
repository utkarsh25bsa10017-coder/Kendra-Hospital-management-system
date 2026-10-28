import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/backup_health_agent.dart';
import 'agents/security_agent.dart';
import 'backup_service.dart';
import 'demo_data.dart';
import 'screens/about_screen.dart';
import 'screens/audit_screen.dart';
import 'screens/backup_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/network_screen.dart';
import 'screens/role_editor_screen.dart';
import 'screens/roles_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/staff_detail_screen.dart';
import 'screens/staff_list_screen.dart';

/// Staff accounts, roles, hospital settings, modules, the network hub,
/// backups and the audit log. Always on.
class AdminModule extends HmsModule {
  @override
  String get id => 'admin';
  @override
  String get name => 'Administration';
  @override
  String get description => 'Staff accounts, roles, hospital settings, network, backups and the audit log.';
  @override
  IconData get icon => Icons.admin_panel_settings_outlined;
  @override
  bool get required => true;

  // The admin permissions are core ones (CorePerms.admin*), declared by core.

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'admin.users',
          title: 'Staff accounts',
          icon: Icons.badge_outlined,
          section: NavSection.admin,
          order: 10,
          permission: CorePerms.adminUsers,
          description: 'Add staff, reset passwords, switch accounts off',
          builder: (c, a) => StaffListScreen(openAdd: a['add'] == true),
        ),
        ModuleRoute(
          id: 'admin.user',
          title: 'Staff member',
          icon: Icons.person_outline,
          showInNav: false,
          permission: CorePerms.adminUsers,
          builder: (c, a) => StaffDetailScreen(userId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'admin.roles',
          title: 'Roles & permissions',
          icon: Icons.shield_outlined,
          section: NavSection.admin,
          order: 20,
          permission: CorePerms.adminRoles,
          description: 'What each job may see and do',
          builder: (c, a) => const RolesScreen(),
        ),
        ModuleRoute(
          id: 'admin.role',
          title: 'Role',
          icon: Icons.shield_outlined,
          showInNav: false,
          permission: CorePerms.adminRoles,
          builder: (c, a) => RoleEditorScreen(roleId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'admin.settings',
          title: 'Hospital settings',
          icon: Icons.tune,
          section: NavSection.admin,
          order: 30,
          permission: CorePerms.adminSettings,
          description: 'Name, address, GSTIN, patient IDs, approval limit, auto-lock',
          builder: (c, a) => const HospitalSettingsScreen(),
        ),
        ModuleRoute(
          id: 'admin.modules',
          title: 'Modules',
          icon: Icons.extension_outlined,
          section: NavSection.admin,
          order: 40,
          permission: CorePerms.adminModules,
          description: 'Switch features on or off',
          builder: (c, a) => const ModulesScreen(),
        ),
        ModuleRoute(
          id: 'admin.network',
          title: 'Network & devices',
          icon: Icons.lan_outlined,
          section: NavSection.admin,
          order: 50,
          permission: CorePerms.adminNetwork,
          description: 'Share data with other computers and tablets',
          builder: (c, a) => const NetworkScreen(),
        ),
        ModuleRoute(
          id: 'admin.backup',
          title: 'Backup & restore',
          icon: Icons.backup_outlined,
          section: NavSection.admin,
          order: 60,
          permission: CorePerms.adminBackup,
          description: 'Back up now, backup folder, restore',
          builder: (c, a) => BackupScreen(backUpNow: a['now'] == true),
        ),
        ModuleRoute(
          id: 'admin.audit',
          title: 'Audit log',
          icon: Icons.history,
          section: NavSection.admin,
          order: 70,
          permission: CorePerms.adminAudit,
          description: 'Who changed what, and when',
          builder: (c, a) => AuditScreen(actorId: a['actor'] as String?),
        ),
        ModuleRoute(
          id: 'admin.about',
          title: 'About this device',
          icon: Icons.info_outline,
          section: NavSection.admin,
          order: 80,
          description: 'Version, mode and data folder',
          builder: (c, a) => const AboutScreen(),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'admin.add_staff',
          label: 'Add staff',
          icon: Icons.person_add_alt_1,
          permission: CorePerms.adminUsers,
          keywords: const ['new user', 'staff', 'account', 'doctor', 'employee', 'login'],
          run: (c) => c.app.nav.open('admin.users', {'add': true}),
        ),
        QuickAction(
          id: 'admin.backup_now',
          label: 'Back up now',
          icon: Icons.backup_outlined,
          permission: CorePerms.adminBackup,
          keywords: const ['backup', 'save copy', 'export database'],
          run: (c) => c.app.nav.open('admin.backup', {'now': true}),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'admin.staff',
          order: 900,
          anchorId: 'nav.admin.users',
          routeId: 'admin.users',
          permission: CorePerms.adminUsers,
          title: 'Staff accounts',
          body: 'Give every person their own username, so everything they do is recorded under their name. '
              'Switch an account off when someone leaves.',
        ),
        TourStep(
          id: 'admin.add_staff',
          order: 901,
          anchorId: 'admin.add_staff',
          routeId: 'admin.users',
          permission: CorePerms.adminUsers,
          title: 'Add staff',
          body: 'Choose what they do (their roles). Kendra makes a temporary password, and they choose their own '
              'at first sign-in.',
        ),
        TourStep(
          id: 'admin.modules',
          order: 910,
          anchorId: 'admin.modules_list',
          routeId: 'admin.modules',
          permission: CorePerms.adminModules,
          title: 'Switch features on or off',
          body: 'Start with what you need. Switching a module off hides it but never deletes its data.',
        ),
        TourStep(
          id: 'admin.network',
          order: 920,
          anchorId: 'nav.admin.network',
          routeId: 'admin.network',
          permission: CorePerms.adminNetwork,
          title: 'Connect other devices',
          body: 'Share this computer\'s data with reception PCs and tablets on the hospital Wi-Fi. '
              'The address and network key to type on them are shown here.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [BackupHealthAgent(), SecurityAgent()];

  Timer? _firstCheck;
  Timer? _hourly;

  /// Records a restore that just happened, then checks every hour whether
  /// today's automatic backup is due.
  @override
  Future<void> onStart(ModuleContext ctx) async {
    _firstCheck?.cancel();
    _hourly?.cancel();
    if (!ctx.isDataHost) return;
    final app = ctx.services;
    await Backups.recordRestore(app);
    Future<void> check() async {
      try {
        final b = await Backups.autoBackupIfDue(app);
        if (b != null) debugPrint('admin: automatic backup saved to ${b.path}');
      } catch (e) {
        // The app may have been closed, or the disk is full; the backup
        // agent raises it with the board if this keeps failing.
        debugPrint('admin: automatic backup failed: $e');
      }
    }

    _firstCheck = Timer(const Duration(minutes: 2), check);
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => check());
  }

  @override
  Future<void> onStop(ModuleContext ctx) async {
    _firstCheck?.cancel();
    _hourly?.cancel();
    _firstCheck = _hourly = null;
  }

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoAdmin(ctx);
}

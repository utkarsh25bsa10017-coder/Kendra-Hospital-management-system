import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/data/sqlite_store.dart';
import 'package:kendra_hms/modules/admin/admin_module.dart';
import 'package:kendra_hms/modules/admin/admin_service.dart';
import 'package:kendra_hms/modules/admin/agents/backup_health_agent.dart';
import 'package:kendra_hms/modules/admin/agents/security_agent.dart';
import 'package:kendra_hms/modules/admin/audit_format.dart';
import 'package:kendra_hms/modules/admin/backup_service.dart';
import 'package:kendra_hms/modules/admin/screens/network_screen.dart' show rankAddresses;
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

class _Fake extends HmsModule {
  _Fake(this.id, {this.dependsOn = const [], this.required = false});
  @override
  final String id;
  @override
  final List<String> dependsOn;
  @override
  final bool required;
  @override
  String get name => titleCase(id);
  @override
  String get description => 'Fake $id';
  @override
  IconData get icon => Icons.extension;
}

List<HmsModule> _modules() => [PatientsModule(), AdminModule()];

Future<Rec> _user(AppServices app, String username) async =>
    (await app.readDb.first(Query(Col.users).eq('username', username)))!;

/// Signs in after any pending session reload has finished. (Core's
/// AuthService reloads the session after account changes; a reload that is
/// still running when someone else signs in would bring the old session back.)
Future<void> _as(AppServices app, String username) async {
  await _idle();
  await signIn(app, username);
  await _idle();
}

/// Lets background work triggered by the last write (role sync, session
/// reloads) finish before the test goes on or closes the hospital.
Future<void> _idle() => Future<void>.delayed(const Duration(milliseconds: 20));

AgentContext _ctx(AppServices app, {DateTime? now}) => AgentContext(db: app.readDb, settings: app.settings, now: now);

void main() {
  test('adding staff gives a readable temporary password that must be changed', () async {
    final app = await bootTestHospital(_modules());
    await _as(app, 'owner');

    expect(Staff.suggestUsername('Dr. Priya Sharma', const {}), 'priya.sharma');
    expect(Staff.suggestUsername('Priya  Sharma', const {'priya.sharma'}), 'priya.sharma2');
    expect(Staff.suggestUsername('Om', const {}), 'om2');

    final created = await Staff.add(app, {
      'display_name': ' Priya Sharma ',
      'username': 'Priya.Sharma',
      'role_ids': [Roles.receptionist],
      'discount_limit_paise': 0,
    });
    expect(created.password, matches(RegExp(r'^Kendra-\d{4}-[a-z]{2}$')));
    expect(created.user.str('username'), 'priya.sharma');
    expect(created.user.str('display_name'), 'Priya Sharma');
    expect(created.user.flag('must_change_password'), isTrue);

    await _idle();
    await app.auth.logout();
    final s = await app.auth.login('priya.sharma', created.password);
    expect(s.mustChangePassword, isTrue);
    expect(s.can('patients.edit'), isTrue);
    await app.auth.changePassword(created.password, 'MyOwnPass9');
    expect(app.auth.session!.mustChangePassword, isFalse);
    await app.auth.logout();
    await expectLater(app.auth.login('priya.sharma', created.password), throwsA(isA<AuthException>()));

    // An administrator's reset makes a new temporary password.
    await _as(app, 'owner');
    final reset = await Staff.resetPassword(app, await _user(app, 'priya.sharma'));
    expect(reset, isNot(created.password));
    await app.auth.logout();
    expect((await app.auth.login('priya.sharma', reset)).mustChangePassword, isTrue);

    // Only owners hand out owner access.
    await addUser(app, 'admin1', [Roles.admin]);
    await _as(app, 'admin1');
    await expectLater(
      Staff.add(app, {'display_name': 'New Boss', 'username': 'boss', 'role_ids': [Roles.owner]}),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(Staff.resetPassword(app, await _user(app, 'owner')), throwsA(isA<ValidationException>()));
    await _idle();
    await app.close();
  });

  test('nobody can switch off themselves or the last owner', () async {
    final app = await bootTestHospital(_modules());
    await addUser(app, 'owner2', [Roles.owner]);
    await addUser(app, 'admin1', [Roles.admin]);

    await _as(app, 'owner');
    await expectLater(Staff.setActive(app, await _user(app, 'owner'), false), throwsA(isA<ValidationException>()));

    // An administrator cannot switch off an owner at all.
    await _as(app, 'admin1');
    await expectLater(Staff.setActive(app, await _user(app, 'owner'), false), throwsA(isA<ValidationException>()));
    // ...nor take away their own access to staff accounts.
    await expectLater(
      Staff.update(app, await _user(app, 'admin1'), {'role_ids': [Roles.receptionist]}),
      throwsA(isA<ValidationException>()),
    );

    // With two owners, one may switch the other off...
    await _as(app, 'owner2');
    final owner2Session = app.auth.session!;
    await _as(app, 'owner');
    final off = await Staff.setActive(app, await _user(app, 'owner2'), false);
    expect(off.flag('active'), isFalse);
    expect(await Staff.activeOwners(app.readDb), 1);

    // ...but then the remaining one is the last owner.
    final why = await Staff.whyCannotDeactivate(app.readDb, owner2Session, await _user(app, 'owner'));
    expect(why, contains('only active owner'));
    await expectLater(
      Staff.update(app, await _user(app, 'owner'), {'role_ids': [Roles.admin]}),
      throwsA(isA<ValidationException>()),
    );

    // Switching back on works and clears any lock.
    final on = await Staff.setActive(app, off, true);
    expect(on.flag('active'), isTrue);
    expect(await Staff.activeOwners(app.readDb), 2);

    // Unlocking clears the lock after too many wrong passwords.
    await app.auth.logout();
    for (var i = 0; i < 5; i++) {
      await expectLater(app.auth.login('admin1', 'wrong$i'), throwsA(isA<AuthException>()));
    }
    expect(Staff.statusOf(await _user(app, 'admin1')), StaffStatus.locked);
    await _as(app, 'owner');
    await Staff.unlock(app, await _user(app, 'admin1'));
    expect(Staff.statusOf(await _user(app, 'admin1')), StaffStatus.active);
    await _idle();
    await app.close();
  });

  test('editing a built-in role marks it customized; reset restores the default', () async {
    final app = await bootTestHospital(_modules());
    await _as(app, 'owner');
    final role = (await app.readDb.get(Col.roles, Roles.receptionist))!;
    final defaults = RoleAdmin.defaults(app.registry, Roles.receptionist);
    expect(role.list<String>('permissions').toSet(), defaults.toSet());
    expect(defaults, contains('patients.edit'));

    final saved = await RoleAdmin.save(app, role,
        name: 'Front desk', description: 'Registration only', permissions: {...defaults}..remove('patients.edit'));
    expect(saved.flag('customized'), isTrue);
    expect(saved.list<String>('permissions'), isNot(contains('patients.edit')));

    // Keeping the built-in roles in sync does not undo an administrator's edit.
    await app.syncRoles();
    expect((await app.readDb.get(Col.roles, Roles.receptionist))!.list<String>('permissions'),
        isNot(contains('patients.edit')));

    await RoleAdmin.resetToDefault(app, saved);
    final back = (await app.readDb.get(Col.roles, Roles.receptionist))!;
    expect(back.flag('customized'), isFalse);
    expect(back.str('name'), 'Receptionist');
    expect(back.list<String>('permissions').toSet(), defaults.toSet());

    // The owner role cannot be edited; nobody can remove their own access.
    final owner = (await app.readDb.get(Col.roles, Roles.owner))!;
    await expectLater(RoleAdmin.save(app, owner, name: 'Owner', description: '', permissions: {}),
        throwsA(isA<ValidationException>()));
    await addUser(app, 'admin1', [Roles.admin]);
    await _as(app, 'admin1');
    final adminRole = (await app.readDb.get(Col.roles, Roles.admin))!;
    await expectLater(
      RoleAdmin.save(app, adminRole,
          name: 'Admin', description: '', permissions: {...adminRole.list<String>('permissions')}..remove(CorePerms.adminRoles)),
      throwsA(isA<ValidationException>()),
    );

    // Custom roles, and permissions grouped by module.
    final custom = await RoleAdmin.add(app, id: RoleAdmin.slug('Insurance desk'), name: 'Insurance desk', permissions: ['patients.view', '*']);
    expect(custom.id, 'insurance_desk');
    expect(custom.list<String>('permissions'), ['patients.view']);
    await expectLater(RoleAdmin.add(app, id: 'doctor', name: 'Doctor 2'), throwsA(isA<ValidationException>()));
    final groups = RoleAdmin.groups(app.registry);
    expect(groups.map((g) => g.name), ['Patients', 'Administration', 'Core']);
    expect(groups[1].permissions.map((p) => p.id), contains(CorePerms.adminBackup));
    expect(groups.last.permissions.map((p) => p.id), contains(CorePerms.towerView));
    await _idle();
    await app.close();
  });

  test('the network screen shows the hospital LAN address first', () {
    expect(rankAddresses(['161.97.97.207', '172.21.0.1', '192.168.1.5', '10.0.0.2', '169.254.3.1']),
        ['192.168.1.5', '10.0.0.2', '172.21.0.1', '161.97.97.207', '169.254.3.1']);
  });

  test('module switches respect dependencies', () async {
    final all = <HmsModule>[
      _Fake('a'),
      _Fake('b', dependsOn: ['a']),
      _Fake('c', dependsOn: ['b']),
      _Fake('d'),
      _Fake('core', required: true),
    ];
    expect(ModuleSwitches.switchOn(all, {}, 'c'), {'a', 'b', 'c'});
    expect(ModuleSwitches.alsoSwitchedOn(all, {'a'}, 'c').map((m) => m.id), ['b']);
    expect(ModuleSwitches.dependents(all, {'a', 'b', 'c', 'd'}, 'a').map((m) => m.id), ['b', 'c']);
    expect(ModuleSwitches.dependents(all, {'a', 'b', 'd'}, 'a').map((m) => m.id), ['b']);
    expect(ModuleSwitches.switchOff(all, {'a', 'b', 'c', 'd'}, 'a'), {'d'});
    expect(ModuleSwitches.switchOff(all, {'a', 'b', 'c', 'd'}, 'c'), {'a', 'b', 'd'});
    expect(() => ModuleSwitches.switchOff(all, {'a'}, 'core'), throwsA(isA<ValidationException>()));
    final needy = <HmsModule>[_Fake('base'), _Fake('kernel', dependsOn: ['base'], required: true)];
    expect(() => ModuleSwitches.switchOff(needy, {'base'}, 'base'), throwsA(isA<ValidationException>()));

    // Saved through settings, the registry follows straight away.
    final app = await bootTestHospital([PatientsModule(), AdminModule(), _Fake('lab'), _Fake('billing', dependsOn: ['lab'])]);
    await _as(app, 'owner');
    expect(app.registry.isActive('billing'), isTrue);
    await ModuleSwitches.save(app, ModuleSwitches.switchOff(app.registry.all, app.registry.enabledIds, 'lab'));
    expect(app.registry.isActive('lab'), isFalse);
    expect(app.registry.isActive('billing'), isFalse);
    expect(app.registry.isActive('admin'), isTrue);
    expect(app.registry.isActive('patients'), isTrue);
    await ModuleSwitches.save(app, ModuleSwitches.switchOn(app.registry.all, app.registry.enabledIds, 'billing'));
    expect(app.registry.isActive('lab'), isTrue);
    expect(app.registry.isActive('billing'), isTrue);
    await _idle();
    await app.close();
  });

  test('a backup is a real copy; restoring it replaces the database file', () async {
    final modules = _modules();
    final app = await bootTestHospital(modules);
    await _as(app, 'owner');
    await app.db.insert(Col.patients, {'uhid': 'TH-1', 'first_name': 'Before', 'full_name': 'Before'});

    final b = await Backups.backupNow(app);
    expect(File(b.path).existsSync(), isTrue);
    expect(b.size, greaterThan(0));
    expect(b.name, matches(RegExp(r'^kendra-\d{8}-\d{4}\.db$')));
    expect(Backups.looksLikeBackup(b.path), isTrue);
    expect(Backups.list(await Backups.folder(app)).map((f) => f.path), [b.path]);
    final last = await Backups.lastBackup(app.store);
    expect(last!.details['path'], b.path);
    expect(last.details['size'], b.size);
    expect(last.actorName, 'Test Owner');

    await app.db.insert(Col.patients, {'uhid': 'TH-2', 'first_name': 'After', 'full_name': 'After'});
    final dbPath = await app.config.databasePath();
    await _idle();
    await app.close();

    final junk = File('${File(dbPath).parent.path}/not-a-backup.db')..writeAsStringSync('hello');
    expect(() => Backups.replaceDatabaseFile(backupPath: junk.path, dbPath: dbPath), throwsA(isA<ValidationException>()));

    Backups.replaceDatabaseFile(backupPath: b.path, dbPath: dbPath);
    final reopened = SqliteRecordStore.open(dbPath, AppServices.buildSchemas(modules));
    final names = (await reopened.query(const Query(Col.patients))).map((p) => p.str('first_name'));
    expect(names, ['Before']);
    expect((await reopened.verifyAudit()).ok, isTrue);
    await reopened.close();
  });

  test('the full restore keeps a safety copy and records itself after the restart', () async {
    final modules = _modules();
    final app = await bootTestHospital(modules);
    await _as(app, 'owner');
    final b = await Backups.backupNow(app);
    await app.db.insert(Col.patients, {'uhid': 'TH-9', 'first_name': 'Late', 'full_name': 'Late'});
    var restarted = false;
    app.requestRestart = () async {
      restarted = true;
    };

    await Backups.restore(app, b);
    expect(restarted, isTrue);
    final folder = await Backups.defaultFolder(app.config);
    final files = Backups.list(folder);
    expect(files.where((f) => f.kind == BackupKind.beforeRestore), hasLength(1));

    final again = await AppServices.boot(app.config, modules);
    expect(await again.store.count(const Query(Col.patients)), 0);
    final restore = await again.store.auditLog(const AuditFilter(action: Backups.restoreAction));
    expect(restore, hasLength(1));
    expect(restore.single.details['by_name'], 'Test Owner');
    expect(restore.single.details['path'], b.path);
    await again.close();
  });

  test('daily automatic backups run after 1 PM and keep the newest 14', () async {
    final app = await bootTestHospital(_modules());
    final today = DateTime.now();
    final morning = DateTime(today.year, today.month, today.day, 9);
    final afternoon = DateTime(today.year, today.month, today.day, 14);
    expect(Backups.isDue(morning, null), isFalse);
    expect(Backups.isDue(afternoon, null), isTrue);
    expect(Backups.isDue(afternoon, afternoon.subtract(const Duration(hours: 1))), isFalse);
    expect(Backups.isDue(afternoon, afternoon.subtract(const Duration(days: 1))), isTrue);

    expect(await Backups.autoBackupIfDue(app, now: morning), isNull);
    final auto = await Backups.autoBackupIfDue(app, now: afternoon);
    expect(auto, isNotNull);
    expect(auto!.kind, BackupKind.automatic);
    expect((await Backups.lastBackup(app.store))!.actorName, 'System');
    expect(await Backups.autoBackupIfDue(app, now: afternoon.add(const Duration(hours: 2))), isNull);

    // Twenty days of automatic backups and one made by hand.
    final folder = await Backups.folder(app);
    for (var d = 1; d <= 20; d++) {
      final t = afternoon.subtract(Duration(days: d));
      File(auto.path).copySync('$folder/${Backups.fileName(t, BackupKind.automatic)}');
    }
    final manual = '$folder/${Backups.fileName(afternoon.subtract(const Duration(days: 30)), BackupKind.manual)}';
    File(auto.path).copySync(manual);
    final removed = Backups.prune(folder);
    expect(removed, hasLength(7));
    final left = Backups.list(folder);
    expect(left.where((f) => f.kind == BackupKind.automatic), hasLength(14));
    expect(left.first.path, auto.path);
    expect(File(manual).existsSync(), isTrue);
    await _idle();
    await app.close();
  });

  test('the audit log of a fresh hospital is intact and reads like sentences', () async {
    final app = await bootTestHospital(_modules());
    await _as(app, 'owner');
    final v = await app.store.verifyAudit();
    expect(v.ok, isTrue);
    expect(v.checked, greaterThan(0));

    final p = await app.db.insert(Col.patients, {'uhid': 'TH-5', 'first_name': 'Asha', 'full_name': 'Asha', 'city': 'Pune'});
    await app.db.update(Col.patients, p.id, {'city': 'Mumbai'});
    final owner = await _user(app, 'owner');
    await app.db.update(Col.users, owner.id, {'discount_limit_paise': 250000, 'is_clinician': true});
    final log = await app.store.auditLog(const AuditFilter(action: 'update', limit: 2));
    expect(AuditFormat.details(app.schemas, log[1]), ['City: Pune → Mumbai']);
    expect(AuditFormat.details(app.schemas, log[0]), unorderedEquals(['Discount limit: — → ₹2,500.00', 'Sees patients: — → Yes']));
    final created = (await app.store.auditLog(AuditFilter(action: 'insert', recordId: p.id))).single;
    expect(AuditFormat.details(app.schemas, created), ['Full name: Asha', '3 other fields filled in']);
    expect((await app.store.verifyAudit()).ok, isTrue);
    await _idle();
    await app.close();
  });

  test('the security agent flags failed sign-ins, locks, old temporary passwords and many owners', () async {
    final app = await bootTestHospital(_modules());
    for (var i = 0; i < 11; i++) {
      await expectLater(app.auth.login('root', 'guess$i'), throwsA(isA<AuthException>()));
    }
    var report = await SecurityAgent().run(_ctx(app));
    final failed = report.findings.where((f) => f.key == 'failed:root').toList();
    expect(failed, hasLength(1));
    expect(failed.single.severity, Severity.medium);
    expect(failed.single.title, contains('11'));

    // Five wrong passwords lock a real account.
    await addUser(app, 'nurse1', [Roles.nurse]);
    for (var i = 0; i < 5; i++) {
      await expectLater(app.auth.login('nurse1', 'wrong$i'), throwsA(isA<AuthException>()));
    }
    await addUser(app, 'owner2', [Roles.owner]);
    await addUser(app, 'owner3', [Roles.owner]);
    await _as(app, 'owner');
    await Staff.add(app, {'display_name': 'New Person', 'username': 'new.person', 'role_ids': [Roles.billing]});

    report = await SecurityAgent().run(_ctx(app));
    final nurse = await _user(app, 'nurse1');
    expect(report.findings.any((f) => f.key == 'locked:${nurse.id}' && f.severity == Severity.low), isTrue);
    expect(report.findings.any((f) => f.key == 'owners' && f.severity == Severity.low), isTrue);
    expect(report.findings.any((f) => f.key.startsWith('temporary:')), isFalse);

    final later = await SecurityAgent().run(_ctx(app, now: DateTime.now().add(const Duration(days: 8))));
    final fresh = await _user(app, 'new.person');
    expect(later.findings.any((f) => f.key == 'temporary:${fresh.id}'), isTrue);
    // A day later the failed sign-ins are old news and the lock has expired.
    expect(later.findings.any((f) => f.key == 'failed:root' || f.key.startsWith('locked:')), isFalse);
    await _idle();
    await app.close();
  });

  test('the backup agent raises a high finding after two days without a backup', () async {
    final app = await bootTestHospital(_modules());
    await _as(app, 'owner');
    expect((await BackupHealthAgent().run(_ctx(app))).findings, isEmpty, reason: 'a new hospital gets two days');
    final never = await BackupHealthAgent().run(_ctx(app, now: DateTime.now().add(const Duration(days: 3))));
    expect(never.findings.single.title, 'No backup has been made yet');

    await Backups.backupNow(app);
    expect((await BackupHealthAgent().run(_ctx(app))).findings, isEmpty);
    final stale = await BackupHealthAgent().run(_ctx(app, now: DateTime.now().add(const Duration(hours: 50))));
    expect(stale.findings.single.severity, Severity.high);
    expect(stale.findings.single.title, 'No backup for 2 days');
    await _idle();
    await app.close();
  });
}

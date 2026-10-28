import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../agents/agent_runner.dart';
import '../auth/auth_service.dart';
import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../data/db.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../data/record_store.dart';
import '../data/remote/hub_server.dart';
import '../data/remote/remote_store.dart';
import '../data/schema.dart';
import '../data/sqlite_store.dart';
import '../modules/module.dart';
import '../modules/registry.dart';
import '../tour/tour_controller.dart';
import 'app_navigator.dart';
import 'approval_service.dart';
import 'device_config.dart';
import 'notification_service.dart';
import 'settings_service.dart';
import 'tower_service.dart';

/// Everything the app needs, created once at start-up and handed to every
/// screen through [AppScope]. Use `context.app` to reach it.
class AppServices {
  AppServices._({
    required this.config,
    required this.schemas,
    required this.store,
    required this.registry,
    required this.auth,
    required this.settings,
    this.local,
    this.remote,
  }) : themeMode = ValueNotifier(_parseTheme(config.themeMode));

  final DeviceConfig config;
  final SchemaRegistry schemas;
  final RecordStore store;
  final SqliteRecordStore? local;
  final RemoteRecordStore? remote;
  final ModuleRegistry registry;
  final AuthService auth;
  final SettingsService settings;
  final ValueNotifier<ThemeMode> themeMode;

  late final Db db = Db(store, () => auth.actor);
  late final Db systemDb = Db(store, () => Actor.system(config.deviceId));
  late final ReadDb readDb = ReadDb(store);
  late final AppNavigator nav = AppNavigator(registry, auth);
  final TourController tour = TourController();
  late final NotificationService notifications = NotificationService(store);
  late final ApprovalService approvals = ApprovalService(this);
  late final TowerService tower = TowerService(this);
  AgentRunner? agents;
  HubServer? hub;
  final _started = <String>{};

  /// Set by the root widget. Call after restoring a backup, leaving the
  /// demo, or anything else that needs the app to start over.
  Future<void> Function()? requestRestart;

  bool get isDataHost => config.mode != DeviceMode.client;
  bool get isDemo => config.mode == DeviceMode.demo;
  String get appVersion => '1.0.0';

  static ThemeMode _parseTheme(String s) =>
      ThemeMode.values.firstWhere((m) => m.name == s, orElse: () => ThemeMode.system);

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode.value = m;
    config.themeMode = m.name;
    await config.save();
  }

  static SchemaRegistry buildSchemas(List<HmsModule> modules) {
    final r = SchemaRegistry()..registerAll(coreCollections);
    for (final m in modules) {
      for (final c in m.collections) {
        if (c.owner != m.id) {
          throw StateError('Collection "${c.name}" in module "${m.id}" must set owner: "${m.id}"');
        }
        r.register(c);
      }
    }
    return r;
  }

  /// Opens the database (or connects to the hub) for a configured device.
  static Future<AppServices> boot(DeviceConfig config, List<HmsModule> modules) async {
    final schemas = buildSchemas(modules);
    late final AppServices s;
    if (config.mode == DeviceMode.client) {
      final remote = RemoteRecordStore(
        baseUrl: config.hubUrl!,
        networkKey: config.networkKey!,
        schemas: schemas,
        deviceId: config.deviceId,
        deviceName: config.deviceName.isEmpty ? Platform.localHostname : config.deviceName,
      );
      final settings = SettingsService(remote);
      final auth = AuthService(RemoteAuthBackend(remote));
      s = AppServices._(
        config: config,
        schemas: schemas,
        store: remote,
        remote: remote,
        registry: ModuleRegistry(modules, settings),
        auth: auth,
        settings: settings,
      );
      remote.onSessionExpired = () => auth.lock();
    } else {
      final local = SqliteRecordStore.open(await config.databasePath(), schemas, deviceId: config.deviceId);
      final settings = SettingsService(local);
      await settings.load();
      final accountChanges =
          local.changes.where((c) => c.collection == Col.users || c.collection == Col.roles).map((_) {});
      s = AppServices._(
        config: config,
        schemas: schemas,
        store: local,
        local: local,
        registry: ModuleRegistry(modules, settings),
        auth: AuthService(LocalAuthBackend(local, config.deviceId), accountChanges: accountChanges),
        settings: settings,
      );
      await s.syncRoles();
      await s.seedModules();
      s.agents = AgentRunner(s)..start();
      if (config.hubEnabled) await s.startHub();
    }
    s.registry.addListener(s._onModulesChanged);
    await s._startModules();
    return s;
  }

  // ------------------------------------------------------------ roles & modules

  /// Keeps the built-in roles in step with the permissions modules declare.
  /// Roles an administrator has edited only gain newly added permissions.
  Future<void> syncRoles() async {
    final defs = registry.allPermissions;
    final allIds = defs.map((d) => d.id).toList()..sort();
    final ops = <WriteOp>[];
    for (final t in Roles.templates) {
      final defaults = t.id == Roles.owner ? ['*'] : [for (final d in defs) if (d.roles.contains(t.id)) d.id];
      final cur = await store.get(Col.roles, t.id);
      if (cur == null) {
        ops.add(InsertOp(Col.roles, {
          'name': t.name,
          'description': t.description,
          'permissions': defaults,
          'builtin': true,
          'customized': false,
          'known_permissions': allIds,
        }, id: t.id));
      } else if (!cur.flag('customized')) {
        final have = cur.list<String>('permissions')..sort();
        final want = [...defaults]..sort();
        if (have.join(',') != want.join(',') || cur.list<String>('known_permissions').length != allIds.length) {
          ops.add(UpdateOp(Col.roles, t.id, {'permissions': want, 'known_permissions': allIds}));
        }
      } else {
        final known = cur.list<String>('known_permissions').toSet();
        final fresh = allIds.where((p) => !known.contains(p)).toSet();
        if (fresh.isNotEmpty) {
          ops.add(UpdateOp(Col.roles, t.id, {
            'permissions': {...cur.list<String>('permissions'), ...defaults.where(fresh.contains)}.toList(),
            'known_permissions': allIds,
          }));
        }
      }
    }
    await systemDb.batch(ops);
  }

  /// Runs each active module's one-time defaults (price lists etc.).
  Future<void> seedModules() async {
    if (!isDataHost) return;
    final seeded = settings.list('modules.seeded').toSet();
    final fresh = registry.active.where((m) => !seeded.contains(m.id)).toList();
    if (fresh.isEmpty) return;
    for (final m in fresh) {
      await m.seedDefaults(ModuleContext(this, m));
      seeded.add(m.id);
    }
    await settings.set(systemDb, 'modules.seeded', seeded.toList());
  }

  Future<void> _startModules() async {
    for (final m in registry.active) {
      if (_started.add(m.id)) {
        try {
          await m.onStart(ModuleContext(this, m));
        } catch (e) {
          debugPrint('module ${m.id} failed to start: $e');
        }
      }
    }
  }

  void _onModulesChanged() async {
    await syncRolesIfHost();
    await seedModules();
    await _startModules();
  }

  Future<void> syncRolesIfHost() async {
    if (isDataHost) await syncRoles();
  }

  // ------------------------------------------------------------ hub

  Future<void> startHub() async {
    if (local == null) return;
    config.networkKey ??= newNetworkKey();
    hub ??= HubServer(
      store: local!,
      auth: LocalAuthBackend(local!, config.deviceId),
      networkKey: config.networkKey!,
      hospitalName: () => settings.hospitalName,
      port: config.hubPort,
    );
    await hub!.start();
    config.hubEnabled = true;
    await config.save();
  }

  Future<void> stopHub() async {
    await hub?.stop();
    hub = null;
    config.hubEnabled = false;
    await config.save();
  }

  // ------------------------------------------------------------ sign-in helpers

  /// Call after a successful sign-in.
  Future<void> afterLogin() async {
    if (!isDataHost) await settings.load();
  }

  Future<Rec?> prefs() async {
    final s = auth.session;
    return s == null ? null : store.get(Col.userPrefs, s.userId);
  }

  Future<void> savePrefs(Map<String, Object?> values) async {
    final s = auth.session;
    if (s == null) return;
    final cur = await store.get(Col.userPrefs, s.userId);
    if (cur == null) {
      await db.insert(Col.userPrefs, values, id: s.userId);
    } else {
      await db.update(Col.userPrefs, s.userId, values);
    }
  }

  /// Tour steps this user can see, in order.
  List<TourStep> tourSteps() {
    final s = auth.session;
    if (s == null) return const [];
    final steps = [...coreTourSteps, ...registry.tourSteps].where((t) {
      if (t.permission != null && !s.can(t.permission!)) return false;
      if (t.routeId != null && !nav.canOpen(t.routeId!)) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return steps;
  }

  /// Starts the walkthrough on first sign-in, or a short "what's new" tour
  /// when modules added steps the user hasn't seen.
  Future<void> maybeStartTour() async {
    final all = tourSteps();
    final seen = seenTourSteps((await prefs())?.data).toSet();
    final unseen = all.where((t) => !seen.contains(t.id)).toList();
    if (unseen.isEmpty) return;
    final firstTime = seen.isEmpty;
    final steps = firstTime
        ? all
        : [
            TourStep(
              id: 'core.whats_new.${DateTime.now().millisecondsSinceEpoch}',
              title: 'Something new',
              body: 'New features were switched on for your hospital. '
                  'Here ${unseen.length == 1 ? 'is a quick look at it' : 'is a quick look at them'}.',
            ),
            ...unseen,
          ];
    startTour(steps);
  }

  void startTour([List<TourStep>? steps]) {
    tour.start(steps ?? tourSteps(), onFinish: (ids) async {
      final seen = seenTourSteps((await prefs())?.data).toSet()..addAll(ids.where((i) => !i.startsWith('core.whats_new')));
      await savePrefs({'seen_tour_steps': seen.toList()});
    });
  }

  Future<void> close() async {
    for (final m in registry.all) {
      if (_started.remove(m.id)) {
        try {
          await m.onStop(ModuleContext(this, m));
        } catch (e) {
          debugPrint('module ${m.id} failed to stop: $e');
        }
      }
    }
    agents?.dispose();
    auth.stopWatching();
    await hub?.stop();
    await store.close();
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});
  final AppServices services;

  static AppServices of(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<AppScope>();
    assert(s != null, 'No AppScope above this widget');
    return s!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.services != services;
}

extension AppContext on BuildContext {
  AppServices get app => AppScope.of(this);
  Db get db => AppScope.of(this).db;
  Session? get session => AppScope.of(this).auth.session;
  bool can(String permission) => AppScope.of(this).auth.can(permission);
  void toast(String message, {bool error = false}) => AppScope.of(this).nav.toast(message, error: error);
}

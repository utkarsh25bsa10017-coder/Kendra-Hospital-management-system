import 'dart:math';

import 'package:kendra_hms/core/auth/auth_service.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/modules/registry.dart';

/// How a staff account stands right now.
enum StaffStatus {
  active('Active', Tone.success),
  temporaryPassword('Temporary password', Tone.warning),
  locked('Locked', Tone.danger),
  off('Switched off', Tone.neutral);

  const StaffStatus(this.label, this.tone);
  final String label;
  final Tone tone;
}

/// Staff account rules: temporary passwords, and the guards that stop an
/// administrator from locking the hospital (or themselves) out.
abstract final class Staff {
  static final _rnd = Random.secure();

  // No i, l or o, so nobody confuses them with 1 and 0.
  static const _letters = 'abcdefghjkmnpqrstuvwxyz';
  static const _titles = {'dr', 'mr', 'mrs', 'ms', 'miss', 'prof', 'shri', 'smt', 'sri'};

  /// Easy to read out over the phone, e.g. `Kendra-4827-pq`.
  static String temporaryPassword([Random? random]) {
    final r = random ?? _rnd;
    final digits = 1000 + r.nextInt(9000);
    final a = _letters[r.nextInt(_letters.length)];
    final b = _letters[r.nextInt(_letters.length)];
    return 'Kendra-$digits-$a$b';
  }

  /// "Dr. Priya Sharma" → "priya.sharma" (or "priya.sharma2" if taken).
  static String suggestUsername(String fullName, Set<String> taken) {
    final words = fullName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_titles.contains(w))
        .toList();
    if (words.isEmpty) return '';
    var base = words.length == 1 ? words.first : '${words.first}.${words.last}';
    if (base.length > 28) base = base.substring(0, 28);
    if (base.length >= 3 && !taken.contains(base)) return base;
    for (var n = 2;; n++) {
      final c = '$base$n';
      if (c.length >= 3 && !taken.contains(c)) return c;
    }
  }

  static StaffStatus statusOf(Rec u, [DateTime? now]) {
    if (!u.flag('active')) return StaffStatus.off;
    final until = u.date('locked_until');
    if (until != null && until.isAfter(now ?? DateTime.now())) return StaffStatus.locked;
    if (u.flag('must_change_password')) return StaffStatus.temporaryPassword;
    return StaffStatus.active;
  }

  static bool isOwner(Rec u) => u.list<String>('role_ids').contains(Roles.owner);
  static bool sessionIsOwner(Session s) => s.roleIds.contains(Roles.owner);

  static Future<int> activeOwners(ReadDb db) =>
      db.count(const Query(Col.users).contains('role_ids', '"${Roles.owner}"').eq('active', true));

  /// Everything the given roles allow together.
  static Future<Set<String>> permissionsOf(ReadDb db, Iterable<String> roleIds) async {
    final roles = await db.byIds(Col.roles, roleIds);
    return {
      for (final r in roles.values)
        if (!r.archived) ...r.list<String>('permissions'),
    };
  }

  static Session _me(AppServices app) => app.auth.session ?? (throw AuthException('Please sign in again'));

  /// Why [me] may not switch [user]'s account off, or null if they may.
  static Future<String?> whyCannotDeactivate(ReadDb db, Session me, Rec user) async {
    final name = user.str('display_name');
    if (user.id == me.userId) return 'You cannot switch off your own account. Ask another administrator to do it.';
    if (isOwner(user) && !sessionIsOwner(me)) return 'Only an owner can switch off an owner\'s account.';
    if (isOwner(user) && user.flag('active') && await activeOwners(db) <= 1) {
      return '$name is the only active owner. Make someone else an owner first, so the hospital is never locked out.';
    }
    return null;
  }

  /// Why [me] may not give [user] the roles [roleIds], or null if they may.
  static Future<String?> whyCannotSetRoles(ReadDb db, Session me, Rec? user, List<String> roleIds) async {
    if (roleIds.isEmpty) return 'Choose at least one role';
    final old = user?.list<String>('role_ids') ?? const <String>[];
    final adds = roleIds.contains(Roles.owner) && !old.contains(Roles.owner);
    final removes = old.contains(Roles.owner) && !roleIds.contains(Roles.owner);
    if ((adds || removes) && !sessionIsOwner(me)) return 'Only an owner can give or take away owner access.';
    if (removes && user!.flag('active') && await activeOwners(db) <= 1) {
      return '${user.str('display_name')} is the only active owner. Make someone else an owner first.';
    }
    if (user != null && user.id == me.userId) {
      final perms = await permissionsOf(db, roleIds);
      if (!perms.contains('*') && !perms.contains(CorePerms.adminUsers)) {
        return 'You would lose access to staff accounts. Ask another administrator to change your roles.';
      }
    }
    return null;
  }

  static Map<String, Object?> _clean(Map<String, Object?> data) {
    final out = {...data};
    if (out['display_name'] is String) out['display_name'] = (out['display_name'] as String).trim();
    if (out.containsKey('username')) {
      final u = normalizeUsername((out['username'] as String?) ?? '');
      final problem = usernameProblem(u);
      if (problem != null) throw ValidationException(problem);
      out['username'] = u;
    }
    for (final k in ['department', 'specialization', 'registration_no', 'phone', 'email']) {
      if (out[k] is String) out[k] = (out[k] as String).trim();
    }
    return out;
  }

  /// Creates the account with a fresh temporary password and returns both.
  /// The person must choose their own password at first sign-in.
  static Future<({Rec user, String password})> add(AppServices app, Map<String, Object?> data) async {
    final me = _me(app);
    final roles = ((data['role_ids'] as List?) ?? const []).cast<String>();
    final why = await whyCannotSetRoles(app.readDb, me, null, roles);
    if (why != null) throw ValidationException(why);
    final password = temporaryPassword();
    final user = await app.auth.backend.createUser(me, {..._clean(data), 'must_change_password': true}, password);
    return (user: user, password: password);
  }

  static Future<Rec> update(AppServices app, Rec user, Map<String, Object?> data) async {
    final me = _me(app);
    if (data.containsKey('role_ids')) {
      final roles = ((data['role_ids'] as List?) ?? const []).cast<String>();
      final old = user.list<String>('role_ids');
      final same = roles.length == old.length && roles.toSet().containsAll(old);
      if (!same) {
        final why = await whyCannotSetRoles(app.readDb, me, user, roles);
        if (why != null) throw ValidationException(why);
      }
    }
    return app.db.update(Col.users, user.id, _clean(data), expectedVersion: user.version);
  }

  /// Sets a new temporary password and returns it.
  static Future<String> resetPassword(AppServices app, Rec user) async {
    final me = _me(app);
    if (user.id == me.userId) {
      throw ValidationException('To change your own password, use "Change password" in your profile menu.');
    }
    if (isOwner(user) && !sessionIsOwner(me)) throw ValidationException('Only an owner can reset an owner\'s password.');
    final password = temporaryPassword();
    await app.auth.backend.setPassword(me, user.id, password);
    return password;
  }

  static Future<Rec> unlock(AppServices app, Rec user) =>
      app.db.update(Col.users, user.id, {'failed_attempts': 0, 'locked_until': null});

  static Future<Rec> setActive(AppServices app, Rec user, bool active) async {
    final me = _me(app);
    if (!active) {
      final why = await whyCannotDeactivate(app.readDb, me, user);
      if (why != null) throw ValidationException(why);
    } else if (isOwner(user) && !sessionIsOwner(me)) {
      throw ValidationException('Only an owner can switch an owner\'s account back on.');
    }
    return app.db.update(Col.users, user.id, {
      'active': active,
      if (active) 'failed_attempts': 0,
      if (active) 'locked_until': null,
    });
  }
}

/// Permissions of one module (or of core), for the role editor.
class PermissionGroup {
  const PermissionGroup(this.id, this.name, this.permissions);
  final String id;
  final String name;
  final List<PermissionDef> permissions;
}

abstract final class RoleAdmin {
  static const coreGroup = 'core';

  /// Every permission, grouped by the module named before the dot
  /// (`billing.invoice` → Billing). Anything else is "Core".
  static List<PermissionGroup> groups(ModuleRegistry registry) {
    final byGroup = <String, List<PermissionDef>>{};
    final seen = <String>{};
    for (final d in registry.allPermissions) {
      if (!seen.add(d.id)) continue;
      final prefix = d.id.split('.').first;
      final key = registry.module(prefix) == null ? coreGroup : prefix;
      byGroup.putIfAbsent(key, () => []).add(d);
    }
    return [
      for (final m in registry.all)
        if (byGroup.containsKey(m.id)) PermissionGroup(m.id, m.name, byGroup[m.id]!),
      if (byGroup.containsKey(coreGroup)) PermissionGroup(coreGroup, 'Core', byGroup[coreGroup]!),
    ];
  }

  /// Ids in the same form [AppServices.syncRoles] stores them.
  static List<String> knownIds(ModuleRegistry registry) => registry.allPermissions.map((d) => d.id).toList()..sort();

  /// What a built-in role gets out of the box.
  static List<String> defaults(ModuleRegistry registry, String roleId) => roleId == Roles.owner
      ? const ['*']
      : ({for (final d in registry.allPermissions) if (d.roles.contains(roleId)) d.id}.toList()..sort());

  static String slug(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  static String? idProblem(String id) {
    if (!RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(id)) {
      return 'Use 2–32 lower-case letters, numbers or _, starting with a letter';
    }
    return null;
  }

  static Session _me(AppServices app) => app.auth.session ?? (throw AuthException('Please sign in again'));

  /// Stops someone removing their own access to this screen.
  static Future<void> _checkSelf(AppServices app, String roleId, Set<String> newPermissions) async {
    final me = _me(app);
    if (!me.roleIds.contains(roleId)) return;
    final after = {...await Staff.permissionsOf(app.readDb, me.roleIds.where((r) => r != roleId)), ...newPermissions};
    if (!after.contains('*') && !after.contains(CorePerms.adminRoles)) {
      throw ValidationException('You would lose access to roles and permissions yourself. '
          'Keep "Edit roles and permissions" ticked, or ask another administrator.');
    }
  }

  static Future<Rec> save(AppServices app, Rec role,
      {required String name, required String description, required Set<String> permissions}) async {
    if (role.id == Roles.owner) throw ValidationException('The owner role always has every permission.');
    if (name.trim().isEmpty) throw ValidationException('Give the role a name');
    final perms = permissions.where((p) => p != '*').toSet();
    await _checkSelf(app, role.id, perms);
    return app.db.update(
      Col.roles,
      role.id,
      {
        'name': name.trim(),
        'description': description.trim(),
        'permissions': perms.toList()..sort(),
        'customized': true,
        'known_permissions': knownIds(app.registry),
      },
      expectedVersion: role.version,
    );
  }

  /// Puts a built-in role back to what Kendra gives it, and lets it follow
  /// new modules automatically again.
  static Future<void> resetToDefault(AppServices app, Rec role) async {
    final t = Roles.template(role.id);
    if (t == null || !role.flag('builtin')) throw ValidationException('Only built-in roles have a default.');
    final perms = defaults(app.registry, role.id);
    await _checkSelf(app, role.id, perms.toSet());
    await app.db.update(Col.roles, role.id, {
      'name': t.name,
      'description': t.description,
      'permissions': perms,
      'customized': false,
      'known_permissions': knownIds(app.registry),
    });
    await app.syncRolesIfHost();
  }

  static Future<Rec> add(AppServices app,
      {required String id, required String name, String description = '', Iterable<String> permissions = const []}) async {
    final roleId = id.trim().toLowerCase();
    final problem = idProblem(roleId);
    if (problem != null) throw ValidationException(problem);
    if (name.trim().isEmpty) throw ValidationException('Give the role a name');
    if (Roles.template(roleId) != null || await app.readDb.get(Col.roles, roleId) != null) {
      throw ValidationException('There is already a role with the id "$roleId"');
    }
    return app.db.insert(
      Col.roles,
      {
        'name': name.trim(),
        'description': description.trim(),
        'permissions': permissions.where((p) => p != '*').toSet().toList()..sort(),
        'builtin': false,
        'customized': true,
        'known_permissions': knownIds(app.registry),
      },
      id: roleId,
    );
  }
}

/// Switching modules on and off while keeping their dependencies intact.
abstract final class ModuleSwitches {
  static HmsModule? _find(List<HmsModule> all, String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// [id] and everything it needs, directly or indirectly.
  static Set<String> withDependencies(List<HmsModule> all, String id) {
    final out = <String>{};
    void visit(String i) {
      if (!out.add(i)) return;
      for (final d in _find(all, i)?.dependsOn ?? const <String>[]) {
        visit(d);
      }
    }

    visit(id);
    return out;
  }

  /// Switched-on modules that need [id], directly or indirectly.
  static List<HmsModule> dependents(List<HmsModule> all, Set<String> enabled, String id) {
    final out = <String>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final m in all) {
        if (out.contains(m.id) || (!enabled.contains(m.id) && !m.required)) continue;
        if (m.dependsOn.any((d) => d == id || out.contains(d))) {
          out.add(m.id);
          changed = true;
        }
      }
    }
    return [for (final m in all) if (out.contains(m.id)) m];
  }

  /// Modules that must come on with [id] (not counting [id] itself).
  static List<HmsModule> alsoSwitchedOn(List<HmsModule> all, Set<String> enabled, String id) {
    final need = withDependencies(all, id)..remove(id);
    return [for (final m in all) if (need.contains(m.id) && !enabled.contains(m.id) && !m.required) m];
  }

  static Set<String> switchOn(List<HmsModule> all, Set<String> enabled, String id) =>
      {...enabled, ...withDependencies(all, id)};

  static Set<String> switchOff(List<HmsModule> all, Set<String> enabled, String id) {
    final m = _find(all, id);
    if (m == null) return enabled;
    if (m.required) throw ValidationException('${m.name} is always on.');
    final blocked = dependents(all, enabled, id);
    if (blocked.any((d) => d.required)) {
      throw ValidationException('${m.name} is needed by ${blocked.where((d) => d.required).map((d) => d.name).join(', ')}, '
          'which is always on.');
    }
    return {...enabled}
      ..remove(id)
      ..removeAll(blocked.map((d) => d.id));
  }

  /// Saves the list. Required modules are always kept on, and ids of
  /// modules that are not installed right now are kept as they were.
  static Future<void> save(AppServices app, Set<String> enabled) async {
    final installed = {for (final m in app.registry.all) m.id};
    final ids = [
      for (final m in app.registry.all)
        if (m.required || enabled.contains(m.id)) m.id,
      for (final id in app.registry.enabledIds)
        if (!installed.contains(id)) id,
    ];
    await app.settings.set(app.db, SettingKeys.modulesEnabled, ids);
  }
}

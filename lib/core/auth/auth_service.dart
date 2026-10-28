import 'dart:async';

import 'package:flutter/foundation.dart';

import '../contracts/collections.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../data/sqlite_store.dart';
import 'password.dart';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Session {
  Session({required this.user, required this.permissions, required this.deviceId, this.token = ''});

  final Rec user;
  final Set<String> permissions;
  final String deviceId;

  /// Hub session token (empty on standalone devices).
  final String token;

  String get userId => user.id;
  String get username => user.str('username');
  String get displayName => user.str('display_name');
  List<String> get roleIds => user.list<String>('role_ids');
  bool get mustChangePassword => user.flag('must_change_password');
  bool get isClinician => user.flag('is_clinician');
  int get discountLimitPaise => user.integer('discount_limit_paise');

  bool can(String permission) => permissions.contains('*') || permissions.contains(permission);
  bool canAny(Iterable<String> perms) => perms.any(can);

  Actor get actor => Actor(id: userId, name: displayName, permissions: permissions, deviceId: deviceId);
}

/// How sign-in works on this device: against the local database
/// (standalone/hub) or by asking the hub (client devices).
abstract class AuthBackend {
  Future<Session> login(String username, String password);
  Future<void> logout(Session session);
  Future<Session> reload(Session session);
  Future<void> changePassword(Session session, String oldPassword, String newPassword);

  /// Admin reset. The user must choose a new password at next sign-in.
  Future<void> setPassword(Session admin, String userId, String newPassword);

  /// Creates a staff account. [by] is null only during first-run setup.
  Future<Rec> createUser(Session? by, Map<String, Object?> data, String password);
}

String normalizeUsername(String u) => u.trim().toLowerCase();

String? usernameProblem(String u) {
  if (!RegExp(r'^[a-z0-9._-]{3,32}$').hasMatch(normalizeUsername(u))) {
    return 'Use 3–32 letters, numbers, dots, dashes or underscores';
  }
  return null;
}

class LocalAuthBackend implements AuthBackend {
  LocalAuthBackend(this.store, this.deviceId);
  final SqliteRecordStore store;
  final String deviceId;

  static const maxAttempts = 5;
  static const lockDuration = Duration(minutes: 5);

  Actor get _system => Actor.system(deviceId);

  Set<String> permissionsFor(Rec user) {
    final perms = <String>{};
    for (final roleId in user.list<String>('role_ids')) {
      final role = store.getSync(Col.roles, roleId);
      if (role != null && !role.archived) perms.addAll(role.list<String>('permissions'));
    }
    return perms;
  }

  Rec? _findUser(String username) {
    final r = store.querySync(Query(Col.users).eq('username', normalizeUsername(username)).take(1),
        withSensitive: true);
    return r.isEmpty ? null : r.first;
  }

  @override
  Future<Session> login(String username, String password) async {
    final user = _findUser(username);
    if (user == null) {
      await store.appendAudit('login_failed', _system, details: {'username': normalizeUsername(username)});
      throw AuthException('Wrong username or password');
    }
    return loginUser(user, password);
  }

  Future<Session> loginUser(Rec user, String password) async {
    if (!user.flag('active')) throw AuthException('This account has been switched off. Ask your administrator.');
    final lockedUntil = user.date('locked_until');
    final now = DateTime.now();
    if (lockedUntil != null && lockedUntil.isAfter(now)) {
      final mins = lockedUntil.difference(now).inMinutes + 1;
      throw AuthException('Too many wrong attempts. Try again in $mins minute${mins == 1 ? '' : 's'}.');
    }
    final ok = verifyPassword(password, user.str('password_hash'), user.str('password_salt'),
        user.integer('password_iterations', defaultPasswordIterations));
    if (!ok) {
      final attempts = user.integer('failed_attempts') + 1;
      final lock = attempts >= maxAttempts;
      store.applySync([
        UpdateOp(Col.users, user.id, {
          'failed_attempts': lock ? 0 : attempts,
          if (lock) 'locked_until': now.add(lockDuration),
        })
      ], _system);
      await store.appendAudit('login_failed', _system,
          collection: Col.users, recordId: user.id, details: {'attempt': attempts, 'locked': lock});
      throw AuthException(lock
          ? 'Too many wrong attempts. The account is locked for ${lockDuration.inMinutes} minutes.'
          : 'Wrong username or password');
    }
    final updated = store.applySync([
      UpdateOp(Col.users, user.id, {'failed_attempts': 0, 'locked_until': null, 'last_login_at': now})
    ], _system).single;
    final session = Session(user: updated, permissions: permissionsFor(updated), deviceId: deviceId);
    await store.appendAudit('login', session.actor, collection: Col.users, recordId: user.id);
    return session;
  }

  @override
  Future<void> logout(Session session) =>
      store.appendAudit('logout', session.actor, collection: Col.users, recordId: session.userId);

  @override
  Future<Session> reload(Session session) async {
    final user = store.getSync(Col.users, session.userId);
    if (user == null || !user.flag('active')) throw AuthException('Your account is no longer active');
    return Session(user: user, permissions: permissionsFor(user), deviceId: session.deviceId, token: session.token);
  }

  @override
  Future<void> changePassword(Session session, String oldPassword, String newPassword) async {
    final user = store.getSync(Col.users, session.userId, withSensitive: true)!;
    if (!verifyPassword(oldPassword, user.str('password_hash'), user.str('password_salt'),
        user.integer('password_iterations', defaultPasswordIterations))) {
      throw AuthException('Your current password is not correct');
    }
    _writePassword(user.id, newPassword, mustChange: false, actor: session.actor);
  }

  @override
  Future<void> setPassword(Session admin, String userId, String newPassword) async {
    if (!admin.can('admin.users')) throw AuthException('Only administrators can reset passwords');
    _writePassword(userId, newPassword, mustChange: true, actor: admin.actor);
  }

  void _writePassword(String userId, String password, {required bool mustChange, required Actor actor}) {
    final problem = passwordProblem(password);
    if (problem != null) throw AuthException(problem);
    final h = newPasswordHash(password);
    // Written as the system so users can change their own password; the
    // audit log still records who asked through the separate entry below.
    store.applySync([
      UpdateOp(Col.users, userId, {
        'password_hash': h.hash,
        'password_salt': h.salt,
        'password_iterations': h.iterations,
        'must_change_password': mustChange,
        'failed_attempts': 0,
        'locked_until': null,
      })
    ], _system);
    store.appendAudit('password_changed', actor, collection: Col.users, recordId: userId);
  }

  @override
  Future<Rec> createUser(Session? by, Map<String, Object?> data, String password) async {
    if (by != null && !by.can('admin.users')) throw AuthException('Only administrators can add staff');
    final username = normalizeUsername((data['username'] as String?) ?? '');
    final uProblem = usernameProblem(username);
    if (uProblem != null) throw AuthException(uProblem);
    final pProblem = passwordProblem(password);
    if (pProblem != null) throw AuthException(pProblem);
    if (_findUser(username) != null) throw AuthException('The username "$username" is already taken');
    final h = newPasswordHash(password);
    final actor = by?.actor ?? _system;
    return store.applySync([
      InsertOp(Col.users, {
        'active': true,
        'failed_attempts': 0,
        'must_change_password': by != null,
        ...data,
        'username': username,
        'password_hash': h.hash,
        'password_salt': h.salt,
        'password_iterations': h.iterations,
      })
    ], actor).single;
  }
}

/// Who is signed in on this device.
class AuthService extends ChangeNotifier {
  AuthService(this.backend, {Stream<void>? accountChanges}) {
    _sub = accountChanges?.listen((_) => _refresh());
  }

  final AuthBackend backend;
  StreamSubscription<void>? _sub;
  Session? _session;
  String? _lockedUsername;

  Session? get session => _session;
  bool get signedIn => _session != null;

  /// Username of the person whose session was locked for inactivity.
  String? get lockedUsername => _lockedUsername;

  bool can(String permission) => _session?.can(permission) ?? false;

  /// The acting user, for writes. Throws if nobody is signed in.
  Actor get actor {
    final s = _session;
    if (s == null) throw AuthException('Please sign in again');
    return s.actor;
  }

  Future<Session> login(String username, String password) async {
    final s = await backend.login(username, password);
    _session = s;
    _lockedUsername = null;
    notifyListeners();
    return s;
  }

  Future<void> logout() async {
    final s = _session;
    _session = null;
    _lockedUsername = null;
    notifyListeners();
    if (s != null) await backend.logout(s);
  }

  /// Locks the screen (idle timeout); the same person signs back in.
  Future<void> lock() async {
    final s = _session;
    if (s == null) return;
    _lockedUsername = s.username;
    _session = null;
    notifyListeners();
    await backend.logout(s);
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await backend.changePassword(_session!, oldPassword, newPassword);
    await _refresh();
  }

  Future<void> _refresh() async {
    final s = _session;
    if (s == null) return;
    Session? next;
    try {
      next = await backend.reload(s);
    } on AuthException {
      next = null;
    }
    // Someone may have signed out or in while the reload ran; don't bring
    // back an old session.
    if (!identical(_session, s)) return;
    _session = next;
    notifyListeners();
  }

  /// Stops following account changes. Called before the database closes, so a
  /// change still on its way can't reach a closed database.
  void stopWatching() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    stopWatching();
    super.dispose();
  }
}

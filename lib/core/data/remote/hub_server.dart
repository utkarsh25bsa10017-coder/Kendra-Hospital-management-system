import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../auth/auth_service.dart';
import '../query.dart';
import '../record.dart';
import '../sqlite_store.dart';
import 'protocol.dart';

class ConnectedDevice {
  ConnectedDevice(this.deviceName, this.address, this.userName, this.lastSeen);
  final String deviceName;
  final String address;
  final String userName;
  DateTime lastSeen;
}

class _HubSession {
  _HubSession(this.session, this.device) : checkedAt = DateTime.now();
  Session session;
  final ConnectedDevice device;

  /// When the account and its permissions were last re-read.
  DateTime checkedAt;
}

/// Serves the hospital database to other devices on the local network.
///
/// Every request must carry the hospital's network key; everything except
/// `login` also needs a session token. Writes are attributed to the signed-in
/// user on the client device and checked against their permissions here, on
/// the hub, so a modified client cannot bypass them.
class HubServer {
  HubServer({
    required this.store,
    required this.auth,
    required this.networkKey,
    required this.hospitalName,
    this.port = hubDefaultPort,
  });

  final SqliteRecordStore store;
  final LocalAuthBackend auth;
  final String networkKey;
  final String Function() hospitalName;
  final int port;

  HttpServer? _server;
  StreamSubscription<StoreChange>? _changeSub;
  final _sessions = <String, _HubSession>{};
  final _sockets = <WebSocket>{};
  final _failures = <String, List<DateTime>>{};
  final devices = ValueNotifier<List<ConnectedDevice>>(const []);
  static const _sessionIdle = Duration(hours: 12);

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle, onError: (Object e) => debugPrint('hub: $e'));
    _changeSub = store.changes.listen((c) {
      final msg = jsonEncode(encodeChange(c));
      for (final s in _sockets.toList()) {
        s.add(msg);
      }
    });
  }

  Future<void> stop() async {
    await _changeSub?.cancel();
    for (final s in _sockets.toList()) {
      await s.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
  }

  /// Addresses other devices can use to reach this hub.
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in iface.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
    return out;
  }

  bool _keyOk(HttpRequest req) {
    final k = req.headers.value(hubKeyHeader) ?? req.uri.queryParameters['key'] ?? '';
    if (k.length != networkKey.length) return false;
    var diff = 0;
    for (var i = 0; i < k.length; i++) {
      diff |= k.codeUnitAt(i) ^ networkKey.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path == '/ping') {
        return await _json(req.response, 200, {
          'app': 'kendra-hub',
          'protocol': hubProtocolVersion,
          'name': _keyOk(req) ? hospitalName() : null,
        });
      }
      if (!_keyOk(req)) return await _json(req.response, 401, {'ok': false, 'kind': WireError.auth, 'error': 'Wrong network key'});
      if (req.uri.path == '/changes' && WebSocketTransformer.isUpgradeRequest(req)) {
        final hs = _sessionFor(req.uri.queryParameters['token']);
        if (hs == null) return await _json(req.response, 401, {'ok': false, 'kind': WireError.session, 'error': 'Signed out'});
        final socket = await WebSocketTransformer.upgrade(req);
        socket.pingInterval = const Duration(seconds: 20);
        _sockets.add(socket);
        socket.listen((_) {}, onDone: () => _sockets.remove(socket), onError: (_) => _sockets.remove(socket));
        return;
      }
      if (req.uri.path == '/rpc' && req.method == 'POST') {
        final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>;
        final op = body['op'] as String;
        final args = (body['args'] as Map?)?.cast<String, Object?>() ?? const {};
        final token = (req.headers.value(HttpHeaders.authorizationHeader) ?? '').replaceFirst('Bearer ', '');
        try {
          final result = await _dispatch(req, op, args, token);
          return await _json(req.response, 200, {'ok': true, 'result': result});
        } on ValidationException catch (e) {
          return await _json(req.response, 200, {'ok': false, 'kind': WireError.validation, 'error': e.message});
        } on ConflictException catch (e) {
          return await _json(req.response, 200, {'ok': false, 'kind': WireError.conflict, 'error': e.message});
        } on PermissionDeniedException catch (e) {
          return await _json(req.response, 200, {'ok': false, 'kind': WireError.permission, 'error': e.message});
        } on AuthException catch (e) {
          return await _json(req.response, 200, {'ok': false, 'kind': WireError.auth, 'error': e.message});
        } on _SessionExpired {
          return await _json(req.response, 200, {'ok': false, 'kind': WireError.session, 'error': 'Please sign in again'});
        }
      }
      return await _json(req.response, 404, {'ok': false, 'kind': WireError.other, 'error': 'Not found'});
    } catch (e) {
      debugPrint('hub error: $e');
      try {
        await _json(req.response, 500, {'ok': false, 'kind': WireError.other, 'error': e.toString()});
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, int status, Object? body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  _HubSession? _sessionFor(String? token) {
    if (token == null || token.isEmpty) return null;
    final hs = _sessions[token];
    if (hs == null) return null;
    if (DateTime.now().difference(hs.device.lastSeen) > _sessionIdle) {
      _sessions.remove(token);
      _publishDevices();
      return null;
    }
    hs.device.lastSeen = DateTime.now();
    return hs;
  }

  void _publishDevices() => devices.value = _sessions.values.map((s) => s.device).toList();

  void _checkRate(String ip) {
    final now = DateTime.now();
    final list = (_failures[ip] ?? [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 10));
    _failures[ip] = list;
    if (list.length >= 20) throw AuthException('Too many failed sign-ins from this device. Wait 10 minutes.');
  }

  Future<Object?> _dispatch(HttpRequest req, String op, Map<String, Object?> a, String token) async {
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';
    if (op == 'login') {
      _checkRate(ip);
      try {
        final local = await auth.login(a['username'] as String, a['password'] as String);
        final t = randomToken(32);
        final deviceId = (a['deviceId'] as String?) ?? ip;
        final session = Session(user: local.user, permissions: local.permissions, deviceId: deviceId, token: t);
        _sessions[t] = _HubSession(
            session, ConnectedDevice((a['deviceName'] as String?) ?? 'Device', ip, session.displayName, DateTime.now()));
        _publishDevices();
        return {'token': t, 'user': encodeRec(session.user), 'permissions': session.permissions.toList()};
      } on AuthException {
        _failures.putIfAbsent(ip, () => []).add(DateTime.now());
        rethrow;
      }
    }

    final hs = _sessionFor(token);
    if (hs == null) throw _SessionExpired();
    // Re-read the account every minute so a switched-off account or changed
    // permissions take effect on every device without signing out.
    if (DateTime.now().difference(hs.checkedAt) > const Duration(minutes: 1)) {
      try {
        hs.session = await auth.reload(hs.session);
        hs.checkedAt = DateTime.now();
      } on AuthException {
        _sessions.remove(token);
        _publishDevices();
        throw _SessionExpired();
      }
    }
    final s = hs.session;
    final actor = s.actor;

    switch (op) {
      case 'logout':
        _sessions.remove(token);
        _publishDevices();
        await auth.logout(s);
        return null;
      case 'reload':
        hs.session = await auth.reload(s);
        return {'user': encodeRec(hs.session.user), 'permissions': hs.session.permissions.toList()};
      case 'changePassword':
        await auth.changePassword(s, a['old'] as String, a['new'] as String);
        return null;
      case 'setPassword':
        await auth.setPassword(s, a['userId'] as String, a['password'] as String);
        return null;
      case 'createUser':
        final rec = await auth.createUser(s, (wireDecode(a['data']) as Map).cast<String, Object?>(), a['password'] as String);
        return encodeRec(rec);
      case 'get':
        final r = await store.get(a['c'] as String, a['id'] as String);
        return r == null ? null : encodeRec(r);
      case 'query':
        return [for (final r in await store.query(decodeQuery(a['q']))) encodeRec(r)];
      case 'count':
        return store.count(decodeQuery(a['q']));
      case 'aggregate':
        return [for (final r in await store.aggregate(decodeAggQuery(a['q']))) encodeAggRow(r)];
      case 'apply':
        final ops = [for (final o in (a['ops'] as List)) decodeOp(o)];
        for (final o in ops) {
          final schema = store.schemas[o.collection];
          final data = switch (o) { InsertOp() => o.data, UpdateOp() => o.patch, ArchiveOp() => const {} };
          for (final f in schema.sensitiveFields) {
            if (data.containsKey(f.name)) throw PermissionDeniedException('That field can only be changed on the hub');
          }
        }
        return [for (final r in await store.apply(ops, actor)) encodeRec(r)];
      case 'nextSequence':
        return store.nextSequence(a['name'] as String, actor);
      case 'appendAudit':
        await store.appendAudit(a['action'] as String, actor,
            collection: a['c'] as String?,
            recordId: a['id'] as String?,
            details: (wireDecode(a['details']) as Map?)?.cast<String, Object?>() ?? const {});
        return null;
      case 'auditLog':
        if (!s.can('admin.audit')) throw PermissionDeniedException('You cannot view the audit log');
        return [for (final e in await store.auditLog(decodeAuditFilter(a['f']))) e.toJson()];
      case 'verifyAudit':
        final v = await store.verifyAudit();
        return {'ok': v.ok, 'checked': v.checked, 'broken': v.brokenAtSeq, 'message': v.message};
    }
    throw ValidationException('Unknown operation $op');
  }
}

class _SessionExpired implements Exception {}

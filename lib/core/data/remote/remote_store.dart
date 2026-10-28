import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../auth/auth_service.dart';
import '../query.dart';
import '../record.dart';
import '../record_store.dart';
import '../schema.dart';
import 'protocol.dart';

enum HubLink { connecting, online, offline }

class HubUnavailableException implements Exception {
  HubUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks that a hub is reachable and the key is right. Returns the
/// hospital name, or throws with a readable message.
Future<String> probeHub(String baseUrl, String key) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(Uri.parse('$baseUrl/ping'));
    req.headers.set(hubKeyHeader, key);
    final res = await req.close().timeout(const Duration(seconds: 6));
    final body = jsonDecode(await utf8.decodeStream(res)) as Map;
    if (body['app'] != 'kendra-hub') throw HubUnavailableException('That address is not a Kendra hub');
    final name = body['name'] as String?;
    if (name == null) throw HubUnavailableException('The hub rejected the network key');
    return name;
  } on SocketException {
    throw HubUnavailableException('Cannot reach $baseUrl. Check the address and that both devices are on the same network.');
  } on TimeoutException {
    throw HubUnavailableException('The hub at $baseUrl did not answer in time');
  } on FormatException {
    throw HubUnavailableException('That address is not a Kendra hub');
  } finally {
    client.close(force: true);
  }
}

/// [RecordStore] that forwards every call to the hospital hub.
class RemoteRecordStore implements RecordStore {
  RemoteRecordStore({
    required this.baseUrl,
    required this.networkKey,
    required this.schemas,
    required this.deviceId,
    required this.deviceName,
  });

  final String baseUrl;
  final String networkKey;
  @override
  final SchemaRegistry schemas;
  final String deviceId;
  final String deviceName;

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final _changes = StreamController<StoreChange>.broadcast();
  final link = ValueNotifier<HubLink>(HubLink.connecting);
  String? _token;
  WebSocket? _socket;
  Timer? _reconnect;
  int _attempt = 0;
  bool _closed = false;

  /// Called when the hub says the session is no longer valid.
  VoidCallback? onSessionExpired;

  @override
  Stream<StoreChange> get changes => _changes.stream;

  Future<Object?> call(String op, [Map<String, Object?> args = const {}]) async {
    try {
      final req = await _http.postUrl(Uri.parse('$baseUrl/rpc'));
      req.headers.contentType = ContentType.json;
      req.headers.set(hubKeyHeader, networkKey);
      if (_token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      req.write(jsonEncode({'op': op, 'args': args}));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
      link.value = HubLink.online;
      if (body['ok'] == true) return body['result'];
      final msg = (body['error'] as String?) ?? 'The hub could not complete the request';
      switch (body['kind']) {
        case WireError.validation:
          throw ValidationException(msg);
        case WireError.conflict:
          throw ConflictException(msg);
        case WireError.permission:
          throw PermissionDeniedException(msg);
        case WireError.auth:
          throw AuthException(msg);
        case WireError.session:
          _token = null;
          onSessionExpired?.call();
          throw AuthException(msg);
      }
      throw HubUnavailableException(msg);
    } on SocketException {
      link.value = HubLink.offline;
      throw HubUnavailableException('Lost connection to the hospital hub. Retrying in the background.');
    } on TimeoutException {
      link.value = HubLink.offline;
      throw HubUnavailableException('The hospital hub is not responding');
    } on HttpException {
      link.value = HubLink.offline;
      throw HubUnavailableException('Lost connection to the hospital hub');
    }
  }

  // ------------------------------------------------------------ session

  void setToken(String? token) {
    _token = token;
    _socket?.close();
    _socket = null;
    if (token != null) _connectChanges();
  }

  /// Live change feed. Retries quickly at first, then every 2 minutes.
  Future<void> _connectChanges() async {
    _reconnect?.cancel();
    if (_closed || _token == null) return;
    link.value = HubLink.connecting;
    try {
      final wsUrl = baseUrl.replaceFirst('http', 'ws');
      final socket = await WebSocket.connect(
          '$wsUrl/changes?token=$_token&key=${Uri.encodeQueryComponent(networkKey)}');
      _socket = socket;
      _attempt = 0;
      link.value = HubLink.online;
      // Anything may have changed while we were away: tell every view to reload.
      _changes.add(const StoreChange('*', '', ChangeKind.update));
      socket.listen(
        (msg) => _changes.add(decodeChange(jsonDecode(msg as String))),
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _socket = null;
    if (_closed || _token == null) return;
    link.value = HubLink.offline;
    const quick = [2, 5, 15, 30, 60];
    final secs = _attempt < quick.length ? quick[_attempt] : 120;
    _attempt++;
    _reconnect = Timer(Duration(seconds: secs), _connectChanges);
  }

  /// Retry right now (the "Reconnect" button).
  void reconnectNow() {
    _attempt = 0;
    _connectChanges();
  }

  // ------------------------------------------------------------ RecordStore

  @override
  Future<Rec?> get(String collection, String id) async {
    final r = await call('get', {'c': collection, 'id': id});
    return r == null ? null : decodeRec(r);
  }

  @override
  Future<List<Rec>> query(Query q) async =>
      [for (final r in (await call('query', {'q': encodeQuery(q)}) as List)) decodeRec(r)];

  @override
  Future<int> count(Query q) async => (await call('count', {'q': encodeQuery(q)})) as int;

  @override
  Future<List<AggRow>> aggregate(AggQuery q) async =>
      [for (final r in (await call('aggregate', {'q': encodeAggQuery(q)}) as List)) decodeAggRow(r)];

  @override
  Future<List<Rec>> apply(List<WriteOp> ops, Actor actor) async =>
      [for (final r in (await call('apply', {'ops': ops.map(encodeOp).toList()}) as List)) decodeRec(r)];

  @override
  Future<int> nextSequence(String name, Actor actor) async => (await call('nextSequence', {'name': name})) as int;

  @override
  Future<void> appendAudit(String action, Actor actor,
      {String? collection, String? recordId, Map<String, Object?> details = const {}}) async {
    await call('appendAudit', {'action': action, 'c': collection, 'id': recordId, 'details': wireEncode(details)});
  }

  @override
  Future<List<AuditEntry>> auditLog(AuditFilter filter) async => [
        for (final e in (await call('auditLog', {'f': encodeAuditFilter(filter)}) as List))
          AuditEntry.fromJson((e as Map).cast<String, Object?>()),
      ];

  @override
  Future<AuditVerification> verifyAudit() async {
    final m = (await call('verifyAudit') as Map).cast<String, Object?>();
    return AuditVerification(
        ok: m['ok'] as bool, checked: m['checked'] as int, brokenAtSeq: m['broken'] as int?, message: m['message'] as String);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _reconnect?.cancel();
    await _socket?.close();
    _http.close(force: true);
    _changes.close().ignore();
  }
}

/// Sign-in for client devices: the hub checks the password.
class RemoteAuthBackend implements AuthBackend {
  RemoteAuthBackend(this.remote);
  final RemoteRecordStore remote;

  Session _session(Map<String, Object?> m, String token) => Session(
        user: decodeRec(m['user']),
        permissions: ((m['permissions'] as List?) ?? const []).cast<String>().toSet(),
        deviceId: remote.deviceId,
        token: token,
      );

  @override
  Future<Session> login(String username, String password) async {
    final m = (await remote.call('login', {
      'username': username,
      'password': password,
      'deviceId': remote.deviceId,
      'deviceName': remote.deviceName,
    }) as Map)
        .cast<String, Object?>();
    final token = m['token'] as String;
    remote.setToken(token);
    return _session(m, token);
  }

  @override
  Future<void> logout(Session session) async {
    try {
      await remote.call('logout');
    } finally {
      remote.setToken(null);
    }
  }

  @override
  Future<Session> reload(Session session) async =>
      _session((await remote.call('reload') as Map).cast<String, Object?>(), session.token);

  @override
  Future<void> changePassword(Session session, String oldPassword, String newPassword) =>
      remote.call('changePassword', {'old': oldPassword, 'new': newPassword});

  @override
  Future<void> setPassword(Session admin, String userId, String newPassword) =>
      remote.call('setPassword', {'userId': userId, 'password': newPassword});

  @override
  Future<Rec> createUser(Session? by, Map<String, Object?> data, String password) async =>
      decodeRec(await remote.call('createUser', {'data': wireEncode(data), 'password': password}));
}

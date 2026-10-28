import 'dart:math';

/// A single stored record. Values are already decoded to Dart types:
/// dateTime fields are [DateTime] (local time), booleans are [bool],
/// json fields are maps/lists.
class Rec {
  Rec(this.collection, this.data);

  final String collection;
  final Map<String, Object?> data;

  String get id => data['id'] as String;
  int get version => (data['version'] as int?) ?? 1;
  DateTime get createdAt => data['created_at'] as DateTime;
  DateTime get updatedAt => data['updated_at'] as DateTime;
  String? get createdBy => data['created_by'] as String?;
  String? get updatedBy => data['updated_by'] as String?;
  bool get archived => data['archived'] == true;

  Object? operator [](String key) => data[key];

  String str(String key, [String fallback = '']) {
    final v = data[key];
    if (v == null) return fallback;
    return v is String ? v : v.toString();
  }

  String? strOrNull(String key) {
    final v = data[key];
    if (v == null) return null;
    final s = v is String ? v : v.toString();
    return s.isEmpty ? null : s;
  }

  int integer(String key, [int fallback = 0]) => (data[key] as num?)?.toInt() ?? fallback;
  int? intOrNull(String key) => (data[key] as num?)?.toInt();
  double real(String key, [double fallback = 0]) => (data[key] as num?)?.toDouble() ?? fallback;
  double? realOrNull(String key) => (data[key] as num?)?.toDouble();
  bool flag(String key) => data[key] == true;
  DateTime? date(String key) => data[key] as DateTime?;

  List<T> list<T>(String key) {
    final v = data[key];
    if (v is List) return v.whereType<T>().toList();
    return <T>[];
  }

  List<Map<String, Object?>> maps(String key) {
    final v = data[key];
    if (v is List) {
      return v.whereType<Map>().map((m) => m.cast<String, Object?>()).toList();
    }
    return const [];
  }

  Map<String, Object?> map(String key) {
    final v = data[key];
    if (v is Map) return v.cast<String, Object?>();
    return <String, Object?>{};
  }

  Rec copyWith(Map<String, Object?> changes) => Rec(collection, {...data, ...changes});

  @override
  String toString() => 'Rec($collection/$id)';
}

/// Who is performing an operation. Every write is attributed to an actor and
/// recorded in the audit log.
class Actor {
  const Actor({
    required this.id,
    required this.name,
    this.permissions = const {},
    this.deviceId = '',
    this.isSystem = false,
  });

  /// The app itself (setup, migrations, scheduled jobs). Bypasses
  /// collection write permissions but is still audited.
  const Actor.system([this.deviceId = ''])
      : id = 'system',
        name = 'System',
        permissions = const {'*'},
        isSystem = true;

  final String id;
  final String name;
  final Set<String> permissions;
  final String deviceId;
  final bool isSystem;

  bool can(String permission) =>
      isSystem || permissions.contains('*') || permissions.contains(permission);

  bool canAny(Iterable<String> perms) => perms.any(can);

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'permissions': permissions.toList(), 'deviceId': deviceId};
}

final _rand = Random.secure();
const _alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';

/// Short, time-sortable unique id: 9 chars of millisecond timestamp in base 36
/// followed by 10 random chars.
String newId() {
  final ts = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36).padLeft(9, '0');
  final sb = StringBuffer(ts);
  for (var i = 0; i < 10; i++) {
    sb.write(_alphabet[_rand.nextInt(_alphabet.length)]);
  }
  return sb.toString();
}

/// Random hex token (sessions, network keys).
String randomToken([int bytes = 24]) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    sb.write(_rand.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

class ConflictException implements Exception {
  ConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PermissionDeniedException implements Exception {
  PermissionDeniedException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ValidationException implements Exception {
  ValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

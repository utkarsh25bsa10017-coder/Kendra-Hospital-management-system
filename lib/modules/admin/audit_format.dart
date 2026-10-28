import 'dart:convert';

import 'package:kendra_hms/core/core.dart';

/// Turns raw audit entries into sentences an administrator can read.
abstract final class AuditFormat {
  static const actions = <String, String>{
    'insert': 'Created',
    'update': 'Changed',
    'archive': 'Archived',
    'view': 'Viewed',
    'login': 'Signed in',
    'logout': 'Signed out',
    'login_failed': 'Failed sign-in',
    'password_changed': 'Password set',
    'backup': 'Backup',
    'restore': 'Restore',
    'network_key_changed': 'New network key',
  };

  static String action(String a) => actions[a] ?? titleCase(a);

  /// Separates the old and the new value in [details] lines.
  static const arrow = ' → ';

  /// For places that can only show plain text: some fonts have no arrow.
  static String plain(String line) => line.replaceAll(arrow, ' › ');

  static Tone tone(String a) => switch (a) {
        'insert' => Tone.success,
        'update' => Tone.info,
        'archive' || 'login_failed' || 'restore' => Tone.danger,
        'password_changed' || 'network_key_changed' => Tone.warning,
        _ => Tone.neutral,
      };

  static String collection(String? c) => c == null || c.isEmpty ? '' : titleCase(c);

  static const _labels = <String, String>{
    'uhid': 'UHID',
    'dob': 'Date of birth',
    'abha_number': 'ABHA number',
    'role_ids': 'Roles',
    'is_clinician': 'Sees patients',
    'must_change_password': 'Must choose a password',
    'locked_until': 'Locked until',
    'failed_attempts': 'Wrong passwords in a row',
    'last_login_at': 'Last sign-in',
    'password_hash': 'Password',
    'display_name': 'Name',
  };

  static String field(String f) {
    final known = _labels[f];
    if (known != null) return known;
    final s = f.replaceAll(RegExp(r'_(paise|id|ids)$'), '');
    final t = s.replaceAll('_', ' ');
    return t.isEmpty ? f : t[0].toUpperCase() + t.substring(1);
  }

  /// Audit diffs hold values as stored: dates as milliseconds, booleans as
  /// 1/0, lists and maps as JSON text.
  static String value(Field? f, String name, Object? v) {
    if (v == null || (v is String && v.isEmpty)) return '—';
    if (v == '***') return '(hidden)';
    if (name.endsWith('_paise') && v is num) return formatMoney(v.toInt());
    switch (f?.type) {
      case FieldType.boolean:
        return (v == 1 || v == true) ? 'Yes' : 'No';
      case FieldType.dateTime:
        if (v is num) return formatDateTime(DateTime.fromMillisecondsSinceEpoch(v.toInt()));
      case FieldType.json:
        if (v is String) {
          try {
            final d = jsonDecode(v);
            if (d is List) return d.isEmpty ? '—' : _short(d.map((e) => e is String ? e : jsonEncode(e)).join(', '));
            if (d is Map) return _short(d.entries.map((e) => '${e.key}: ${e.value}').join(', '));
            return _short('$d');
          } on FormatException {
            return _short(v);
          }
        }
      default:
        break;
    }
    return _short(v is String ? v : '$v');
  }

  static String _short(String s) => s.length > 60 ? '${s.substring(0, 57)}…' : s;

  static const _nameFields = ['display_name', 'full_name', 'name', 'title', 'uhid', 'username', 'number', 'description'];
  static const _noise = {'known_permissions', 'password_iterations', 'password_salt'};

  /// One line per change, e.g. "Status: open → closed".
  static List<String> details(SchemaRegistry schemas, AuditEntry e, {int max = 6}) {
    final schema = e.collection == null ? null : schemas.lookup(e.collection!);
    final d = e.details;
    final lines = <String>[];
    switch (e.action) {
      case 'update':
        final changes = (d['changes'] as Map?)?.cast<String, Object?>() ?? const {};
        for (final c in changes.entries) {
          if (_noise.contains(c.key)) continue;
          final pair = c.value is List ? c.value as List : [null, c.value];
          final f = schema?.field(c.key);
          if (f?.sensitive ?? false) {
            lines.add('${field(c.key)} changed');
          } else {
            lines.add('${field(c.key)}: ${value(f, c.key, pair.isEmpty ? null : pair.first)}$arrow'
                '${value(f, c.key, pair.length < 2 ? null : pair[1])}');
          }
        }
      case 'insert':
        final data = (d['data'] as Map?)?.cast<String, Object?>() ?? const {};
        for (final k in _nameFields) {
          if (data[k] != null) {
            lines.add('${field(k)}: ${value(schema?.field(k), k, data[k])}');
            break;
          }
        }
        final rest = data.keys.where((k) => !_noise.contains(k)).length - lines.length;
        if (rest > 0) lines.add('${plural(rest, 'other field')} filled in');
      case 'backup':
        lines.add('Saved to ${d['path'] ?? '—'}');
        if (d['size'] is num) lines.add('Size ${_size((d['size'] as num).toInt())}');
      case 'restore':
        lines.add('From ${d['path'] ?? 'a backup'}');
        if (d['by_name'] != null) lines.add('Restored by ${d['by_name']}');
        if (d['safety_copy'] != null) lines.add('Earlier data kept in ${d['safety_copy']}');
      default:
        for (final entry in d.entries) {
          lines.add('${field(entry.key)}: ${value(null, entry.key, entry.value is String || entry.value is num ? entry.value : jsonEncode(entry.value))}');
        }
    }
    if (lines.length > max) {
      final more = lines.length - max + 1;
      return [...lines.take(max - 1), '+ ${plural(more, 'more change')}'];
    }
    return lines;
  }

  static String _size(int bytes) =>
      bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../contracts/collections.dart';
import '../data/db.dart';
import '../data/query.dart';
import '../data/record_store.dart';

/// Hospital-wide settings, cached in memory and kept fresh from the database.
class SettingsService extends ChangeNotifier {
  SettingsService(this.store) {
    _sub = store.changes.where((c) => c.collection == Col.settings || c.collection == '*').listen((_) => load());
  }

  final RecordStore store;
  StreamSubscription<Object?>? _sub;
  Map<String, Object?> _values = {};
  bool _loaded = false;

  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final rows = await store.query(const Query(Col.settings));
      _values = {for (final r in rows) r.id: r['value']};
      _loaded = true;
      notifyListeners();
    } catch (_) {
      // Client devices cannot read settings before signing in.
    }
  }

  Object? raw(String key) => _values[key];

  String str(String key, [String fallback = '']) {
    final v = _values[key];
    return v is String ? v : fallback;
  }

  int integer(String key, int fallback) {
    final v = _values[key];
    return v is num ? v.toInt() : fallback;
  }

  bool flag(String key, [bool fallback = false]) {
    final v = _values[key];
    return v is bool ? v : fallback;
  }

  List<String> list(String key, [List<String> fallback = const []]) {
    final v = _values[key];
    return v is List ? v.whereType<String>().toList() : fallback;
  }

  String get hospitalName => str(SettingKeys.hospitalName, 'Hospital');
  int get highValueLimitPaise => integer(SettingKeys.highValueLimitPaise, 1000000);
  int get idleLockMinutes => integer(SettingKeys.idleLockMinutes, 15);
  int get briefingHour => integer(SettingKeys.briefingHour, 8);

  Future<void> set(Db db, String key, Object? value) async {
    final existing = await store.get(Col.settings, key);
    if (existing == null) {
      await db.insert(Col.settings, {'value': value}, id: key);
    } else {
      await db.update(Col.settings, key, {'value': value});
    }
    _values[key] = value;
    notifyListeners();
  }

  Future<void> setAll(Db db, Map<String, Object?> values) async {
    for (final e in values.entries) {
      await set(db, e.key, e.value);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

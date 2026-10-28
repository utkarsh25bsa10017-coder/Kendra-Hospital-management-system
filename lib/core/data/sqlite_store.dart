import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'query.dart';
import 'record.dart';
import 'record_store.dart';
import 'schema.dart';

/// The hospital database: one SQLite file on the hub (or standalone) device.
///
/// * Tables are created and migrated from [CollectionSchema]s.
/// * Every write is atomic and is recorded in an append-only, hash-chained
///   audit log; SQLite triggers reject any UPDATE or DELETE on that log.
/// * Records are never deleted, only archived.
class SqliteRecordStore implements RecordStore {
  SqliteRecordStore._(this._db, this.schemas, this.deviceId) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _migrateCore();
    for (final s in schemas.all) {
      _migrateCollection(s);
    }
    _reloadLastHash();
  }

  factory SqliteRecordStore.open(String path, SchemaRegistry schemas, {String deviceId = ''}) =>
      SqliteRecordStore._(sqlite3.open(path), schemas, deviceId);

  factory SqliteRecordStore.inMemory(SchemaRegistry schemas, {String deviceId = 'test'}) =>
      SqliteRecordStore._(sqlite3.openInMemory(), schemas, deviceId);

  final Database _db;
  @override
  final SchemaRegistry schemas;
  final String deviceId;
  final _changes = StreamController<StoreChange>.broadcast();
  static const _genesis = '0000000000000000000000000000000000000000000000000000000000000000';
  String _lastHash = _genesis;

  @override
  Stream<StoreChange> get changes => _changes.stream;

  // ---------------------------------------------------------------- schema

  void _migrateCore() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        actor_id TEXT NOT NULL,
        actor_name TEXT NOT NULL,
        device_id TEXT NOT NULL DEFAULT '',
        action TEXT NOT NULL,
        collection TEXT,
        record_id TEXT,
        details TEXT NOT NULL,
        prev_hash TEXT NOT NULL,
        hash TEXT NOT NULL
      )''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_audit_record ON audit_log (collection, record_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_audit_actor ON audit_log (actor_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log (ts)');
    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS audit_log_no_update BEFORE UPDATE ON audit_log
      BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END''');
    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS audit_log_no_delete BEFORE DELETE ON audit_log
      BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END''');
    _db.execute('CREATE TABLE IF NOT EXISTS sequences (name TEXT PRIMARY KEY, value INTEGER NOT NULL)');
    _db.execute('CREATE TABLE IF NOT EXISTS kendra_meta (key TEXT PRIMARY KEY, value TEXT)');
    _db.execute("INSERT OR IGNORE INTO kendra_meta (key, value) VALUES ('db_id', ?)", [newId()]);
  }

  static String _sqlType(FieldType t) => switch (t) {
        FieldType.text || FieldType.ref || FieldType.json => 'TEXT',
        FieldType.integer || FieldType.boolean || FieldType.dateTime => 'INTEGER',
        FieldType.real => 'REAL',
      };

  void _migrateCollection(CollectionSchema s) {
    final t = s.name;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS "$t" (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        archived INTEGER NOT NULL DEFAULT 0
      )''');
    final existing = _db.select('PRAGMA table_info("$t")').map((r) => r['name'] as String).toSet();
    for (final f in s.fields) {
      if (!existing.contains(f.name)) {
        _db.execute('ALTER TABLE "$t" ADD COLUMN "${f.name}" ${_sqlType(f.type)}');
      }
      if (f.unique) {
        _db.execute('CREATE UNIQUE INDEX IF NOT EXISTS "ux_${t}_${f.name}" ON "$t" ("${f.name}")');
      } else if (f.indexed) {
        _db.execute('CREATE INDEX IF NOT EXISTS "ix_${t}_${f.name}" ON "$t" ("${f.name}")');
      }
    }
    _db.execute('CREATE INDEX IF NOT EXISTS "ix_${t}_created_at" ON "$t" (created_at)');
    for (final cols in s.compositeIndexes) {
      for (final c in cols) {
        if (!s.hasColumn(c)) throw ArgumentError('Index column "$c" not in "$t"');
      }
      _db.execute('CREATE INDEX IF NOT EXISTS "ix_${t}_${cols.join('_')}" ON "$t" '
          '(${cols.map((c) => '"$c"').join(', ')})');
    }
  }

  // ---------------------------------------------------------------- encoding

  static FieldType _columnType(CollectionSchema s, String column) {
    switch (column) {
      case Sys.createdAt || Sys.updatedAt:
        return FieldType.dateTime;
      case Sys.version:
        return FieldType.integer;
      case Sys.archived:
        return FieldType.boolean;
      case Sys.id || Sys.createdBy || Sys.updatedBy:
        return FieldType.text;
    }
    final f = s.field(column);
    if (f == null) throw ValidationException('Unknown field "$column" in "${s.name}"');
    return f.type;
  }

  static Object? _jsonSafe(Object? v) {
    if (v is DateTime) return v.toUtc().toIso8601String();
    throw ValidationException('Value of type ${v.runtimeType} cannot be stored as JSON');
  }

  static Object? encodeValue(FieldType type, Object? v, String label) {
    if (v == null) return null;
    switch (type) {
      case FieldType.text || FieldType.ref:
        if (v is String) return v;
        throw ValidationException('$label must be text');
      case FieldType.integer:
        if (v is int) return v;
        if (v is num && v == v.roundToDouble()) return v.toInt();
        throw ValidationException('$label must be a whole number');
      case FieldType.real:
        if (v is num) return v.toDouble();
        throw ValidationException('$label must be a number');
      case FieldType.boolean:
        if (v is bool) return v ? 1 : 0;
        throw ValidationException('$label must be true or false');
      case FieldType.dateTime:
        if (v is DateTime) return v.toUtc().millisecondsSinceEpoch;
        if (v is int) return v;
        throw ValidationException('$label must be a date/time');
      case FieldType.json:
        return jsonEncode(v, toEncodable: _jsonSafe);
    }
  }

  static Object? decodeValue(FieldType type, Object? v) {
    if (v == null) return null;
    return switch (type) {
      FieldType.text || FieldType.ref => v is String ? v : v.toString(),
      FieldType.integer => (v as num).toInt(),
      FieldType.real => (v as num).toDouble(),
      FieldType.boolean => v == 1 || v == true,
      FieldType.dateTime => DateTime.fromMillisecondsSinceEpoch((v as num).toInt()),
      FieldType.json => v is String ? jsonDecode(v) : v,
    };
  }

  Rec _decodeRow(CollectionSchema s, Map<String, Object?> row, {bool withSensitive = false}) {
    final out = <String, Object?>{
      Sys.id: row[Sys.id],
      Sys.createdAt: decodeValue(FieldType.dateTime, row[Sys.createdAt]),
      Sys.updatedAt: decodeValue(FieldType.dateTime, row[Sys.updatedAt]),
      Sys.createdBy: row[Sys.createdBy],
      Sys.updatedBy: row[Sys.updatedBy],
      Sys.version: row[Sys.version],
      Sys.archived: row[Sys.archived] == 1,
    };
    for (final f in s.fields) {
      if (f.sensitive && !withSensitive) continue;
      out[f.name] = decodeValue(f.type, row[f.name]);
    }
    return Rec(s.name, out);
  }

  static String _escapeLike(String v) =>
      v.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  (String, List<Object?>) _where(CollectionSchema s, List<Filter> filters,
      {String? search, bool includeArchived = false}) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (!includeArchived) clauses.add('archived = 0');
    for (final f in filters) {
      final type = _columnType(s, f.field);
      final col = '"${f.field}"';
      Object? enc(Object? v) => encodeValue(type == FieldType.json ? FieldType.text : type, v, f.field);
      switch (f.op) {
        case Op.eq:
          clauses.add('$col = ?');
          params.add(enc(f.value));
        case Op.neq:
          clauses.add('($col IS NULL OR $col != ?)');
          params.add(enc(f.value));
        case Op.gt:
          clauses.add('$col > ?');
          params.add(enc(f.value));
        case Op.gte:
          clauses.add('$col >= ?');
          params.add(enc(f.value));
        case Op.lt:
          clauses.add('$col < ?');
          params.add(enc(f.value));
        case Op.lte:
          clauses.add('$col <= ?');
          params.add(enc(f.value));
        case Op.inList:
          final values = (f.value as List?) ?? const [];
          if (values.isEmpty) {
            clauses.add('0');
          } else {
            clauses.add('$col IN (${List.filled(values.length, '?').join(', ')})');
            params.addAll(values.map(enc));
          }
        case Op.contains:
          clauses.add("$col LIKE ? ESCAPE '\\'");
          params.add('%${_escapeLike(f.value.toString())}%');
        case Op.startsWith:
          clauses.add("$col LIKE ? ESCAPE '\\'");
          params.add('${_escapeLike(f.value.toString())}%');
        case Op.isNull:
          clauses.add('$col IS NULL');
        case Op.isNotNull:
          clauses.add('$col IS NOT NULL');
      }
    }
    if (search != null && search.trim().isNotEmpty) {
      final fields = s.searchableFields.toList();
      if (fields.isNotEmpty) {
        for (final word in search.trim().split(RegExp(r'\s+'))) {
          clauses.add('(${fields.map((f) => "\"${f.name}\" LIKE ? ESCAPE '\\'").join(' OR ')})');
          for (var i = 0; i < fields.length; i++) {
            params.add('%${_escapeLike(word)}%');
          }
        }
      }
    }
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', params);
  }

  // ---------------------------------------------------------------- reads

  @override
  Future<Rec?> get(String collection, String id) async => getSync(collection, id);

  Rec? getSync(String collection, String id, {bool withSensitive = false}) {
    final s = schemas[collection];
    final rows = _db.select('SELECT * FROM "${s.name}" WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _decodeRow(s, rows.first, withSensitive: withSensitive);
  }

  @override
  Future<List<Rec>> query(Query q) async => querySync(q);

  List<Rec> querySync(Query q, {bool withSensitive = false}) {
    final s = schemas[q.collection];
    final (where, params) = _where(s, q.filters, search: q.search, includeArchived: q.includeArchived);
    final orderType = _columnType(s, q.orderBy);
    final collate = orderType == FieldType.text ? ' COLLATE NOCASE' : '';
    final dir = q.descending ? 'DESC' : 'ASC';
    var sql = 'SELECT * FROM "${s.name}" $where ORDER BY "${q.orderBy}"$collate $dir, id $dir';
    if (q.limit != null || q.offset > 0) {
      sql += ' LIMIT ? OFFSET ?';
      params.addAll([q.limit ?? -1, q.offset]);
    }
    return _db.select(sql, params).map((r) => _decodeRow(s, r, withSensitive: withSensitive)).toList();
  }

  @override
  Future<int> count(Query q) async {
    final s = schemas[q.collection];
    final (where, params) = _where(s, q.filters, search: q.search, includeArchived: q.includeArchived);
    return _db.select('SELECT COUNT(*) AS c FROM "${s.name}" $where', params).first['c'] as int;
  }

  @override
  Future<List<AggRow>> aggregate(AggQuery q) async {
    final s = schemas[q.collection];
    final (where, params) = _where(s, q.filters, includeArchived: q.includeArchived);
    String keyExpr = 'NULL';
    FieldType? keyType;
    if (q.groupBy != null) {
      keyType = _columnType(s, q.groupBy!);
      keyExpr = '"${q.groupBy}"';
    } else if (q.groupByDay != null) {
      if (_columnType(s, q.groupByDay!) != FieldType.dateTime) {
        throw ValidationException('groupByDay needs a date field');
      }
      keyExpr = "strftime('%Y-%m-%d', \"${q.groupByDay}\" / 1000, 'unixepoch', 'localtime')";
    }
    for (final f in q.sums) {
      final t = _columnType(s, f);
      if (t != FieldType.integer && t != FieldType.real) {
        throw ValidationException('Cannot sum non-numeric field "$f"');
      }
    }
    final sums = q.sums.map((f) => ', SUM("$f") AS "s_$f"').join();
    final rows = _db.select(
        'SELECT $keyExpr AS k, COUNT(*) AS c$sums FROM "${s.name}" $where GROUP BY k ORDER BY k', params);
    return rows.map((r) {
      final key = keyType == null ? r['k'] : decodeValue(keyType, r['k']);
      return AggRow(key, r['c'] as int, {for (final f in q.sums) f: (r['s_$f'] as num?) ?? 0});
    }).toList();
  }

  // ---------------------------------------------------------------- writes

  void _checkWrite(CollectionSchema s, Actor actor) {
    if (s.writePermissions.isEmpty) return;
    if (!actor.canAny(s.writePermissions)) {
      throw PermissionDeniedException('You do not have permission to change ${s.name.replaceAll('_', ' ')}');
    }
  }

  static Object? _redact(Field f, Object? v) => f.sensitive && v != null ? '***' : v;

  @override
  Future<List<Rec>> apply(List<WriteOp> ops, Actor actor) async => applySync(ops, actor);

  List<Rec> applySync(List<WriteOp> ops, Actor actor) {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final results = <Rec>[];
    final changes = <StoreChange>[];
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final op in ops) {
        final s = schemas[op.collection];
        _checkWrite(s, actor);
        switch (op) {
          case InsertOp():
            results.add(_insert(s, op, actor, nowMs));
            changes.add(StoreChange(s.name, results.last.id, ChangeKind.insert));
          case UpdateOp():
            final (rec, changed) = _update(s, op, actor, nowMs);
            results.add(rec);
            if (changed) changes.add(StoreChange(s.name, rec.id, ChangeKind.update));
          case ArchiveOp():
            results.add(_archive(s, op, actor, nowMs));
            changes.add(StoreChange(s.name, op.id, ChangeKind.archive));
        }
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      _reloadLastHash();
      if (e is SqliteException && e.message.contains('UNIQUE constraint failed')) {
        final field = e.message.split('.').last.trim();
        throw ValidationException('Another record already uses this ${field.replaceAll('_', ' ')}');
      }
      rethrow;
    }
    for (final c in changes) {
      _changes.add(c);
    }
    return results;
  }

  Rec _insert(CollectionSchema s, InsertOp op, Actor actor, int nowMs) {
    final id = op.id ?? newId();
    final row = <String, Object?>{
      Sys.id: id,
      Sys.createdAt: nowMs,
      Sys.updatedAt: nowMs,
      Sys.createdBy: actor.id,
      Sys.updatedBy: actor.id,
      Sys.version: 1,
      Sys.archived: 0,
    };
    final auditData = <String, Object?>{};
    op.data.forEach((k, v) {
      final f = s.field(k);
      if (f == null) throw ValidationException('Unknown field "$k" in "${s.name}"');
      final enc = encodeValue(f.type, v, k);
      row[k] = enc;
      if (enc != null) auditData[k] = _redact(f, enc);
    });
    for (final f in s.fields.where((f) => f.required)) {
      final v = row[f.name];
      if (v == null || (v is String && v.trim().isEmpty)) {
        throw ValidationException('${_label(f.name)} is required');
      }
    }
    final cols = row.keys.toList();
    _db.execute(
      'INSERT INTO "${s.name}" (${cols.map((c) => '"$c"').join(', ')}) '
      'VALUES (${List.filled(cols.length, '?').join(', ')})',
      [for (final c in cols) row[c]],
    );
    _writeAudit(nowMs, actor, 'insert', s.name, id, {'data': auditData});
    return _decodeRow(s, row);
  }

  (Rec, bool) _update(CollectionSchema s, UpdateOp op, Actor actor, int nowMs) {
    final rows = _db.select('SELECT * FROM "${s.name}" WHERE id = ?', [op.id]);
    if (rows.isEmpty) throw ValidationException('Record not found in ${s.name}');
    final cur = Map<String, Object?>.from(rows.first);
    if (op.expectedVersion != null && cur[Sys.version] != op.expectedVersion) {
      throw ConflictException('Someone else changed this record. Reload it and try again.');
    }
    final sets = <String, Object?>{};
    final diff = <String, Object?>{};
    op.patch.forEach((k, v) {
      final f = s.field(k);
      if (f == null) throw ValidationException('Unknown field "$k" in "${s.name}"');
      final enc = encodeValue(f.type, v, k);
      if (enc == null && f.required) throw ValidationException('${_label(k)} is required');
      if (enc != cur[k]) {
        sets[k] = enc;
        diff[k] = [_redact(f, cur[k]), _redact(f, enc)];
      }
    });
    if (sets.isEmpty) return (_decodeRow(s, cur), false);
    final assigns = sets.keys.map((k) => '"$k" = ?').join(', ');
    _db.execute(
      'UPDATE "${s.name}" SET $assigns, version = version + 1, updated_at = ?, updated_by = ? WHERE id = ?',
      [...sets.values, nowMs, actor.id, op.id],
    );
    cur.addAll(sets);
    cur[Sys.version] = (cur[Sys.version] as int) + 1;
    cur[Sys.updatedAt] = nowMs;
    cur[Sys.updatedBy] = actor.id;
    _writeAudit(nowMs, actor, 'update', s.name, op.id, {'changes': diff});
    return (_decodeRow(s, cur), true);
  }

  Rec _archive(CollectionSchema s, ArchiveOp op, Actor actor, int nowMs) {
    _db.execute(
      'UPDATE "${s.name}" SET archived = 1, version = version + 1, updated_at = ?, updated_by = ? WHERE id = ?',
      [nowMs, actor.id, op.id],
    );
    if (_db.updatedRows == 0) throw ValidationException('Record not found in ${s.name}');
    _writeAudit(nowMs, actor, 'archive', s.name, op.id, {if (op.reason != null) 'reason': op.reason});
    return getSync(s.name, op.id)!;
  }

  static String _label(String field) {
    final s = field.replaceAll('_id', '').replaceAll('_', ' ');
    return s.isEmpty ? field : s[0].toUpperCase() + s.substring(1);
  }

  @override
  Future<int> nextSequence(String name, Actor actor) async => nextSequenceSync(name);

  int nextSequenceSync(String name) {
    final r = _db.select(
      'INSERT INTO sequences (name, value) VALUES (?, 1) '
      'ON CONFLICT(name) DO UPDATE SET value = value + 1 RETURNING value',
      [name],
    );
    return r.first['value'] as int;
  }

  // ---------------------------------------------------------------- audit

  void _reloadLastHash() {
    final r = _db.select('SELECT hash FROM audit_log ORDER BY seq DESC LIMIT 1');
    _lastHash = r.isEmpty ? _genesis : r.first['hash'] as String;
  }

  static String _hashOf(String prev, int ts, String actorId, String actorName, String deviceId,
          String action, String? collection, String? recordId, String detailsJson) =>
      sha256
          .convert(utf8.encode(
              '$prev|$ts|$actorId|$actorName|$deviceId|$action|${collection ?? ''}|${recordId ?? ''}|$detailsJson'))
          .toString();

  void _writeAudit(int ts, Actor actor, String action, String? collection, String? recordId,
      Map<String, Object?> details) {
    final dev = actor.deviceId.isEmpty ? deviceId : actor.deviceId;
    final detailsJson = jsonEncode(details, toEncodable: _jsonSafe);
    final hash = _hashOf(_lastHash, ts, actor.id, actor.name, dev, action, collection, recordId, detailsJson);
    _db.execute(
      'INSERT INTO audit_log (ts, actor_id, actor_name, device_id, action, collection, record_id, details, prev_hash, hash) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [ts, actor.id, actor.name, dev, action, collection, recordId, detailsJson, _lastHash, hash],
    );
    _lastHash = hash;
  }

  @override
  Future<void> appendAudit(String action, Actor actor,
      {String? collection, String? recordId, Map<String, Object?> details = const {}}) async {
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _writeAudit(ts, actor, action, collection, recordId, details);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      _reloadLastHash();
      rethrow;
    }
  }

  @override
  Future<List<AuditEntry>> auditLog(AuditFilter f) async {
    final clauses = <String>[];
    final params = <Object?>[];
    void add(String c, Object? v) {
      clauses.add(c);
      params.add(v);
    }

    if (f.collection != null) add('collection = ?', f.collection);
    if (f.recordId != null) add('record_id = ?', f.recordId);
    if (f.actorId != null) add('actor_id = ?', f.actorId);
    if (f.action != null) add('action = ?', f.action);
    if (f.from != null) add('ts >= ?', f.from!.toUtc().millisecondsSinceEpoch);
    if (f.to != null) add('ts < ?', f.to!.toUtc().millisecondsSinceEpoch);
    if (f.beforeSeq != null) add('seq < ?', f.beforeSeq);
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = _db.select('SELECT * FROM audit_log $where ORDER BY seq DESC LIMIT ?', [...params, f.limit]);
    return rows
        .map((r) => AuditEntry(
              seq: r['seq'] as int,
              ts: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
              actorId: r['actor_id'] as String,
              actorName: r['actor_name'] as String,
              deviceId: r['device_id'] as String,
              action: r['action'] as String,
              collection: r['collection'] as String?,
              recordId: r['record_id'] as String?,
              details: (jsonDecode(r['details'] as String) as Map).cast<String, Object?>(),
              hash: r['hash'] as String,
            ))
        .toList();
  }

  @override
  Future<AuditVerification> verifyAudit() async {
    var prev = _genesis;
    var checked = 0;
    var lastSeq = 0;
    while (true) {
      final rows = _db.select('SELECT * FROM audit_log WHERE seq > ? ORDER BY seq LIMIT 2000', [lastSeq]);
      if (rows.isEmpty) break;
      for (final r in rows) {
        final seq = r['seq'] as int;
        if (r['prev_hash'] != prev) {
          return AuditVerification(
              ok: false, checked: checked, brokenAtSeq: seq, message: 'Entry $seq does not follow entry ${seq - 1}');
        }
        final h = _hashOf(prev, r['ts'] as int, r['actor_id'] as String, r['actor_name'] as String,
            r['device_id'] as String, r['action'] as String, r['collection'] as String?,
            r['record_id'] as String?, r['details'] as String);
        if (h != r['hash']) {
          return AuditVerification(
              ok: false, checked: checked, brokenAtSeq: seq, message: 'Entry $seq was altered after it was written');
        }
        prev = h;
        checked++;
        lastSeq = seq;
      }
    }
    return AuditVerification(ok: true, checked: checked, message: 'All $checked entries are intact');
  }

  // ---------------------------------------------------------------- maintenance

  /// Writes a consistent copy of the database to [path].
  void backupTo(String path) => _db.execute('VACUUM INTO ?', [path]);

  String get databaseId =>
      _db.select("SELECT value FROM kendra_meta WHERE key = 'db_id'").first['value'] as String;

  @override
  Future<void> close() async {
    // Not awaited: the done event may be delivered in another zone.
    _changes.close().ignore();
    _db.close();
  }
}

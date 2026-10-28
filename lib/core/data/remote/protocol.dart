/// JSON wire format shared by the hub server and its clients.
library;

import '../query.dart';
import '../record.dart';
import '../record_store.dart';

const hubDefaultPort = 8787;
const hubProtocolVersion = 1;
const hubKeyHeader = 'x-kendra-key';

Object? wireEncode(Object? v) {
  if (v is DateTime) return {r'$dt': v.toUtc().millisecondsSinceEpoch};
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), wireEncode(val)));
  if (v is Iterable) return v.map(wireEncode).toList();
  return v;
}

Object? wireDecode(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v.containsKey(r'$dt')) {
      return DateTime.fromMillisecondsSinceEpoch((v[r'$dt'] as num).toInt());
    }
    return v.map((k, val) => MapEntry(k as String, wireDecode(val)));
  }
  if (v is List) return v.map(wireDecode).toList();
  return v;
}

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();

List<Object?> encodeFilters(List<Filter> fs) =>
    [for (final f in fs) [f.field, f.op.name, wireEncode(f.value)]];

List<Filter> decodeFilters(Object? v) => [
      for (final f in (v as List? ?? const []))
        Filter((f as List)[0] as String, Op.values.byName(f[1] as String), wireDecode(f[2])),
    ];

Map<String, Object?> encodeQuery(Query q) => {
      'c': q.collection,
      'f': encodeFilters(q.filters),
      's': q.search,
      'o': q.orderBy,
      'd': q.descending,
      'l': q.limit,
      'off': q.offset,
      'a': q.includeArchived,
    };

Query decodeQuery(Object? v) {
  final m = _map(v);
  return Query(
    m['c'] as String,
    filters: decodeFilters(m['f']),
    search: m['s'] as String?,
    orderBy: (m['o'] as String?) ?? 'created_at',
    descending: (m['d'] as bool?) ?? true,
    limit: m['l'] as int?,
    offset: (m['off'] as int?) ?? 0,
    includeArchived: (m['a'] as bool?) ?? false,
  );
}

Map<String, Object?> encodeAggQuery(AggQuery q) => {
      'c': q.collection,
      'f': encodeFilters(q.filters),
      'g': q.groupBy,
      'gd': q.groupByDay,
      'sum': q.sums,
      'a': q.includeArchived,
    };

AggQuery decodeAggQuery(Object? v) {
  final m = _map(v);
  return AggQuery(
    m['c'] as String,
    filters: decodeFilters(m['f']),
    groupBy: m['g'] as String?,
    groupByDay: m['gd'] as String?,
    sums: ((m['sum'] as List?) ?? const []).cast<String>(),
    includeArchived: (m['a'] as bool?) ?? false,
  );
}

Map<String, Object?> encodeAggRow(AggRow r) => {'k': wireEncode(r.key), 'n': r.count, 's': r.sums};

AggRow decodeAggRow(Object? v) {
  final m = _map(v);
  return AggRow(wireDecode(m['k']), m['n'] as int, _map(m['s']).map((k, v) => MapEntry(k, v as num)));
}

Map<String, Object?> encodeOp(WriteOp op) => switch (op) {
      InsertOp() => {'t': 'i', 'c': op.collection, 'id': op.id, 'data': wireEncode(op.data)},
      UpdateOp() => {
          't': 'u',
          'c': op.collection,
          'id': op.id,
          'data': wireEncode(op.patch),
          'ev': op.expectedVersion,
        },
      ArchiveOp() => {'t': 'a', 'c': op.collection, 'id': op.id, 'reason': op.reason},
    };

WriteOp decodeOp(Object? v) {
  final m = _map(v);
  final c = m['c'] as String;
  return switch (m['t']) {
    'i' => InsertOp(c, _map(wireDecode(m['data'])), id: m['id'] as String?),
    'u' => UpdateOp(c, m['id'] as String, _map(wireDecode(m['data'])), expectedVersion: m['ev'] as int?),
    'a' => ArchiveOp(c, m['id'] as String, reason: m['reason'] as String?),
    _ => throw ArgumentError('Unknown op ${m['t']}'),
  };
}

Map<String, Object?> encodeRec(Rec r) => {'c': r.collection, 'd': wireEncode(r.data)};
Rec decodeRec(Object? v) {
  final m = _map(v);
  return Rec(m['c'] as String, _map(wireDecode(m['d'])));
}

Map<String, Object?> encodeAuditFilter(AuditFilter f) => {
      'c': f.collection,
      'r': f.recordId,
      'u': f.actorId,
      'a': f.action,
      'from': f.from?.millisecondsSinceEpoch,
      'to': f.to?.millisecondsSinceEpoch,
      'b': f.beforeSeq,
      'l': f.limit,
    };

AuditFilter decodeAuditFilter(Object? v) {
  final m = _map(v);
  DateTime? dt(Object? x) => x == null ? null : DateTime.fromMillisecondsSinceEpoch(x as int);
  return AuditFilter(
    collection: m['c'] as String?,
    recordId: m['r'] as String?,
    actorId: m['u'] as String?,
    action: m['a'] as String?,
    from: dt(m['from']),
    to: dt(m['to']),
    beforeSeq: m['b'] as int?,
    limit: (m['l'] as int?) ?? 100,
  );
}

Map<String, Object?> encodeChange(StoreChange c) => {'c': c.collection, 'id': c.id, 'k': c.kind.name};
StoreChange decodeChange(Object? v) {
  final m = _map(v);
  return StoreChange(m['c'] as String, m['id'] as String, ChangeKind.values.byName(m['k'] as String));
}

/// Error kinds sent back by the hub so the client can rethrow the same type.
abstract final class WireError {
  static const validation = 'validation';
  static const conflict = 'conflict';
  static const permission = 'permission';
  static const auth = 'auth';
  static const session = 'session';
  static const other = 'other';
}

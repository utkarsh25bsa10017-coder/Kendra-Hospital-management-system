import 'dart:async';

import 'query.dart';
import 'record.dart';
import 'record_store.dart';

/// Read-only view of the database. Agents only ever get this.
class ReadDb {
  ReadDb(this.store);
  final RecordStore store;

  Future<Rec?> get(String collection, String? id) async =>
      id == null || id.isEmpty ? null : store.get(collection, id);
  Future<List<Rec>> query(Query q) => store.query(q);
  Future<Rec?> first(Query q) async {
    final r = await store.query(q.take(1));
    return r.isEmpty ? null : r.first;
  }

  Future<int> count(Query q) => store.count(q);
  Future<List<AggRow>> aggregate(AggQuery q) => store.aggregate(q);

  /// Sum of a numeric field over the matching records.
  Future<num> sum(Query q, String field) async {
    final rows = await store.aggregate(AggQuery.of(q, sums: [field]));
    return rows.isEmpty ? 0 : rows.first.sum(field);
  }

  /// Loads records by id, keyed by id. Missing ids are left out.
  Future<Map<String, Rec>> byIds(String collection, Iterable<String?> ids) async {
    final unique = ids.whereType<String>().where((e) => e.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return {};
    final out = <String, Rec>{};
    for (var i = 0; i < unique.length; i += 500) {
      final chunk = unique.sublist(i, i + 500 > unique.length ? unique.length : i + 500);
      for (final r in await store.query(Query(collection).isIn('id', chunk).withArchived())) {
        out[r.id] = r;
      }
    }
    return out;
  }

  /// Fires (debounced) whenever any of [collections] changes.
  Stream<void> watchCollections(Set<String> collections,
      {Duration debounce = const Duration(milliseconds: 120)}) {
    late StreamController<void> ctrl;
    StreamSubscription<StoreChange>? sub;
    Timer? timer;
    ctrl = StreamController<void>(
      onListen: () {
        sub = store.changes.where((c) => c.collection == '*' || collections.contains(c.collection)).listen((_) {
          timer?.cancel();
          timer = Timer(debounce, () {
            if (!ctrl.isClosed) ctrl.add(null);
          });
        });
      },
      onCancel: () {
        timer?.cancel();
        return sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  /// Emits the query result now and again after every relevant change.
  Stream<List<Rec>> watch(Query q) async* {
    yield await query(q);
    await for (final _ in watchCollections({q.collection})) {
      yield await query(q);
    }
  }
}

/// Read/write access bound to whoever is signed in. Every write is
/// attributed to [actor] and audited.
class Db extends ReadDb {
  Db(super.store, this._actor);
  final Actor Function() _actor;

  Actor get actor => _actor();

  Future<Rec> insert(String collection, Map<String, Object?> data, {String? id}) async =>
      (await store.apply([InsertOp(collection, data, id: id)], actor)).single;

  Future<Rec> update(String collection, String id, Map<String, Object?> patch, {int? expectedVersion}) async =>
      (await store.apply([UpdateOp(collection, id, patch, expectedVersion: expectedVersion)], actor)).single;

  Future<void> archive(String collection, String id, {String? reason}) =>
      store.apply([ArchiveOp(collection, id, reason: reason)], actor);

  /// All-or-nothing group of writes. Use [newId] to pre-assign ids so ops
  /// in the same batch can reference each other.
  Future<List<Rec>> batch(List<WriteOp> ops) => ops.isEmpty ? Future.value(const []) : store.apply(ops, actor);

  Future<int> nextSequence(String name) => store.nextSequence(name, actor);

  Future<void> audit(String action,
          {String? collection, String? recordId, Map<String, Object?> details = const {}}) =>
      store.appendAudit(action, actor, collection: collection, recordId: recordId, details: details);

  String newId() => _newId();
}

String _newId() => newId();

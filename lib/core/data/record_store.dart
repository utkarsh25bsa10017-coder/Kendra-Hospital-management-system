import 'query.dart';
import 'record.dart';
import 'schema.dart';

class AuditEntry {
  const AuditEntry({
    required this.seq,
    required this.ts,
    required this.actorId,
    required this.actorName,
    required this.deviceId,
    required this.action,
    required this.collection,
    required this.recordId,
    required this.details,
    required this.hash,
  });

  final int seq;
  final DateTime ts;
  final String actorId;
  final String actorName;
  final String deviceId;

  /// insert, update, archive, or a custom action such as login or approve.
  final String action;
  final String? collection;
  final String? recordId;
  final Map<String, Object?> details;
  final String hash;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'ts': ts.millisecondsSinceEpoch,
        'actorId': actorId,
        'actorName': actorName,
        'deviceId': deviceId,
        'action': action,
        'collection': collection,
        'recordId': recordId,
        'details': details,
        'hash': hash,
      };

  static AuditEntry fromJson(Map<String, Object?> j) => AuditEntry(
        seq: j['seq'] as int,
        ts: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        actorId: j['actorId'] as String,
        actorName: j['actorName'] as String,
        deviceId: (j['deviceId'] as String?) ?? '',
        action: j['action'] as String,
        collection: j['collection'] as String?,
        recordId: j['recordId'] as String?,
        details: (j['details'] as Map?)?.cast<String, Object?>() ?? const {},
        hash: j['hash'] as String,
      );
}

class AuditFilter {
  const AuditFilter({
    this.collection,
    this.recordId,
    this.actorId,
    this.action,
    this.from,
    this.to,
    this.beforeSeq,
    this.limit = 100,
  });
  final String? collection;
  final String? recordId;
  final String? actorId;
  final String? action;
  final DateTime? from;
  final DateTime? to;
  final int? beforeSeq;
  final int limit;
}

class AuditVerification {
  const AuditVerification({required this.ok, required this.checked, this.brokenAtSeq, this.message = ''});
  final bool ok;
  final int checked;
  final int? brokenAtSeq;
  final String message;
}

/// The database contract. Implemented by the local SQLite store and by the
/// network client that talks to the hospital hub.
abstract class RecordStore {
  SchemaRegistry get schemas;

  Future<Rec?> get(String collection, String id);
  Future<List<Rec>> query(Query q);
  Future<int> count(Query q);
  Future<List<AggRow>> aggregate(AggQuery q);

  /// Applies all ops atomically: either every op succeeds or none do.
  Future<List<Rec>> apply(List<WriteOp> ops, Actor actor);

  /// Atomically increments and returns the named counter (UHIDs, bill numbers).
  Future<int> nextSequence(String name, Actor actor);

  /// Records a non-data event (login, approval, record viewed, export...).
  Future<void> appendAudit(String action, Actor actor,
      {String? collection, String? recordId, Map<String, Object?> details = const {}});

  Future<List<AuditEntry>> auditLog(AuditFilter filter);
  Future<AuditVerification> verifyAudit();

  /// Emits after every committed write, on this device and (for the hub and
  /// its clients) on every connected device.
  Stream<StoreChange> get changes;

  Future<void> close();
}

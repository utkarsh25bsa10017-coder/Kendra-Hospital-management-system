/// Store-independent query descriptions. They are plain data so the same
/// query runs against the local SQLite store or is sent to the hub.
library;

enum Op { eq, neq, gt, gte, lt, lte, inList, contains, startsWith, isNull, isNotNull }

class Filter {
  const Filter(this.field, this.op, [this.value]);
  final String field;
  final Op op;
  final Object? value;
}

class Query {
  const Query(
    this.collection, {
    this.filters = const [],
    this.search,
    this.orderBy = 'created_at',
    this.descending = true,
    this.limit,
    this.offset = 0,
    this.includeArchived = false,
  });

  final String collection;
  final List<Filter> filters;

  /// Free text; every word must match one of the collection's searchable fields.
  final String? search;
  final String orderBy;
  final bool descending;
  final int? limit;
  final int offset;
  final bool includeArchived;

  Query _with({
    List<Filter>? filters,
    String? search,
    String? orderBy,
    bool? descending,
    int? limit,
    int? offset,
    bool? includeArchived,
  }) =>
      Query(
        collection,
        filters: filters ?? this.filters,
        search: search ?? this.search,
        orderBy: orderBy ?? this.orderBy,
        descending: descending ?? this.descending,
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
        includeArchived: includeArchived ?? this.includeArchived,
      );

  Query where(String field, Op op, [Object? value]) =>
      _with(filters: [...filters, Filter(field, op, value)]);

  Query eq(String field, Object? value) =>
      value == null ? where(field, Op.isNull) : where(field, Op.eq, value);
  Query neq(String field, Object? value) => where(field, Op.neq, value);
  Query gt(String field, Object value) => where(field, Op.gt, value);
  Query gte(String field, Object value) => where(field, Op.gte, value);
  Query lt(String field, Object value) => where(field, Op.lt, value);
  Query lte(String field, Object value) => where(field, Op.lte, value);
  Query isIn(String field, Iterable<Object?> values) =>
      where(field, Op.inList, values.toList());
  Query contains(String field, String value) => where(field, Op.contains, value);
  Query startsWith(String field, String value) => where(field, Op.startsWith, value);
  Query isNull(String field) => where(field, Op.isNull);
  Query isNotNull(String field) => where(field, Op.isNotNull);

  /// Records whose [field] (a dateTime) falls in [from, to).
  Query between(String field, DateTime from, DateTime to) =>
      where(field, Op.gte, from).where(field, Op.lt, to);

  Query matching(String? text) =>
      (text == null || text.trim().isEmpty) ? this : _with(search: text.trim());
  Query sort(String field, {bool desc = false}) => _with(orderBy: field, descending: desc);
  Query take(int n, {int skip = 0}) => _with(limit: n, offset: skip);
  Query withArchived() => _with(includeArchived: true);
}

/// Grouped counts and sums, e.g. revenue per day.
class AggQuery {
  const AggQuery(
    this.collection, {
    this.filters = const [],
    this.groupBy,
    this.groupByDay,
    this.sums = const [],
    this.includeArchived = false,
  });

  /// Build from an existing [Query]'s filters.
  AggQuery.of(Query q, {this.groupBy, this.groupByDay, this.sums = const []})
      : collection = q.collection,
        filters = q.filters,
        includeArchived = q.includeArchived;

  final String collection;
  final List<Filter> filters;

  /// Group by the raw value of this field.
  final String? groupBy;

  /// Group by the local calendar day (yyyy-MM-dd) of this dateTime field.
  final String? groupByDay;
  final List<String> sums;
  final bool includeArchived;
}

class AggRow {
  const AggRow(this.key, this.count, this.sums);

  /// Group key (null when not grouped).
  final Object? key;
  final int count;
  final Map<String, num> sums;

  num sum(String field) => sums[field] ?? 0;
}

sealed class WriteOp {
  const WriteOp(this.collection);
  final String collection;
}

class InsertOp extends WriteOp {
  const InsertOp(super.collection, this.data, {this.id});
  final Map<String, Object?> data;

  /// Optional pre-generated id so other ops in the same batch can reference it.
  final String? id;
}

class UpdateOp extends WriteOp {
  const UpdateOp(super.collection, this.id, this.patch, {this.expectedVersion});
  final String id;
  final Map<String, Object?> patch;

  /// When set, the update fails with a ConflictException if someone else
  /// changed the record in the meantime.
  final int? expectedVersion;
}

/// Records are never deleted; archiving hides them from normal queries.
class ArchiveOp extends WriteOp {
  const ArchiveOp(super.collection, this.id, {this.reason});
  final String id;
  final String? reason;
}

enum ChangeKind { insert, update, archive }

class StoreChange {
  const StoreChange(this.collection, this.id, this.kind);
  final String collection;
  final String id;
  final ChangeKind kind;
}

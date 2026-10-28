/// Collection schemas: every table in the database is declared by a module as
/// a [CollectionSchema]. The store creates and migrates tables from these
/// declarations, so adding a field or a whole module never needs hand-written
/// migration code.
library;

enum FieldType { text, integer, real, boolean, dateTime, json, ref }

class Field {
  const Field(
    this.name,
    this.type, {
    this.required = false,
    this.indexed = false,
    this.unique = false,
    this.searchable = false,
    this.sensitive = false,
    this.refCollection,
  });

  const Field.text(this.name,
      {this.required = false,
      this.indexed = false,
      this.unique = false,
      this.searchable = false,
      this.sensitive = false})
      : type = FieldType.text,
        refCollection = null;

  /// Whole numbers. Money is always stored as an integer number of paise.
  const Field.integer(this.name,
      {this.required = false, this.indexed = false, this.unique = false})
      : type = FieldType.integer,
        searchable = false,
        sensitive = false,
        refCollection = null;

  const Field.real(this.name, {this.required = false, this.indexed = false})
      : type = FieldType.real,
        unique = false,
        searchable = false,
        sensitive = false,
        refCollection = null;

  const Field.boolean(this.name, {this.required = false, this.indexed = false})
      : type = FieldType.boolean,
        unique = false,
        searchable = false,
        sensitive = false,
        refCollection = null;

  const Field.dateTime(this.name, {this.required = false, this.indexed = false})
      : type = FieldType.dateTime,
        unique = false,
        searchable = false,
        sensitive = false,
        refCollection = null;

  /// Any JSON value (map, list, string, number, bool). Stored as text.
  const Field.json(this.name, {this.required = false, this.sensitive = false})
      : type = FieldType.json,
        indexed = false,
        unique = false,
        searchable = false,
        refCollection = null;

  /// The id of a record in [refCollection].
  const Field.ref(this.name, String this.refCollection,
      {this.required = false, this.indexed = true})
      : type = FieldType.ref,
        unique = false,
        searchable = false,
        sensitive = false;

  final String name;
  final FieldType type;
  final bool required;
  final bool indexed;
  final bool unique;

  /// Included in free-text search (`Query.search`).
  final bool searchable;

  /// Never returned over the network and redacted in audit diffs
  /// (password hashes and similar).
  final bool sensitive;
  final String? refCollection;
}

/// System columns present on every record.
abstract final class Sys {
  static const id = 'id';
  static const createdAt = 'created_at';
  static const updatedAt = 'updated_at';
  static const createdBy = 'created_by';
  static const updatedBy = 'updated_by';
  static const version = 'version';
  static const archived = 'archived';

  static const all = {id, createdAt, updatedAt, createdBy, updatedBy, version, archived};
  static const dateFields = {createdAt, updatedAt};
}

class CollectionSchema {
  const CollectionSchema({
    required this.name,
    required this.fields,
    this.owner = 'core',
    this.description = '',
    this.writePermissions = const {},
    this.compositeIndexes = const [],
  });

  /// Table name, snake_case. Must be unique across all modules.
  final String name;
  final List<Field> fields;

  /// Module id that owns this collection.
  final String owner;
  final String description;

  /// If not empty, the acting user needs at least one of these permissions to
  /// insert, update or archive records. Enforced by the store, on every device.
  final Set<String> writePermissions;
  final List<List<String>> compositeIndexes;

  Field? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  bool hasColumn(String name) => Sys.all.contains(name) || field(name) != null;

  Iterable<Field> get searchableFields => fields.where((f) => f.searchable);
  Iterable<Field> get sensitiveFields => fields.where((f) => f.sensitive);
}

class SchemaRegistry {
  final Map<String, CollectionSchema> _byName = {};

  static final _ident = RegExp(r'^[a-z][a-z0-9_]*$');
  static const reserved = {'audit_log', 'sequences', 'kendra_meta', 'sqlite_master'};

  void register(CollectionSchema s) {
    if (!_ident.hasMatch(s.name) || reserved.contains(s.name)) {
      throw ArgumentError('Invalid collection name "${s.name}"');
    }
    final existing = _byName[s.name];
    if (existing != null && existing.owner != s.owner) {
      throw StateError(
          'Collection "${s.name}" is declared by both "${existing.owner}" and "${s.owner}"');
    }
    final seen = <String>{};
    for (final f in s.fields) {
      if (!_ident.hasMatch(f.name) || Sys.all.contains(f.name)) {
        throw ArgumentError('Invalid field name "${f.name}" in "${s.name}"');
      }
      if (!seen.add(f.name)) {
        throw ArgumentError('Duplicate field "${f.name}" in "${s.name}"');
      }
    }
    _byName[s.name] = s;
  }

  void registerAll(Iterable<CollectionSchema> list) => list.forEach(register);

  CollectionSchema operator [](String name) {
    final s = _byName[name];
    if (s == null) throw ArgumentError('Unknown collection "$name"');
    return s;
  }

  CollectionSchema? lookup(String name) => _byName[name];
  bool contains(String name) => _byName.containsKey(name);
  Iterable<CollectionSchema> get all => _byName.values;
}

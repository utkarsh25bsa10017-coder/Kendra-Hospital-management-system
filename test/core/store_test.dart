import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/data/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';

const _items = CollectionSchema(
  name: 'items',
  owner: 'test',
  fields: [
    Field.text('code', required: true, unique: true, searchable: true),
    Field.text('name', searchable: true),
    Field.integer('price_paise'),
    Field.boolean('active'),
    Field.dateTime('sold_at'),
    Field.json('tags'),
    Field.text('secret', sensitive: true),
  ],
);

const _actor = Actor(id: 'u1', name: 'Tester', permissions: {'*'});

SchemaRegistry _schemas() => SchemaRegistry()..register(_items);

void main() {
  test('insert, query, update and archive', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    final a = await db.insert('items', {'code': 'A1', 'name': 'Paracetamol', 'price_paise': 1250, 'active': true, 'tags': ['otc']});
    expect(a.version, 1);
    expect(a['tags'], ['otc']);
    expect(a.flag('active'), isTrue);

    final b = await db.update('items', a.id, {'price_paise': 1500});
    expect(b.version, 2);
    expect(b.integer('price_paise'), 1500);

    expect(await db.count(const Query('items')), 1);
    expect((await db.query(const Query('items').matching('parac'))).length, 1);
    expect((await db.query(const Query('items').gt('price_paise', 2000))).length, 0);

    await db.archive('items', a.id, reason: 'test');
    expect(await db.count(const Query('items')), 0);
    expect(await db.count(const Query('items').withArchived()), 1);
  });

  test('rejects unknown fields, missing required fields and duplicates', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    expect(() => db.insert('items', {'code': 'X', 'colour': 'red'}), throwsA(isA<ValidationException>()));
    expect(() => db.insert('items', {'name': 'no code'}), throwsA(isA<ValidationException>()));
    await db.insert('items', {'code': 'DUP'});
    expect(() => db.insert('items', {'code': 'DUP'}), throwsA(isA<ValidationException>()));
  });

  test('optimistic locking catches concurrent edits', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    final a = await db.insert('items', {'code': 'C'});
    await db.update('items', a.id, {'name': 'first'}, expectedVersion: 1);
    expect(() => db.update('items', a.id, {'name': 'second'}, expectedVersion: 1), throwsA(isA<ConflictException>()));
  });

  test('batches are all-or-nothing', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    await expectLater(
      db.batch([
        const InsertOp('items', {'code': 'OK'}),
        const InsertOp('items', {'code': 'OK'}),
      ]),
      throwsA(isA<ValidationException>()),
    );
    expect(await db.count(const Query('items')), 0);
    expect((await s.verifyAudit()).ok, isTrue);
  });

  test('sensitive fields are hidden from normal reads and audit diffs', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    final a = await db.insert('items', {'code': 'S', 'secret': 'hunter2'});
    expect((await db.get('items', a.id))!.data.containsKey('secret'), isFalse);
    expect(s.getSync('items', a.id, withSensitive: true)!['secret'], 'hunter2');
    final log = await s.auditLog(AuditFilter(recordId: a.id));
    expect((log.single.details['data'] as Map)['secret'], '***');
  });

  test('aggregates by day with sums', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    final db = Db(s, () => _actor);
    final d1 = DateTime(2026, 3, 1, 10);
    final d2 = DateTime(2026, 3, 2, 18);
    await db.insert('items', {'code': '1', 'price_paise': 100, 'sold_at': d1});
    await db.insert('items', {'code': '2', 'price_paise': 250, 'sold_at': d1});
    await db.insert('items', {'code': '3', 'price_paise': 400, 'sold_at': d2});
    final rows = await db.aggregate(const AggQuery('items', groupByDay: 'sold_at', sums: ['price_paise']));
    expect(rows.map((r) => r.key), ['2026-03-01', '2026-03-02']);
    expect(rows.first.sum('price_paise'), 350);
    expect(rows.first.count, 2);
    expect(await db.sum(const Query('items'), 'price_paise'), 750);
  });

  test('sequences only go up', () async {
    final s = SqliteRecordStore.inMemory(_schemas());
    expect(await s.nextSequence('uhid', _actor), 1);
    expect(await s.nextSequence('uhid', _actor), 2);
    expect(await s.nextSequence('bill', _actor), 1);
  });

  test('audit log is append-only and tampering is detected', () async {
    final dir = Directory.systemTemp.createTempSync('kendra_audit_');
    final path = '${dir.path}/t.db';
    final s = SqliteRecordStore.open(path, _schemas());
    final db = Db(s, () => _actor);
    final a = await db.insert('items', {'code': 'T', 'price_paise': 100});
    await db.update('items', a.id, {'price_paise': 90});
    await db.audit('login');
    expect((await s.verifyAudit()).ok, isTrue);

    final raw = sqlite3.open(path);
    expect(() => raw.execute("UPDATE audit_log SET actor_name = 'someone else' WHERE seq = 2"), throwsA(isA<SqliteException>()));
    expect(() => raw.execute('DELETE FROM audit_log WHERE seq = 1'), throwsA(isA<SqliteException>()));

    // Someone with file access drops the guard and rewrites history.
    raw.execute('DROP TRIGGER audit_log_no_update');
    raw.execute("UPDATE audit_log SET details = '{\"changes\":{}}' WHERE seq = 2");
    raw.close();
    final v = await s.verifyAudit();
    expect(v.ok, isFalse);
    expect(v.brokenAtSeq, 2);
    await s.close();
  });

  test('new fields are added to existing tables automatically', () async {
    final dir = Directory.systemTemp.createTempSync('kendra_mig_');
    final path = '${dir.path}/m.db';
    final s1 = SqliteRecordStore.open(path, _schemas());
    await Db(s1, () => _actor).insert('items', {'code': 'OLD'});
    await s1.close();

    const v2 = CollectionSchema(name: 'items', owner: 'test', fields: [..._itemsFields, Field.text('colour')]);
    final s2 = SqliteRecordStore.open(path, SchemaRegistry()..register(v2));
    final db2 = Db(s2, () => _actor);
    final r = (await db2.query(const Query('items'))).single;
    expect(r['colour'], isNull);
    await db2.update('items', r.id, {'colour': 'blue'});
    expect((await db2.get('items', r.id))!['colour'], 'blue');
    await s2.close();
  });

  test('collection write permissions are enforced', () async {
    const locked = CollectionSchema(name: 'locked', owner: 'test', writePermissions: {'x.edit'}, fields: [Field.text('a')]);
    final s = SqliteRecordStore.inMemory(SchemaRegistry()..register(locked));
    const nobody = Actor(id: 'u2', name: 'Nobody');
    const editor = Actor(id: 'u3', name: 'Editor', permissions: {'x.edit'});
    expect(() => Db(s, () => nobody).insert('locked', {'a': '1'}), throwsA(isA<PermissionDeniedException>()));
    expect((await Db(s, () => editor).insert('locked', {'a': '1'}))['a'], '1');
  });
}

const _itemsFields = [
  Field.text('code', required: true, unique: true, searchable: true),
  Field.text('name', searchable: true),
  Field.integer('price_paise'),
  Field.boolean('active'),
  Field.dateTime('sold_at'),
  Field.json('tags'),
  Field.text('secret', sensitive: true),
];

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/lab/agents/critical_results_agent.dart';
import 'package:kendra_hms/modules/lab/agents/turnaround_agent.dart';
import 'package:kendra_hms/modules/lab/agents/uncollected_agent.dart';
import 'package:kendra_hms/modules/lab/agents/unverified_agent.dart';
import 'package:kendra_hms/modules/lab/lab_module.dart';
import 'package:kendra_hms/modules/lab/lab_rules.dart';
import 'package:kendra_hms/modules/lab/lab_schema.dart';
import 'package:kendra_hms/modules/lab/lab_service.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

const _k = LabParam(key: 'k', name: 'Potassium', short: 'K+', unit: 'mmol/L', low: 3.5, high: 5.1, criticalLow: 2.8, criticalHigh: 6.2, decimals: 1);
const _hb = LabParam(
    key: 'hb', name: 'Haemoglobin', short: 'Hb', unit: 'g/dL', low: 13, high: 17, femaleLow: 12, femaleHigh: 15, criticalLow: 7, criticalHigh: 20, decimals: 1);
const _wbc = LabParam(key: 'wbc', name: 'Total WBC count', short: 'WBC', unit: '/µL', low: 4000, high: 11000);
const _hiv = LabParam(key: 'hiv', name: 'HIV', kind: LabParam.choice, choices: ['Non-reactive', 'Reactive'], refText: 'Non-reactive');
const _abo = LabParam(key: 'abo', name: 'ABO group', kind: LabParam.choice, choices: ['A', 'B', 'AB', 'O']);
const _colour = LabParam(key: 'colour', name: 'Colour', kind: LabParam.choice, choices: ['Pale yellow', 'Yellow', 'Red'], refText: 'Pale yellow / Yellow');

class _Hospital {
  _Hospital(this.app, this.patient, this.doctor);
  final AppServices app;
  final Rec patient;
  final Rec doctor;
  Db get db => app.db;
  Future<Map<String, Rec>> tests() => LabService.testsByCode(app.readDb);
  Future<Rec> order(String id) async => (await app.readDb.get(Col.serviceOrders, id))!;
}

Future<_Hospital> _boot() async {
  final app = await bootTestHospital([PatientsModule(), LabModule()]);
  final doctor = await addUser(app, 'doc1', [Roles.doctor]);
  await addUser(app, 'tech1', [Roles.labTech]);
  await addUser(app, 'path1', [Roles.pathologist]);
  await addUser(app, 'path2', [Roles.pathologist]);
  final patient = await app.systemDb.insert(Col.patients, {
    'uhid': 'TH-26-000001',
    'first_name': 'Ravi',
    'last_name': 'Kumar',
    'full_name': 'Ravi Kumar',
    'gender': 'male',
    'payer_type': 'self',
  });
  return _Hospital(app, patient, doctor);
}

Future<List<Rec>> _place(_Hospital h, List<String> codes, {String priority = Priority.routine, DateTime? at}) async {
  final tests = await h.tests();
  return LabService.createOrders(h.app.systemDb,
      patientId: h.patient.id, tests: [for (final c in codes) tests[c]!], priority: priority, orderedBy: h.doctor.id, at: at);
}

/// Signs out first so no account refresh runs against a closed database.
Future<void> _close(AppServices app) async {
  if (app.auth.signedIn) await app.auth.logout();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await app.close();
}

Future<List<Rec>> _charges(_Hospital h, String orderId) =>
    h.app.readDb.query(const Query(Col.charges).eq('source_id', orderId).withArchived().take(10));

void main() {
  group('flags', () {
    test('numeric values get L, H, LL and HH', () {
      expect(_k.flagFor('4.2'), '');
      expect(_k.flagFor('3.4'), LabFlag.low);
      expect(_k.flagFor('5.6'), LabFlag.high);
      expect(_k.flagFor('6.8'), LabFlag.criticalHigh);
      expect(_k.flagFor('2.5'), LabFlag.criticalLow);
      expect(_k.flagFor('6.2'), LabFlag.high, reason: 'at the critical limit is high, beyond it is critical');
      expect(_k.flagFor('5.1'), '', reason: 'range limits are inclusive');
      expect(_k.flagFor(''), '');
      expect(_k.flagFor('abc'), '');
      expect(_k.problem('abc'), isNotNull);
      expect(_wbc.flagFor('14,200'), LabFlag.high, reason: 'grouping commas are accepted');
      expect(_wbc.value('14200')['value'], '14,200');
    });

    test('female ranges apply to women only', () {
      expect(_hb.flagFor('12.5', sex: 'male'), LabFlag.low);
      expect(_hb.flagFor('12.5', sex: 'female'), '');
      expect(_hb.flagFor('15.5', sex: 'female'), LabFlag.high);
      expect(_hb.flagFor('6.4', sex: 'female'), LabFlag.criticalLow);
      expect(_hb.refLabel('female'), '12.0 – 15.0');
    });

    test('choice values are abnormal unless they are a normal answer', () {
      expect(_hiv.flagFor('Non-reactive'), '');
      expect(_hiv.flagFor('Reactive'), LabFlag.abnormal);
      expect(_colour.flagFor('Yellow'), '');
      expect(_colour.flagFor('Red'), LabFlag.abnormal);
      expect(_abo.flagFor('AB'), '', reason: 'no normal answer means nothing is flagged');
      expect(LabFlag.isCritical(_hiv.flagFor('Reactive')), isFalse);
    });

    test('summary lists abnormal values, criticals first', () {
      final params = [_hb, _wbc, _k];
      final values = buildValues(params, {'hb': '9.8', 'wbc': '14200', 'k': '4.0'});
      expect(resultSummary(params, values), 'Hb 9.8 L, WBC 14,200 H');
      final crit = buildValues(params, {'hb': '14.0', 'wbc': '7000', 'k': '6.8'});
      expect(resultSummary(params, crit), 'K+ 6.8 HH');
      expect(anyCritical(crit), isTrue);
      expect(criticalText(crit, params), 'K+ 6.8');
      expect(resultSummary(params, buildValues(params, {'hb': '14.0', 'wbc': '7000'})), 'All values normal');
      expect(resultSummary([_k], buildValues([_k], {'k': '4.4'})), 'K+ 4.4 mmol/L');
      expect(resultSummary([_hiv], buildValues([_hiv], {'hiv': 'Reactive'})), 'HIV Reactive');
    });

    test('sample ids and turnaround targets', () {
      expect(sampleIdFor(DateTime(2026, 10, 24), 42), 'S-261024-0042');
      expect(sampleSequence(DateTime(2026, 10, 4)), 'sample:20261004');
      expect(targetMinutes(Priority.stat, 240), 60);
      expect(targetMinutes(Priority.stat, 45), 45);
      expect(targetMinutes(Priority.routine, 240), 240);
    });
  });

  group('workflow', () {
    test('collecting posts exactly one charge per order and is idempotent', () async {
      final h = await _boot();
      await signIn(h.app, 'tech1');
      final orders = await _place(h, ['LAB-CBC', 'LAB-ESR', 'LAB-LFT']);
      final samples = await LabService.collect(h.db, orders);
      expect(samples.length, 2, reason: 'CBC and ESR share the EDTA tube; LFT needs its own');

      final cbc = await h.order(orders[0].id);
      final esr = await h.order(orders[1].id);
      final lft = await h.order(orders[2].id);
      expect(cbc.str('status'), Vals.collected);
      expect(cbc.str('sample_id'), matches(RegExp(r'^S-\d{6}-\d{4}$')));
      expect(esr.str('sample_id'), cbc.str('sample_id'));
      expect(lft.str('sample_id'), isNot(cbc.str('sample_id')));

      final charges = await _charges(h, cbc.id);
      expect(charges, hasLength(1));
      final c = charges.single;
      expect(cbc.str('charge_id'), c.id);
      expect(c.str('category'), Vals.lab);
      expect(c.str('status'), Vals.pending);
      expect(c.str('source_module'), 'lab');
      expect(c.str('source_collection'), Col.serviceOrders);
      expect(c.str('description'), cbc.str('name'));
      expect(c.str('service_code'), 'LAB-CBC');
      expect(c.integer('quantity'), 1);
      expect(c.integer('unit_price_paise'), 35000);
      expect(c.integer('amount_paise'), 35000);
      expect(c.str('ordered_by'), h.doctor.id);
      expect(c.str('patient_id'), h.patient.id);

      // Tapping again (or another device collecting the same orders) does nothing.
      expect(await LabService.collect(h.db, orders), isEmpty);
      expect(await LabService.collect(h.db, [cbc, cbc]), isEmpty);
      for (final o in orders) {
        expect(await _charges(h, o.id), hasLength(1));
      }
      await _close(h.app);
    });

    test('a cancelled order is never charged', () async {
      final h = await _boot();
      await signIn(h.app, 'tech1');
      final orders = await _place(h, ['LAB-TSH']);
      await LabService.cancel(h.db, orders.single, 'Ordered by mistake');
      expect(await LabService.collect(h.db, orders), isEmpty);
      expect(await _charges(h, orders.single.id), isEmpty);
      expect((await h.order(orders.single.id)).str('status'), Vals.cancelled);
      await _close(h.app);
    });

    test('results need a collected sample, and the enterer cannot verify', () async {
      final h = await _boot();
      final tests = await h.tests();
      final orders = await _place(h, ['LAB-ELECTRO']);
      final test = tests['LAB-ELECTRO'];
      await signIn(h.app, 'path1');
      await expectLater(
          LabService.saveResults(h.db, order: orders.single, test: test, raw: {'k': '4.1'}), throwsA(isA<ValidationException>()));
      await LabService.collect(h.app.systemDb, orders);

      final result = await LabService.saveResults(h.db,
          order: await h.order(orders.single.id), test: test, raw: {'na': '138', 'k': '6.8', 'cl': '101'}, sex: 'male');
      expect(result.str('status'), ResultStatus.entered);
      expect(result.flag('critical'), isTrue);
      expect(result.str('entered_by'), h.app.auth.session!.userId);
      var order = await h.order(orders.single.id);
      expect(order.str('status'), Vals.resulted);
      expect(order.flag('critical'), isTrue);
      expect(order.str('result_summary'), 'K+ 6.8 HH');

      // Same pathologist: refused.
      await expectLater(
        LabService.verify(h.db, order: order),
        throwsA(predicate((e) => e is ValidationException && e.message.contains('different person'))),
      );
      // A lab technician cannot verify at all.
      await signIn(h.app, 'tech1');
      await expectLater(LabService.verify(h.db, order: order), throwsA(isA<PermissionDeniedException>()));
      // A second pathologist can; the ordering doctor is told about the critical value.
      await signIn(h.app, 'path2');
      await LabService.verify(h.db, order: order, seen: result);
      order = await h.order(orders.single.id);
      expect(order.str('status'), Vals.verified);
      expect(order.str('verified_by'), h.app.auth.session!.userId);
      final saved = (await LabService.resultFor(h.app.readDb, order.id))!;
      expect(saved.str('status'), ResultStatus.verified);
      expect(saved.str('verified_by_name'), 'Path2');
      final notes = await h.app.readDb.query(Query(Col.notifications).eq('user_id', h.doctor.id).take(10));
      expect(notes.single.str('title'), 'Critical result: K+ 6.8 for Ravi Kumar');
      expect(notes.single.str('severity'), 'critical');

      // Saving over a verified report is refused; it must be amended.
      await signIn(h.app, 'tech1');
      await expectLater(LabService.saveResults(h.db, order: order, test: test, raw: {'k': '4.0'}), throwsA(isA<ValidationException>()));

      // The doctor acknowledges.
      await signIn(h.app, 'doc1');
      await LabService.acknowledge(h.db, result: saved, note: 'Patient called back');
      final acked = (await LabService.resultFor(h.app.readDb, order.id))!;
      expect(acked.str('acknowledged_by_name'), 'Doc1');
      expect(acked.date('acknowledged_at'), isNotNull);
      await expectLater(LabService.acknowledge(h.db, result: acked), throwsA(isA<ValidationException>()));
      await _close(h.app);
    });

    test('verifying values that changed meanwhile is refused', () async {
      final h = await _boot();
      final tests = await h.tests();
      final orders = await _place(h, ['LAB-FBS']);
      await LabService.collect(h.app.systemDb, orders);
      await signIn(h.app, 'tech1');
      final first = await LabService.saveResults(h.db, order: await h.order(orders.single.id), test: tests['LAB-FBS'], raw: {'glu_f': '96'});
      await LabService.saveResults(h.db, order: await h.order(orders.single.id), test: tests['LAB-FBS'], raw: {'glu_f': '196'});
      await signIn(h.app, 'path1');
      await expectLater(
          LabService.verify(h.db, order: await h.order(orders.single.id), seen: first), throwsA(isA<ConflictException>()));
      await _close(h.app);
    });

    test('amending a verified report keeps the previous version', () async {
      final h = await _boot();
      final tests = await h.tests();
      final cbc = tests['LAB-CBC'];
      final orders = await _place(h, ['LAB-CBC']);
      await LabService.collect(h.app.systemDb, orders);
      await signIn(h.app, 'tech1');
      await LabService.saveResults(h.db, order: await h.order(orders.single.id), test: cbc, raw: {'hb': '9.8', 'wbc': '14200'});
      await signIn(h.app, 'path1');
      await LabService.verify(h.db, order: await h.order(orders.single.id));

      await signIn(h.app, 'tech1');
      await expectLater(
        LabService.amend(h.db, order: await h.order(orders.single.id), test: cbc, raw: {'hb': '12.8'}, reason: '  '),
        throwsA(isA<ValidationException>()),
      );
      await LabService.amend(h.db,
          order: await h.order(orders.single.id), test: cbc, raw: {'hb': '13.8', 'wbc': '14200'}, reason: 'Transcription error');
      final amended = (await LabService.resultFor(h.app.readDb, orders.single.id))!;
      expect(amended.str('status'), ResultStatus.amended);
      expect(amended.str('amend_reason'), 'Transcription error');
      expect(amended.date('verified_at'), isNull);
      final history = amended.maps('history');
      expect(history, hasLength(1));
      expect(history.single['reason'], 'Transcription error');
      expect(history.single['verified_by_name'], 'Path1');
      expect((history.single['values'] as List).cast<Map>().firstWhere((v) => v['key'] == 'hb')['value'], '9.8');
      expect(amended.maps('values').firstWhere((v) => v['key'] == 'hb')['value'], '13.8');

      var order = await h.order(orders.single.id);
      expect(order.str('status'), Vals.resulted, reason: 'the corrected report waits for verification again');
      expect(order.str('verified_by'), isEmpty);
      expect(order.str('result_summary'), 'WBC 14,200 H');

      // Only verified reports can be amended.
      await expectLater(
        LabService.amend(h.db, order: order, test: cbc, raw: {'hb': '13.9'}, reason: 'Again'),
        throwsA(isA<ValidationException>()),
      );
      await signIn(h.app, 'path2');
      await LabService.verify(h.db, order: order);
      order = await h.order(orders.single.id);
      expect(order.str('status'), Vals.verified);
      final reverified = (await LabService.resultFor(h.app.readDb, orders.single.id))!;
      expect(reverified.maps('history'), hasLength(1));
      expect(reverified.str('verified_by_name'), 'Path2');
      await _close(h.app);
    });
  });

  group('agents', () {
    test('critical results: unacknowledged in the last 48 h only', () async {
      final h = await _boot();
      final tests = await h.tests();
      final now = DateTime.now();
      final tech = await addUser(h.app, 'tech2', [Roles.labTech]);
      final path = await addUser(h.app, 'path3', [Roles.pathologist]);
      Future<Rec> criticalOrder(Duration ago, String k) async {
        final o = (await _place(h, ['LAB-ELECTRO'], at: now.subtract(ago))).single;
        await LabService.collect(h.app.systemDb, [o], at: now.subtract(ago - const Duration(minutes: 10)));
        await LabService.saveResults(h.app.systemDb,
            order: await h.order(o.id),
            test: tests['LAB-ELECTRO'],
            raw: {'na': '137', 'k': k, 'cl': '100'},
            userId: tech.id,
            userName: 'Tech2',
            at: now.subtract(ago - const Duration(minutes: 40)));
        await LabService.verify(h.app.systemDb,
            order: await h.order(o.id), userId: path.id, userName: 'Path3', at: now.subtract(ago - const Duration(minutes: 60)));
        return o;
      }

      final recent = await criticalOrder(const Duration(hours: 4), '6.8');
      await criticalOrder(const Duration(days: 3), '7.1'); // too old to alert on
      await criticalOrder(const Duration(hours: 6), '4.4'); // not critical

      final ctx = AgentContext(db: h.app.readDb, settings: h.app.settings, now: now);
      var report = await CriticalResultsAgent().run(ctx);
      expect(report.findings, hasLength(1));
      final f = report.findings.single;
      expect(f.severity, Severity.critical);
      expect(f.title, 'Critical result: K+ 6.8 for Ravi Kumar');
      expect(f.patientId, h.patient.id);
      expect(f.evidence.first.routeId, 'lab.order');
      expect(f.evidence.first.routeArgs, {'id': recent.id});

      final result = (await LabService.resultFor(h.app.readDb, recent.id))!;
      await LabService.acknowledge(h.app.systemDb, result: result, userId: h.doctor.id, userName: 'Doc1');
      report = await CriticalResultsAgent().run(ctx);
      expect(report.findings, isEmpty);
      await _close(h.app);
    });

    test('turnaround, uncollected and unverified', () async {
      final h = await _boot();
      final tests = await h.tests();
      final now = DateTime.now();
      DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

      final stat = (await _place(h, ['LAB-RBS'], priority: Priority.stat, at: ago(75))).single; // high
      final lateCbc = (await _place(h, ['LAB-CBC'], at: ago(180))).single; // TAT 120: medium
      await LabService.collect(h.app.systemDb, [lateCbc], at: ago(170));
      final fresh = (await _place(h, ['LAB-CBC'], at: ago(30))).single; // within TAT
      final old = (await _place(h, ['LAB-LIPID'], at: ago(50 * 60))).single; // uncollected
      final waiting = (await _place(h, ['LAB-TSH'], at: ago(7 * 60))).single;
      await LabService.collect(h.app.systemDb, [waiting], at: ago(6 * 60 + 50));
      await LabService.saveResults(h.app.systemDb,
          order: await h.order(waiting.id), test: tests['LAB-TSH'], raw: {'tsh': '2.1'}, at: ago(5 * 60));
      final recentResult = (await _place(h, ['LAB-FBS'], at: ago(90))).single;
      await LabService.collect(h.app.systemDb, [recentResult], at: ago(85));
      await LabService.saveResults(h.app.systemDb,
          order: await h.order(recentResult.id), test: tests['LAB-FBS'], raw: {'glu_f': '90'}, at: ago(55));

      final ctx = AgentContext(db: h.app.readDb, settings: h.app.settings, now: now);
      final tat = {for (final f in (await TurnaroundAgent().run(ctx)).findings) f.key: f};
      expect(tat['order:${stat.id}']?.severity, Severity.high);
      expect(tat['order:${stat.id}']?.title, startsWith('STAT'));
      expect(tat['order:${lateCbc.id}']?.severity, Severity.medium);
      expect(tat.containsKey('order:${fresh.id}'), isFalse);
      expect(tat.containsKey('order:${old.id}'), isFalse, reason: 'left to the uncollected agent');
      expect(tat['order:${waiting.id}']?.severity, Severity.medium, reason: 'TSH TAT is 6 h and it is 7 h old');
      expect(tat['order:${recentResult.id}']?.severity, Severity.medium, reason: 'FBS is due in 1 h; this is 90 min old');

      final uncollected = (await UncollectedAgent().run(ctx)).findings;
      expect(uncollected.map((f) => f.key), ['order:${old.id}']);
      expect(uncollected.single.severity, Severity.low);
      expect(uncollected.single.title, startsWith('Ordered but sample never collected'));

      final unverified = (await UnverifiedAgent().run(ctx)).findings;
      expect(unverified.map((f) => f.key), ['order:${waiting.id}']);
      expect(unverified.single.severity, Severity.low);
      await _close(h.app);
    });
  });

  test('demo data covers every state and charges each collected order once', () async {
    final app = await bootTestHospital([PatientsModule(), LabModule()], demo: true);
    app.agents?.dispose();
    final db = app.readDb;
    Future<int> count(String status) => db.count(LabService.labOrders().eq('status', status));
    expect(await count(Vals.ordered), greaterThanOrEqualTo(6));
    expect(await count(Vals.collected), greaterThanOrEqualTo(5));
    expect(await count(Vals.resulted), greaterThanOrEqualTo(4));
    expect(await count(Vals.verified), greaterThanOrEqualTo(40));
    final collected = await db.count(LabService.labOrders().isNotNull('charge_id'));
    final charges = await db.count(const Query(Col.charges).eq('source_module', 'lab'));
    expect(charges, collected);

    final ctx = AgentContext(db: db, settings: app.settings);
    final critical = (await CriticalResultsAgent().run(ctx)).findings;
    expect(critical.map((f) => f.title), contains(startsWith('Critical result: K+ 6.8 for ')));
    final tat = (await TurnaroundAgent().run(ctx)).findings;
    expect(tat.where((f) => f.severity == Severity.high), isNotEmpty, reason: 'the overdue STAT');
    expect((await UncollectedAgent().run(ctx)).findings, isNotEmpty);
    expect((await UnverifiedAgent().run(ctx)).findings, isNotEmpty);
    await _close(app);
  });
}

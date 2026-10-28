import 'package:kendra_hms/core/core.dart';

import 'lab_rules.dart';
import 'lab_schema.dart';

/// An order with everything a screen needs to show it.
class LabItem {
  LabItem({required this.order, this.patient, this.test, this.result, this.doctorName = ''});
  final Rec order;
  final Rec? patient;
  final Rec? test;
  final Rec? result;
  final String doctorName;

  String get id => order.id;
  String get status => order.str('status');
  String get priority => order.str('priority', Priority.routine);
  bool get isStat => priority == Priority.stat;
  int get tatMinutes => test?.intOrNull('tat_minutes') ?? defaultTatMinutes;
  DateTime get orderedAt => order.date('ordered_at') ?? order.createdAt;
  DateTime get due => dueAt(orderedAt, priority, tatMinutes);
  String get patientName => patient?.str('full_name') ?? 'Unknown patient';
  String get uhid => patient?.str('uhid') ?? '';
  String get testName => order.str('name');
  String get container => test?.str('container') ?? '';
  List<LabParam> get params => paramsOf(test);

  /// Ordered → verified, for completed orders.
  Duration? get turnaround {
    return order.date('verified_at')?.difference(orderedAt);
  }
}

/// A tube that was just labelled.
class CollectedSample {
  CollectedSample({required this.sampleId, required this.container, required this.tests, this.patient, required this.at});
  final String sampleId;
  final String container;
  final List<String> tests;
  final Rec? patient;
  final DateTime at;

  /// What to write on the tube.
  String get labelText {
    final p = patient;
    final who = p == null
        ? ''
        : [
            p.str('full_name'),
            [ageLabel(p.date('dob'), p.intOrNull('age_years')), switch (p.str('gender')) { 'male' => 'M', 'female' => 'F', _ => '' }]
                .where((s) => s.isNotEmpty && s != '—')
                .join(' '),
            p.str('uhid'),
          ].where((s) => s.isNotEmpty).join(' · ');
    return [sampleId, who, '${tests.join(', ')} · $container', formatDateTime(at)].where((s) => s.isNotEmpty).join('\n');
  }
}

/// Lab workflow: order → collect (charge posted) → results → verify, plus
/// amendments and critical-result acknowledgement.
abstract final class LabService {
  static Future<Map<String, Rec>> testsByCode(ReadDb db, {bool activeOnly = false}) async {
    var q = const Query(LabCol.tests).sort('name').take(500);
    if (activeOnly) q = q.eq('active', true);
    return {for (final t in await db.query(q)) t.str('code'): t};
  }

  static Future<Rec?> resultFor(ReadDb db, String orderId) =>
      db.first(Query(LabCol.results).eq('order_id', orderId));

  static Future<Map<String, Rec>> pricesByCode(ReadDb db, Iterable<String> codes) async {
    final list = codes.toSet().toList();
    if (list.isEmpty) return {};
    return {for (final s in await db.query(Query(Col.services).isIn('code', list).take(list.length + 10))) s.str('code'): s};
  }

  /// Loads patients, tests, results and doctor names for [orders].
  static Future<List<LabItem>> loadItems(ReadDb db, List<Rec> orders, {Map<String, Rec>? tests}) async {
    if (orders.isEmpty) return const [];
    final patients = await db.byIds(Col.patients, orders.map((o) => o.strOrNull('patient_id')));
    final users = await db.byIds(Col.users, orders.map((o) => o.strOrNull('ordered_by')));
    final t = tests ?? await testsByCode(db);
    final ids = orders.map((o) => o.id).toList();
    final results = <String, Rec>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      for (final r in await db.query(Query(LabCol.results).isIn('order_id', chunk).take(chunk.length + 5))) {
        results[r.str('order_id')] = r;
      }
    }
    return [
      for (final o in orders)
        LabItem(
          order: o,
          patient: patients[o.str('patient_id')],
          test: t[o.str('service_code')],
          result: results[o.id],
          doctorName: users[o.str('ordered_by')]?.str('display_name') ?? '',
        ),
    ];
  }

  static Query labOrders() => const Query(Col.serviceOrders).eq('order_type', Vals.lab);

  // ---------------------------------------------------------------- ordering

  /// Places one order per test (status 'ordered').
  static Future<List<Rec>> createOrders(
    Db db, {
    required String patientId,
    required List<Rec> tests,
    String priority = Priority.routine,
    String notes = '',
    String? encounterId,
    String? orderedBy,
    DateTime? at,
  }) async {
    if (tests.isEmpty) throw ValidationException('Choose at least one test');
    final when = at ?? DateTime.now();
    return db.batch([
      for (final t in tests)
        InsertOp(Col.serviceOrders, {
          'patient_id': patientId,
          'encounter_id': encounterId,
          'order_type': Vals.lab,
          'service_code': t.str('code'),
          'name': t.str('name'),
          'status': Vals.ordered,
          'priority': priority,
          'ordered_by': orderedBy ?? db.actor.id,
          'ordered_at': when,
          'clinical_notes': notes.trim().isEmpty ? null : notes.trim(),
        }),
    ]);
  }

  /// Cancels an order whose sample was never collected (so nothing was charged).
  static Future<void> cancel(Db db, Rec order, String reason) async {
    final cur = await db.get(Col.serviceOrders, order.id);
    if (cur == null || cur.str('status') != Vals.ordered) {
      throw ValidationException('Only orders whose sample has not been collected can be cancelled');
    }
    await db.update(Col.serviceOrders, order.id, {'status': Vals.cancelled}, expectedVersion: cur.version);
    await db.audit('cancel', collection: Col.serviceOrders, recordId: order.id, details: {'reason': reason});
  }

  // ---------------------------------------------------------------- collection

  /// Marks samples collected, gives each tube a sample number and posts
  /// exactly one charge per order. Orders already collected (by anyone, on
  /// any device) are skipped, so tapping twice never charges twice.
  /// Tests that go in the same container share a tube and a sample number.
  static Future<List<CollectedSample>> collect(Db db, List<Rec> orders, {DateTime? at}) async {
    final now = at ?? DateTime.now();
    final fresh = <Rec>[];
    final seen = <String>{};
    for (final o in orders) {
      if (!seen.add(o.id)) continue;
      final r = await db.get(Col.serviceOrders, o.id);
      if (r != null && r.str('status') == Vals.ordered && r.strOrNull('charge_id') == null) fresh.add(r);
    }
    if (fresh.isEmpty) return const [];
    final already = {
      for (final c in await db.query(Query(Col.charges)
          .eq('source_collection', Col.serviceOrders)
          .isIn('source_id', fresh.map((o) => o.id).toList())
          .take(fresh.length + 10)))
        c.str('source_id'),
    };
    fresh.removeWhere((o) => already.contains(o.id));
    if (fresh.isEmpty) return const [];

    final tests = await testsByCode(db);
    final prices = await pricesByCode(db, fresh.map((o) => o.str('service_code')));
    final patients = await db.byIds(Col.patients, fresh.map((o) => o.strOrNull('patient_id')));

    // One tube per patient and container.
    final groups = <String, List<Rec>>{};
    for (final o in fresh) {
      final t = tests[o.str('service_code')];
      final container = t?.str('container') ?? '';
      groups.putIfAbsent('${o.str('patient_id')}|${container.isEmpty ? o.id : container}', () => []).add(o);
    }

    final ops = <WriteOp>[];
    final samples = <CollectedSample>[];
    for (final group in groups.values) {
      final n = await db.nextSequence(sampleSequence(now));
      final sid = sampleIdFor(now, n);
      final first = group.first;
      final t = tests[first.str('service_code')];
      samples.add(CollectedSample(
        sampleId: sid,
        container: t?.str('container', 'Sample') ?? 'Sample',
        tests: [for (final o in group) _shortName(o.str('name'))],
        patient: patients[first.str('patient_id')],
        at: now,
      ));
      for (final o in group) {
        final price = prices[o.str('service_code')]?.integer('price_paise') ?? 0;
        final chargeId = db.newId();
        ops.add(InsertOp(Col.charges, {
          'patient_id': o.str('patient_id'),
          'encounter_id': o.strOrNull('encounter_id'),
          'service_code': o.strOrNull('service_code'),
          'description': o.str('name'),
          'category': Vals.lab,
          'quantity': 1,
          'unit_price_paise': price,
          'amount_paise': price,
          'status': Vals.pending,
          'source_module': 'lab',
          'source_collection': Col.serviceOrders,
          'source_id': o.id,
          'service_date': now,
          'ordered_by': o.strOrNull('ordered_by'),
        }, id: chargeId));
        ops.add(UpdateOp(
          Col.serviceOrders,
          o.id,
          {'status': Vals.collected, 'sample_id': sid, 'collected_at': now, 'charge_id': chargeId},
          expectedVersion: o.version,
        ));
      }
    }
    await db.batch(ops);
    return samples;
  }

  /// "Complete blood count (CBC)" → "CBC" for tube labels.
  static String _shortName(String name) {
    final m = RegExp(r'\(([^)]+)\)\s*$').firstMatch(name);
    return m != null && m.group(1)!.length <= 14 ? m.group(1)! : name;
  }

  // ---------------------------------------------------------------- results

  /// Saves (or corrects, before verification) the results of a collected
  /// sample. The order moves to 'resulted' with a short summary.
  static Future<Rec> saveResults(
    Db db, {
    required Rec order,
    required Rec? test,
    required Map<String, String> raw,
    String comments = '',
    String? sex,
    String? userId,
    String? userName,
    DateTime? at,
  }) async {
    final cur = await db.get(Col.serviceOrders, order.id) ?? order;
    final status = cur.str('status');
    if (status == Vals.verified) throw ValidationException('This report is verified. Use Amend to change it.');
    if (status != Vals.collected && status != Vals.resulted) {
      throw ValidationException(status == Vals.ordered ? 'Collect the sample before entering results' : 'This order is $status');
    }
    final params = paramsOf(test);
    for (final p in params) {
      final problem = p.problem(raw[p.key] ?? '');
      if (problem != null) throw ValidationException('${p.name}: $problem');
    }
    final values = buildValues(params, raw, sex: sex);
    if (values.isEmpty) throw ValidationException('Enter at least one result');
    final existing = await resultFor(db, order.id);
    if (existing != null && existing.str('status') == ResultStatus.verified) {
      throw ValidationException('This report is verified. Use Amend to change it.');
    }
    final now = at ?? DateTime.now();
    final critical = anyCritical(values);
    final data = <String, Object?>{
      'order_id': order.id,
      'patient_id': cur.str('patient_id'),
      'test_code': cur.str('service_code'),
      'values': values,
      'status': existing?.str('status') == ResultStatus.amended ? ResultStatus.amended : ResultStatus.entered,
      'entered_by': userId ?? db.actor.id,
      'entered_by_name': userName ?? db.actor.name,
      'entered_at': now,
      'comments': comments.trim(),
      'critical': critical,
    };
    final resultId = existing?.id ?? db.newId();
    final out = await db.batch([
      existing == null
          ? InsertOp(LabCol.results, data, id: resultId)
          : UpdateOp(LabCol.results, existing.id, data, expectedVersion: existing.version),
      UpdateOp(Col.serviceOrders, order.id, {
        'status': Vals.resulted,
        'result_summary': resultSummary(params, values),
        'abnormal': anyAbnormal(values),
        'critical': critical,
        'resulted_at': now,
      }, expectedVersion: order.version),
    ]);
    return out.first;
  }

  /// Signs the report. The verifier must be a different person from the
  /// one who entered the results.
  ///
  /// Pass [seen], the result the verifier was looking at, so values changed
  /// in the meantime are never signed unseen.
  static Future<void> verify(Db db,
      {required Rec order, Rec? seen, String? userId, String? userName, DateTime? at}) async {
    if (!db.actor.can(LabPerms.verify)) throw PermissionDeniedException('Only a pathologist can verify reports');
    final result = await resultFor(db, order.id);
    if (result == null) throw ValidationException('There are no results to verify yet');
    if (seen != null && seen.version != result.version) {
      throw ConflictException('These results were changed while you were looking at them. Check them again.');
    }
    if (result.str('status') == ResultStatus.verified) throw ValidationException('This report is already verified');
    final uid = userId ?? db.actor.id;
    if (result.str('entered_by') == uid) {
      throw ValidationException('You entered these results. A different person must verify them.');
    }
    final now = at ?? DateTime.now();
    final name = userName ?? db.actor.name;
    final cur = await db.get(Col.serviceOrders, order.id) ?? order;
    final ops = <WriteOp>[
      UpdateOp(LabCol.results, result.id,
          {'status': ResultStatus.verified, 'verified_by': uid, 'verified_by_name': name, 'verified_at': now},
          expectedVersion: result.version),
      UpdateOp(Col.serviceOrders, order.id, {'status': Vals.verified, 'verified_by': uid, 'verified_at': now},
          expectedVersion: cur.version),
    ];
    // The ordering doctor hears about a critical value straight away.
    final doctor = cur.strOrNull('ordered_by');
    if (result.flag('critical') && doctor != null && await db.get(Col.users, doctor) != null) {
      final patient = await db.get(Col.patients, cur.str('patient_id'));
      final test = (await testsByCode(db))[cur.str('service_code')];
      final crit = criticalText(result.maps('values'), paramsOf(test));
      ops.add(InsertOp(Col.notifications, {
        'user_id': doctor,
        'title': 'Critical result: $crit for ${patient?.str('full_name') ?? 'your patient'}',
        'body': '${cur.str('name')} was verified by $name. Please review and acknowledge it.',
        'severity': 'critical',
        'kind': 'system',
        'route_id': 'lab.order',
        'route_args': {'id': order.id},
        'read': false,
      }));
    }
    await db.batch(ops);
  }

  /// Changes a verified report. The previous version is kept in history and
  /// the new values wait for verification again.
  static Future<void> amend(
    Db db, {
    required Rec order,
    required Rec? test,
    required Map<String, String> raw,
    required String reason,
    String comments = '',
    String? sex,
    String? userId,
    String? userName,
    DateTime? at,
  }) async {
    if (reason.trim().isEmpty) throw ValidationException('Give a reason for the amendment');
    final result = await resultFor(db, order.id);
    if (result == null || result.str('status') != ResultStatus.verified) {
      throw ValidationException('Only verified reports can be amended');
    }
    final params = paramsOf(test);
    for (final p in params) {
      final problem = p.problem(raw[p.key] ?? '');
      if (problem != null) throw ValidationException('${p.name}: $problem');
    }
    final values = buildValues(params, raw, sex: sex);
    if (values.isEmpty) throw ValidationException('Enter at least one result');
    final now = at ?? DateTime.now();
    final name = userName ?? db.actor.name;
    final previous = {
      'values': result.maps('values'),
      'comments': result.str('comments'),
      'status': result.str('status'),
      'entered_by_name': result.str('entered_by_name'),
      'entered_at': result.date('entered_at')?.toIso8601String(),
      'verified_by_name': result.str('verified_by_name'),
      'verified_at': result.date('verified_at')?.toIso8601String(),
      'critical': result.flag('critical'),
      'acknowledged_by_name': result.strOrNull('acknowledged_by_name'),
      'acknowledged_at': result.date('acknowledged_at')?.toIso8601String(),
      'amend_reason': result.strOrNull('amend_reason'),
      'replaced_at': now.toIso8601String(),
      'replaced_by_name': name,
      'reason': reason.trim(),
    };
    final critical = anyCritical(values);
    final cur = await db.get(Col.serviceOrders, order.id) ?? order;
    await db.batch([
      UpdateOp(LabCol.results, result.id, {
        'values': values,
        'comments': comments.trim(),
        'status': ResultStatus.amended,
        'entered_by': userId ?? db.actor.id,
        'entered_by_name': name,
        'entered_at': now,
        'verified_by': null,
        'verified_by_name': null,
        'verified_at': null,
        'critical': critical,
        'acknowledged_by': null,
        'acknowledged_by_name': null,
        'acknowledged_at': null,
        'acknowledge_note': null,
        'amend_reason': reason.trim(),
        'history': [...result.maps('history'), previous],
      }, expectedVersion: result.version),
      UpdateOp(Col.serviceOrders, order.id, {
        'status': Vals.resulted,
        'result_summary': resultSummary(params, values),
        'abnormal': anyAbnormal(values),
        'critical': critical,
        'resulted_at': now,
        'verified_by': null,
        'verified_at': null,
      }, expectedVersion: cur.version),
    ]);
  }

  /// The doctor confirms they have seen a critical result and acted on it.
  static Future<void> acknowledge(Db db, {required Rec result, String note = '', String? userId, String? userName, DateTime? at}) async {
    final cur = await db.get(LabCol.results, result.id) ?? result;
    if (!cur.flag('critical')) throw ValidationException('This result has no critical values');
    if (cur.date('acknowledged_at') != null) throw ValidationException('Already acknowledged by ${cur.str('acknowledged_by_name')}');
    await db.update(LabCol.results, cur.id, {
      'acknowledged_by': userId ?? db.actor.id,
      'acknowledged_by_name': userName ?? db.actor.name,
      'acknowledged_at': at ?? DateTime.now(),
      'acknowledge_note': note.trim().isEmpty ? null : note.trim(),
    }, expectedVersion: cur.version);
  }

  // ---------------------------------------------------------------- history

  /// The most recent earlier verified value of each parameter for a patient
  /// (across tests), for delta checks and trends.
  static Future<Map<String, (Map<String, Object?>, DateTime)>> previousValues(ReadDb db, String patientId,
      {String? excludeOrderId, DateTime? before}) async {
    final rows = await db.query(Query(LabCol.results)
        .eq('patient_id', patientId)
        .eq('status', ResultStatus.verified)
        .sort('verified_at', desc: true)
        .take(60));
    final out = <String, (Map<String, Object?>, DateTime)>{};
    for (final r in rows) {
      if (r.str('order_id') == excludeOrderId) continue;
      final at = r.date('entered_at') ?? r.createdAt;
      if (before != null && !at.isBefore(before)) continue;
      for (final v in r.maps('values')) {
        final k = v['key'] as String? ?? '';
        if (k.isNotEmpty && !out.containsKey(k)) out[k] = (v, at);
      }
    }
    return out;
  }
}

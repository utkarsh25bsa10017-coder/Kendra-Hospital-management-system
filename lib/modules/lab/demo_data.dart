import 'dart:math';

import 'package:kendra_hms/core/core.dart';

import 'lab_rules.dart';
import 'lab_schema.dart';
import 'lab_service.dart';

/// A believable day in the lab: OPD's orders processed, plus a set of cases
/// that put something on every screen — a dengue patient with falling
/// platelets, a diabetic with HbA1c trends, an unacknowledged critical
/// potassium, an overdue STAT, results waiting for the pathologist, and an
/// order nobody collected two days ago.
Future<void> seedDemoLab(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final tests = await LabService.testsByCode(db);
  if (tests.isEmpty) return;
  final users = await db.query(const Query(Col.users).take(200));
  Rec? user(String name) => users.where((u) => u.str('username') == name).firstOrNull;
  final tech = user('lab');
  final path = user('pathology');
  final physician = user('board') ?? user('drkhan');
  final paeds = user('drkhan') ?? physician;
  final ortho = user('drnair') ?? physician;
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(60));
  if (tech == null || path == null || physician == null || patients.length < 20) return;

  final s = _Seeder(db, tests, tech, path, Random(42));
  await s.processExistingOrders();

  final now = DateTime.now();
  DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));
  DateTime daysAgo(int d, {int hour = 10, int minute = 0}) {
    final t = DateTime(now.year, now.month, now.day - d, hour, minute);
    return t.isAfter(now) ? ago(30) : t;
  }

  // Earlier today, but never before midnight and never in the future.
  final today = startOfDay(now);
  DateTime todayAgo(int minutes) {
    var t = ago(minutes);
    if (t.isBefore(today)) t = today.add(const Duration(minutes: 2));
    return t.isAfter(now) ? now : t;
  }

  Rec p(int i) => patients[i % patients.length];
  const h = 60;

  // ---- Dengue: falling platelets over a week, today's CBC on the bench.
  final dengue = p(1);
  await s.flow(dengue, ['LAB-CBC', 'LAB-DENGUE-NS1'],
      doctor: physician,
      orderedAt: daysAgo(6, hour: 10),
      collect: 20, result: 110, verify: 40,
      values: {
        'LAB-CBC': {'wbc': '3,600', 'plt': '1,48,000', 'neut': '46'},
        'LAB-DENGUE-NS1': {'ns1': 'Positive'},
      },
      notes: 'Fever 3 days, myalgia, retro-orbital pain');
  await s.flow(dengue, ['LAB-CBC'],
      doctor: physician, orderedAt: daysAgo(4, hour: 9), collect: 15, result: 90, verify: 35,
      values: {'LAB-CBC': {'wbc': '3,200', 'plt': '96,000', 'hb': '15.2'}});
  await s.flow(dengue, ['LAB-CBC'],
      doctor: physician, orderedAt: daysAgo(2, hour: 9), collect: 15, result: 85, verify: 30,
      values: {'LAB-CBC': {'wbc': '3,900', 'plt': '62,000', 'hb': '15.9'}},
      comments: {'LAB-CBC': 'Platelet count confirmed on smear. Correlate clinically.'});
  await s.flow(dengue, ['LAB-CBC'], doctor: physician, orderedAt: ago(70), collect: 12, priority: Priority.urgent);

  // ---- Diabetic follow-up: HbA1c, FBS and PPBS improving over three months.
  final diabetic = p(2);
  for (final (d, a1c, fbs, pp) in [(88, '8.6', '172', '248'), (58, '8.1', '154', '221'), (30, '7.4', '141', '198'), (3, '7.0', '128', '176')]) {
    await s.flow(diabetic, [if (d != 58) 'LAB-HBA1C', 'LAB-FBS', 'LAB-PPBS'],
        doctor: physician,
        orderedAt: daysAgo(d, hour: 8, minute: 30),
        collect: 10, result: 150, verify: 45,
        values: {
          'LAB-HBA1C': {'hba1c': a1c},
          'LAB-FBS': {'glu_f': fbs},
          'LAB-PPBS': {'glu_pp': pp},
        });
  }
  await s.flow(diabetic, ['LAB-LIPID'],
      doctor: physician, orderedAt: daysAgo(30, hour: 8, minute: 35), collect: 10, result: 160, verify: 50,
      values: {'LAB-LIPID': {'tc': '226', 'tg': '188', 'hdl': '41'}});
  await s.flow(diabetic, ['LAB-FBS', 'LAB-PPBS'], doctor: physician, orderedAt: ago(10));

  // ---- Kidney disease: critical potassium verified yesterday, not acknowledged.
  final renal = p(3);
  await s.flow(renal, ['LAB-KFT', 'LAB-ELECTRO'],
      doctor: physician, orderedAt: daysAgo(5, hour: 11), collect: 15, result: 120, verify: 40,
      values: {
        'LAB-KFT': {'urea': '78', 'creat': '2.86', 'uric': '7.9', 'ca': '8.4'},
        'LAB-ELECTRO': {'na': '134', 'k': '5.6', 'cl': '103'},
      });
  final critAt = ago(22 * h);
  await s.flow(renal, ['LAB-KFT', 'LAB-ELECTRO'],
      doctor: physician, orderedAt: critAt, collect: 15, result: 95, verify: 25, priority: Priority.urgent,
      values: {
        'LAB-KFT': {'urea': '96', 'creat': '3.42', 'uric': '8.6', 'ca': '8.1'},
        'LAB-ELECTRO': {'na': '131', 'k': '6.8', 'cl': '101'},
      },
      comments: {'LAB-ELECTRO': 'Sample not haemolysed. Repeat run confirms potassium 6.8.'},
      notes: 'CKD stage 4, on ACE inhibitor. Weakness since morning.');

  // ---- An older critical haemoglobin that the doctor did acknowledge.
  final anaemic = p(9);
  final old = await s.flow(anaemic, ['LAB-CBC'],
      doctor: paeds!, orderedAt: daysAgo(12, hour: 12), collect: 10, result: 60, verify: 20, priority: Priority.urgent,
      values: {'LAB-CBC': {'hb': '6.4', 'plt': '2,10,000'}});
  final oldResult = await LabService.resultFor(db, old.first.id);
  if (oldResult != null) {
    await LabService.acknowledge(db,
        result: oldResult,
        note: 'Admitted for transfusion',
        userId: paeds.id,
        userName: paeds.str('display_name'),
        at: daysAgo(12, hour: 13, minute: 50));
  }
  await s.flow(anaemic, ['LAB-CBC'],
      doctor: paeds, orderedAt: daysAgo(8, hour: 10), collect: 10, result: 70, verify: 30,
      values: {'LAB-CBC': {'hb': '8.9'}});

  // ---- To collect: an overdue STAT, a fever panel, vitamins, and a 2-day-old order.
  await s.flow(p(4), ['LAB-ELECTRO', 'LAB-RBS'],
      doctor: physician, orderedAt: ago(95), priority: Priority.stat, notes: 'Vomiting, drowsy. Known diabetic.');
  await s.flow(p(12), ['LAB-CBC', 'LAB-MP', 'LAB-DENGUE-NS1', 'LAB-CRP'],
      doctor: physician, orderedAt: ago(18), priority: Priority.urgent, notes: 'High-grade fever with chills, 2 days');
  await s.flow(p(13), ['LAB-VITD', 'LAB-B12'], doctor: ortho!, orderedAt: ago(35));
  await s.flow(p(5), ['LAB-LIPID'], doctor: physician, orderedAt: ago(50 * h));

  // ---- In progress: samples on the bench.
  await s.flow(p(10), ['LAB-URINE-R', 'LAB-WIDAL'], doctor: physician, orderedAt: ago(55), collect: 12);
  await s.flow(p(11), ['LAB-CBC', 'LAB-PTINR', 'LAB-BGRP', 'LAB-HIV', 'LAB-HBSAG', 'LAB-HCV'],
      doctor: ortho, orderedAt: ago(40), collect: 15, priority: Priority.urgent, notes: 'Pre-op: total knee replacement');

  // ---- Entered, waiting for the pathologist (one for more than 4 hours).
  await s.flow(p(6), ['LAB-LFT', 'LAB-CRP'],
      doctor: physician, orderedAt: ago(7 * h), collect: 20, result: 100,
      values: {
        'LAB-LFT': {'tbil': '2.84', 'dbil': '1.62', 'ast': '86', 'alt': '112', 'alp': '168'},
        'LAB-CRP': {'crp': '34.5'},
      });
  await s.flow(p(7), ['LAB-CBC', 'LAB-ESR'],
      doctor: physician, orderedAt: ago(150), collect: 15, result: 85,
      values: {
        'LAB-CBC': {'hb': '9.8', 'wbc': '14,200', 'neut': '84'},
        'LAB-ESR': {'esr': '38'},
      });
  await s.flow(p(8), ['LAB-TFT'],
      doctor: physician, orderedAt: ago(5 * h + 20), collect: 25, result: 270,
      values: {'LAB-TFT': {'tsh': '7.84', 't4': '4.6'}});

  // ---- Reported today.
  Future<void> doneToday(Rec patient, List<String> codes, int verifiedAgo, Rec doctor,
      {Map<String, Map<String, String>> values = const {}, String priority = Priority.routine}) async {
    final verifiedAt = todayAgo(verifiedAgo);
    final total = s.rnd.nextInt(60) + (priority == Priority.routine ? 110 : 45);
    await s.flow(patient, codes,
        doctor: doctor,
        orderedAt: verifiedAt.subtract(Duration(minutes: total)),
        collect: 10 + s.rnd.nextInt(10),
        result: total - 50,
        verify: 25 + s.rnd.nextInt(10),
        values: values,
        priority: priority);
  }

  await doneToday(p(14), ['LAB-CBC', 'LAB-ESR'], 340, physician);
  await doneToday(p(15), ['LAB-LIPID', 'LAB-FBS'], 300, physician,
      values: {'LAB-LIPID': {'tc': '236', 'tg': '212', 'hdl': '37'}, 'LAB-FBS': {'glu_f': '108'}});
  await doneToday(p(16), ['LAB-HBA1C', 'LAB-TSH'], 260, physician, values: {'LAB-HBA1C': {'hba1c': '7.8'}, 'LAB-TSH': {'tsh': '6.92'}});
  await doneToday(p(17), ['LAB-URINE-R'], 220, physician,
      values: {'LAB-URINE-R': {'pus': '12', 'protein': 'Trace', 'appearance': 'Slightly turbid'}});
  await doneToday(p(19), ['LAB-MP', 'LAB-DENGUE-NS1', 'LAB-RBS'], 180, physician, priority: Priority.urgent);
  await doneToday(p(20), ['LAB-KFT'], 140, physician);
  await doneToday(p(18), ['LAB-CBC'], 95, paeds, values: {'LAB-CBC': {'eos': '9', 'hb': '11.1'}});
  await doneToday(p(21), ['LAB-HIV', 'LAB-HBSAG'], 60, ortho);

  // ---- The last few weeks, for history, trends and turnaround figures.
  const routine = [
    ['LAB-CBC'], ['LAB-FBS', 'LAB-PPBS'], ['LAB-LFT'], ['LAB-KFT'], ['LAB-LIPID'], ['LAB-TSH'], ['LAB-URINE-R'],
    ['LAB-CBC', 'LAB-CRP'], ['LAB-RBS'], ['LAB-TFT'], ['LAB-VITD'], ['LAB-WIDAL'], ['LAB-CBC', 'LAB-ESR'], ['LAB-HBA1C'],
  ];
  final docs = [physician, physician, ortho, paeds];
  for (var i = 0; i < 26; i++) {
    final d = 1 + s.rnd.nextInt(28);
    final patient = p(22 + s.rnd.nextInt(18));
    final codes = routine[s.rnd.nextInt(routine.length)];
    final abnormalKey = s.rnd.nextInt(4) == 0;
    await s.flow(patient, codes,
        doctor: docs[i % docs.length],
        orderedAt: daysAgo(d, hour: 8 + s.rnd.nextInt(8), minute: s.rnd.nextInt(60)),
        collect: 10 + s.rnd.nextInt(25),
        result: 60 + s.rnd.nextInt(150),
        verify: 15 + s.rnd.nextInt(70),
        mildAbnormal: abnormalKey);
  }
}

class _Seeder {
  _Seeder(this.db, this.tests, this.tech, this.path, this.rnd);
  final Db db;
  final Map<String, Rec> tests;
  final Rec tech;
  final Rec path;
  final Random rnd;

  /// Orders the OPD demo placed: older ones were completed, today's are
  /// spread across the worklist.
  Future<void> processExistingOrders() async {
    final orders = await db.query(LabService.labOrders().eq('status', Vals.ordered).sort('ordered_at').take(300));
    final now = DateTime.now();
    final today = startOfDay(now);
    DateTime notAfterNow(DateTime t) => t.isAfter(now) ? now.subtract(const Duration(minutes: 1)) : t;
    var i = 0;
    for (final o in orders) {
      final orderedAt = o.date('ordered_at') ?? now;
      final test = tests[o.str('service_code')];
      final stage = orderedAt.isBefore(today) ? 3 : (i++ % 4);
      if (stage == 0) continue;
      final collectedAt = notAfterNow(orderedAt.add(Duration(minutes: 8 + rnd.nextInt(25))));
      await LabService.collect(db, [o], at: collectedAt);
      if (stage == 1 || test == null) continue;
      final resultedAt = notAfterNow(collectedAt.add(Duration(minutes: 40 + rnd.nextInt(90))));
      if (!await _enter(o.id, resultedAt, mildAbnormal: rnd.nextInt(4) == 0)) continue;
      if (stage == 2) continue;
      await _verify(o.id, notAfterNow(resultedAt.add(Duration(minutes: 15 + rnd.nextInt(60)))));
    }
  }

  /// Places [codes] for [patient] at [orderedAt], then (optionally) collects
  /// after [collect] minutes, enters results [result] minutes after that and
  /// verifies [verify] minutes later.
  Future<List<Rec>> flow(
    Rec patient,
    List<String> codes, {
    required Rec doctor,
    required DateTime orderedAt,
    int? collect,
    int? result,
    int? verify,
    String priority = Priority.routine,
    Map<String, Map<String, String>> values = const {},
    Map<String, String> comments = const {},
    String notes = '',
    bool mildAbnormal = false,
  }) async {
    final list = [for (final c in codes) ?tests[c]];
    if (list.isEmpty) return const [];
    final orders = await LabService.createOrders(db,
        patientId: patient.id, tests: list, priority: priority, orderedBy: doctor.id, at: orderedAt, notes: notes);
    if (collect == null) return orders;
    final collectedAt = orderedAt.add(Duration(minutes: collect));
    await LabService.collect(db, orders, at: collectedAt);
    if (result == null) return orders;
    final resultedAt = collectedAt.add(Duration(minutes: result));
    for (final o in orders) {
      final code = o.str('service_code');
      await _enter(o.id, resultedAt, set: values[code] ?? const {}, comments: comments[code] ?? '', mildAbnormal: mildAbnormal);
    }
    if (verify == null) return orders;
    for (final o in orders) {
      await _verify(o.id, resultedAt.add(Duration(minutes: verify)));
    }
    return orders;
  }

  Future<bool> _enter(String orderId, DateTime at,
      {Map<String, String> set = const {}, String comments = '', bool mildAbnormal = false}) async {
    final o = await db.get(Col.serviceOrders, orderId);
    if (o == null) return false;
    final test = tests[o.str('service_code')];
    final params = paramsOf(test);
    if (params.isEmpty) return false;
    final patient = await db.get(Col.patients, o.str('patient_id'));
    final sex = patient?.strOrNull('gender');
    final raw = _normalValues(params, sex)..addAll(set);
    if (mildAbnormal && set.isEmpty) _nudge(params, raw, sex);
    _derive(o.str('service_code'), params, raw, set.keys.toSet());
    await LabService.saveResults(db,
        order: o,
        test: test,
        raw: raw,
        comments: comments,
        sex: sex,
        userId: tech.id,
        userName: tech.str('display_name'),
        at: at);
    return true;
  }

  Future<void> _verify(String orderId, DateTime at) async {
    final o = await db.get(Col.serviceOrders, orderId);
    if (o == null || o.str('status') != Vals.resulted) return;
    await LabService.verify(db, order: o, userId: path.id, userName: path.str('display_name'), at: at);
  }

  Map<String, String> _normalValues(List<LabParam> params, String? sex) {
    final out = <String, String>{};
    for (final p in params) {
      switch (p.kind) {
        case LabParam.numeric:
          final (lo, hi) = p.rangeFor(sex);
          double v;
          if (lo != null && hi != null) {
            v = lo + (hi - lo) * (0.25 + 0.5 * rnd.nextDouble());
          } else if (hi != null) {
            v = hi * (0.6 + 0.3 * rnd.nextDouble());
          } else if (lo != null) {
            v = lo * (1.15 + 0.4 * rnd.nextDouble());
          } else {
            continue;
          }
          out[p.key] = p.format(_tidy(v, hi));
        case LabParam.choice:
          final normal = p.normalChoices;
          if (normal.isNotEmpty) {
            out[p.key] = normal.first;
          } else if (p.key == 'abo') {
            out[p.key] = const ['B', 'O', 'O', 'A', 'B', 'AB'][rnd.nextInt(6)];
          } else if (p.choices.isNotEmpty) {
            out[p.key] = rnd.nextInt(16) == 0 && p.choices.length > 1 ? p.choices[1] : p.choices.first;
          }
        default:
          out[p.key] = p.refText.isEmpty ? 'Nil' : p.refText;
      }
    }
    return out;
  }

  /// Counts are reported rounded: WBC to the nearest 100, platelets to 1000.
  static double _tidy(double v, double? hi) {
    if ((hi ?? 0) >= 100000) return (v / 1000).roundToDouble() * 1000;
    if ((hi ?? 0) >= 10000) return (v / 100).roundToDouble() * 100;
    return v;
  }

  /// Pushes one value just outside its range, as real reports often are.
  void _nudge(List<LabParam> params, Map<String, String> raw, String? sex) {
    final candidates = params.where((p) => p.isNumeric && p.rangeFor(sex).$2 != null).toList();
    if (candidates.isEmpty) return;
    final p = candidates[rnd.nextInt(candidates.length)];
    final hi = p.rangeFor(sex).$2!;
    var v = hi * (1.08 + 0.15 * rnd.nextDouble());
    final crit = p.criticalHigh;
    if (crit != null && v >= crit) v = hi + (crit - hi) * 0.4;
    raw[p.key] = p.format(_tidy(v, hi));
  }

  /// Keeps calculated values consistent with the measured ones.
  void _derive(String code, List<LabParam> params, Map<String, String> raw, Set<String> given) {
    final byKey = {for (final p in params) p.key: p};
    double? v(String k) => byKey[k]?.parse(raw[k] ?? '');
    void put(String k, double x) {
      if (!given.contains(k) && byKey[k] != null) raw[k] = byKey[k]!.format(x);
    }

    switch (code) {
      case 'LAB-CBC':
        final hb = v('hb');
        if (hb == null) break;
        final mch = hb < 11 ? 23.5 + rnd.nextDouble() : 28.5 + rnd.nextDouble() * 2;
        put('pcv', hb * (2.95 + rnd.nextDouble() * 0.1));
        put('rbc', hb * 10 / mch);
        final pcv = v('pcv')!;
        final rbc = v('rbc')!;
        put('mcv', pcv * 10 / rbc);
        put('mch', hb * 10 / rbc);
        put('mchc', hb * 100 / pcv);
        final others = ['lymph', 'mono', 'eos', 'baso'];
        if (given.contains('neut')) {
          final rest = (v('mono') ?? 0) + (v('eos') ?? 0) + (v('baso') ?? 0);
          put('lymph', 100 - v('neut')! - rest);
        } else {
          put('neut', 100 - others.fold<double>(0, (a, k) => a + (v(k) ?? 0)));
        }
      case 'LAB-LFT':
        put('ibil', max(0.1, (v('tbil') ?? 0.8) - (v('dbil') ?? 0.2)));
        put('glob', (v('tp') ?? 7.2) - (v('alb') ?? 4.3));
        put('ag', (v('alb') ?? 4.3) / max(0.5, v('glob') ?? 2.9));
      case 'LAB-LIPID':
        put('tc', 150 + rnd.nextDouble() * 40);
        put('vldl', (v('tg') ?? 120) / 5);
        put('ldl', (v('tc') ?? 170) - (v('hdl') ?? 50) - (v('vldl') ?? 24));
        put('tc_hdl', (v('tc') ?? 170) / max(20, v('hdl') ?? 50));
      case 'LAB-HBA1C':
        put('eag', 28.7 * (v('hba1c') ?? 5.4) - 46.7);
      case 'LAB-PTINR':
        put('inr', (v('pt') ?? 12.3) / 12.3);
    }
  }
}

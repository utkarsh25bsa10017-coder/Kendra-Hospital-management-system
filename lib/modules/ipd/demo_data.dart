import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:kendra_hms/core/core.dart';

import 'bed_charging.dart';
import 'ipd_schema.dart';
import 'ipd_service.dart';

/// One stay in the demo hospital. Times are worked out relative to now.
class _Stay {
  _Stay({
    required this.diagnosis,
    required this.reason,
    required this.doctor,
    required this.admitAt,
    this.bed,
    this.wardKind = 'general',
    this.child = false,
    this.expectedDays,
    this.progress = '',
    this.requestAt,
    this.dischargeAt,
    this.dischargeType = 'normal',
    this.readyAfter = const Duration(minutes: 90),
    this.transferAt,
    this.transferTo,
    this.transferReason = '',
  });

  final String diagnosis;
  final String reason;
  final String doctor; // demo username
  final DateTime admitAt;
  final String? bed; // fixed bed label, or null to take a free one in [wardKind]
  final String wardKind;
  final bool child;
  final int? expectedDays;
  final String progress;
  final DateTime? requestAt;
  final DateTime? dischargeAt;
  final String dischargeType;

  /// Cleaning time after discharge; null leaves the bed in cleaning.
  final Duration? readyAfter;
  final DateTime? transferAt;
  final String? transferTo;
  final String transferReason;
  Rec? patient;
  Rec? admission;
}

/// ~60% of beds occupied with stays 1–8 days old, one transfer, one
/// discharge waiting six hours, two beds in cleaning, one in maintenance and
/// about twenty discharges over the last month. Bed-day charges are posted
/// by the real posting routine.
Future<void> seedDemoIpd(ModuleContext ctx) async {
  final db = ctx.systemDb;
  await IpdService.seedDefaults(db);
  final now = DateTime.now();
  final rnd = Random(26);
  DateTime day(int daysAgo, int hour, [int minute = 0]) => DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  final wards = await db.query(const Query(IpdCol.wards).eq('active', true).sort('created_at').take(50));
  final beds = await db.query(const Query(IpdCol.beds).eq('active', true).take(500));
  if (wards.isEmpty || beds.isEmpty) return;
  final wardKind = {for (final w in wards) w.id: w.str('kind')};
  final bedByLabel = {for (final b in beds) b.str('label'): b};

  final staff = await db.query(const Query(Col.users).eq('is_clinician', true).take(50));
  if (staff.isEmpty) return;
  final doctors = {for (final u in staff) u.str('username'): u};
  Rec doctor(String username) => doctors[username] ?? staff.first;

  final everyone = await db.query(const Query(Col.patients).sort('uhid').take(200));
  // The patients module registers its first patient twice on purpose; leave the copy out.
  final people = everyone.length > 1 ? everyone.sublist(0, everyone.length - 1) : everyone;
  if (people.length < 4) return;
  bool isChild(Rec p) {
    final dob = p.date('dob');
    return dob != null && ageInYears(dob) < 14;
  }

  final used = <String>{};
  Rec takePatient({bool child = false}) {
    final pick = people.firstWhere((p) => !used.contains(p.id) && isChild(p) == child,
        orElse: () => people.firstWhere((p) => !used.contains(p.id), orElse: () => people[rnd.nextInt(people.length)]));
    used.add(pick.id);
    return pick;
  }

  // ------------------------------------------------------------ current stays (18 beds)
  final current = <_Stay>[
    _Stay(bed: 'G-01', diagnosis: 'Dengue fever with thrombocytopenia', reason: 'Platelets 48,000, vomiting, unable to take orally',
        doctor: 'board', admitAt: day(3, 11, 20), expectedDays: 5,
        progress: 'Afebrile since morning. Platelets 62,000 (rising). Continue oral fluids, repeat CBC tomorrow.'),
    _Stay(bed: 'G-02', diagnosis: 'Acute gastroenteritis with dehydration', reason: 'Loose motions 10 episodes, moderate dehydration',
        doctor: 'board', admitAt: day(1, 22, 40), expectedDays: 2,
        progress: 'Stools reduced to 2 since night. Tolerating ORS. Plan to stop IV fluids by evening.'),
    _Stay(bed: 'G-03', diagnosis: 'Fracture shaft of femur (right) — ORIF done', reason: 'Road traffic accident, closed fracture',
        doctor: 'drnair', admitAt: day(8, 15, 10), expectedDays: 7,
        progress: 'Post-op day 6. Wound healthy, drain removed. Physiotherapy for non-weight-bearing walking.'),
    _Stay(bed: 'G-06', diagnosis: 'Community-acquired pneumonia', reason: 'Fever, cough, SpO2 91% on room air',
        doctor: 'board', admitAt: day(4, 9, 45), expectedDays: 6,
        progress: 'Off oxygen since last night, SpO2 95%. Continue IV ceftriaxone, switch to oral on day 5.'),
    _Stay(bed: 'G-07', diagnosis: 'Cellulitis of left leg', reason: 'Spreading redness and swelling, fever',
        doctor: 'board', admitAt: day(5, 13, 30), expectedDays: 5, requestAt: now.subtract(const Duration(hours: 6)),
        progress: 'Redness much reduced, afebrile 48 h. Fit for discharge on oral antibiotics.'),
    _Stay(bed: 'G-08', diagnosis: 'Typhoid fever', reason: 'Fever for 9 days, Widal positive',
        doctor: 'board', admitAt: day(2, 17, 5), expectedDays: 5,
        progress: 'Fever spikes reducing. Continue IV ceftriaxone. Soft diet.'),
    _Stay(bed: 'G-09', child: true, diagnosis: 'Simple febrile seizure', reason: 'One generalised seizure at home with fever 39.4 °C',
        doctor: 'drkhan', admitAt: now.subtract(const Duration(hours: 3)), expectedDays: 2,
        progress: 'No further seizures. Paracetamol for fever. Counsel parents before discharge.'),
    _Stay(bed: 'S-01', diagnosis: 'Laparoscopic cholecystectomy — post-op', reason: 'Symptomatic gallstones, elective surgery',
        doctor: 'board', admitAt: day(2, 8, 0), expectedDays: 3,
        progress: 'Post-op day 1. Pain controlled, tolerating liquids. Drain minimal. Mobilise.'),
    _Stay(bed: 'S-04', diagnosis: 'Malaria (P. vivax)', reason: 'High-grade fever with chills, smear positive',
        doctor: 'board', admitAt: day(3, 19, 25), expectedDays: 4,
        progress: 'Fever settled after artesunate. Start primaquine after G6PD report.'),
    _Stay(bed: 'S-05', diagnosis: 'Total knee replacement (left)', reason: 'Severe osteoarthritis, elective surgery',
        doctor: 'drnair', admitAt: day(4, 7, 30), expectedDays: 5,
        progress: 'Post-op day 3. Knee flexion 80°. Walking with walker. Continue DVT prophylaxis.'),
    _Stay(bed: 'S-02', diagnosis: 'Acute pancreatitis', reason: 'Severe epigastric pain, lipase 1,240',
        doctor: 'board', admitAt: day(5, 10, 15), expectedDays: 7,
        transferAt: day(2, 11, 20), transferTo: 'P-02', transferReason: 'Upgrade to private room at family request',
        progress: 'Pain much better, started on clear liquids. Lipase falling.'),
    _Stay(bed: 'S-02', child: true, diagnosis: 'Acute bronchiolitis', reason: 'Wheeze and fast breathing, poor feeding',
        doctor: 'drkhan', admitAt: day(1, 16, 10), expectedDays: 3,
        progress: 'Respiratory rate settling. Nebulisation 6-hourly. Feeding better.'),
    _Stay(bed: 'P-04', diagnosis: 'Hypertensive urgency', reason: 'BP 210/120 with headache',
        doctor: 'board', admitAt: day(2, 21, 50), expectedDays: 3,
        progress: 'BP 150/94 on oral medicines. Renal function normal. Plan discharge tomorrow.'),
    _Stay(bed: 'P-05', diagnosis: 'Fracture neck of femur (left) — hemiarthroplasty', reason: 'Fall at home, unable to bear weight',
        doctor: 'drnair', admitAt: day(6, 12, 40), expectedDays: 8,
        progress: 'Post-op day 4. Sitting out of bed. Wound clean. Physiotherapy twice daily.'),
    _Stay(bed: 'ICU-01', diagnosis: 'Diabetic ketoacidosis', reason: 'Vomiting, drowsy, blood sugar 486, ketones positive',
        doctor: 'board', admitAt: day(6, 3, 15), expectedDays: 4,
        progress: 'Acidosis resolved. Shifted to basal-bolus insulin. Diabetes educator to counsel.'),
    _Stay(bed: 'ICU-02', diagnosis: 'COPD exacerbation on NIV', reason: 'Breathlessness, CO2 retention',
        doctor: 'board', admitAt: day(3, 4, 40), expectedDays: 6,
        progress: 'NIV weaned to nights only. ABG improving. Continue nebulisation and steroids.'),
    _Stay(bed: 'ICU-04', diagnosis: 'Severe dengue with shock', reason: 'Hypotension, platelets 18,000',
        doctor: 'board', admitAt: day(2, 23, 30), expectedDays: 5,
        progress: 'Off inotropes since morning. Urine output adequate. Platelets 34,000.'),
    _Stay(bed: 'ICU-05', diagnosis: 'Acute coronary syndrome — post thrombolysis', reason: 'Chest pain, ST elevation in anterior leads',
        doctor: 'board', admitAt: day(4, 6, 5), expectedDays: 5,
        progress: 'Pain-free. Echo: EF 45%. Referred for angiography, plan step-down tomorrow.'),
  ];
  for (final s in current) {
    s.patient = takePatient(child: s.child);
  }
  final dkaPatient = current.firstWhere((s) => s.bed == 'ICU-01').patient!;

  // ------------------------------------------------------------ discharges (last 30 days)
  const generalDx = [
    ('Viral fever with thrombocytopenia', 'board'),
    ('Acute gastroenteritis', 'drkhan'),
    ('Urinary tract infection', 'board'),
    ('Lower respiratory tract infection', 'drkhan'),
    ('Renal colic', 'board'),
    ('Acute asthma', 'board'),
  ];
  const semiDx = [('Laparoscopic appendicectomy', 'board'), ('Dengue fever', 'board'), ('Fracture distal radius — K-wiring', 'drnair')];
  const privateDx = [('Total hip replacement (right)', 'drnair'), ('Chest pain — evaluation', 'board'), ('Laparoscopic hernia repair', 'board')];
  const icuDx = [('Organophosphate poisoning', 'board'), ('Severe sepsis (urinary source)', 'board'), ('Snake bite (viperine) on ASV', 'board')];
  const kinds = ['general', 'semi_private', 'general', 'private', 'icu', 'general', 'semi_private', 'general', 'private'];
  const stayDays = [3, 2, 4, 1, 5, 2, 3, 0, 4, 2, 3, 6, 2, 1, 3, 4, 2, 3];
  final past = <_Stay>[];
  for (var k = 0; k < stayDays.length; k++) {
    final kind = kinds[k % kinds.length];
    final list = switch (kind) { 'semi_private' => semiDx, 'private' => privateDx, 'icu' => icuDx, _ => generalDx };
    final (baseDx, doc) = list[k % list.length];
    final daysAgo = 30 - (k * 1.5).round();
    final stay = stayDays[k];
    // A same-day (day care) stay goes home the afternoon it came in.
    final admitAt = stay == 0 ? day(daysAgo, 8, 30) : day(daysAgo, 9 + rnd.nextInt(10), rnd.nextInt(4) * 15);
    var dischargeAt = stay == 0
        ? day(daysAgo, 15, 0)
        : DateTime(admitAt.year, admitAt.month, admitAt.day + stay, 11 + rnd.nextInt(3), rnd.nextInt(4) * 15);
    if (dischargeAt.isAfter(now.subtract(const Duration(days: 1)))) dischargeAt = now.subtract(const Duration(days: 1));
    // k == 0 is the patient now in ICU with DKA, readmitted within the month.
    final dx = k == 0 ? 'Diabetic foot ulcer (right) — debridement' : (stay == 0 ? 'Day care: blood transfusion' : baseDx);
    final type = k == 5 ? 'lama' : (k == 9 ? 'referred' : 'normal');
    past.add(_Stay(
      wardKind: kind,
      diagnosis: dx,
      reason: k == 0 ? 'Infected ulcer, uncontrolled sugars' : (stay == 0 ? 'Haemoglobin 6.8 g/dL' : 'Admitted from OPD'),
      doctor: doc,
      admitAt: admitAt,
      requestAt: dischargeAt.subtract(Duration(minutes: 60 + rnd.nextInt(90))),
      dischargeAt: dischargeAt,
      dischargeType: type,
    ));
  }
  // Two discharges this morning: their beds are still being cleaned.
  past.add(_Stay(bed: 'G-05', diagnosis: 'Acute febrile illness', reason: 'Fever with body ache', doctor: 'board',
      admitAt: day(3, 13, 0), requestAt: now.subtract(const Duration(hours: 7)),
      dischargeAt: now.subtract(const Duration(hours: 5)), readyAfter: null));
  past.add(_Stay(bed: 'S-03', diagnosis: 'Laparoscopic appendicectomy', reason: 'Acute appendicitis', doctor: 'board',
      admitAt: day(2, 9, 30), requestAt: now.subtract(const Duration(hours: 3)),
      dischargeAt: now.subtract(const Duration(hours: 1)), readyAfter: null));
  for (final (i, s) in past.indexed) {
    s.patient = i == 0 ? dkaPatient : takePatient(child: s.doctor == 'drkhan');
  }

  // Beds that discharged patients may use: those that end up free today.
  final fixed = {for (final s in [...current, ...past]) ?s.bed, for (final s in current) ?s.transferTo};
  final pool = beds.where((b) => !fixed.contains(b.str('label')) && b.str('label') != 'G-10').toList()
    ..sort((a, b) => IpdService.compareLabels(a.str('label'), b.str('label')));

  // ------------------------------------------------------------ replay events in time order
  final events = <(DateTime, int, Future<void> Function())>[];
  var seq = 0;
  void on(DateTime at, Future<void> Function() run) => events.add((at, seq++, run));

  Future<Rec> freshBed(String id) async => (await db.get(IpdCol.beds, id))!;

  for (final s in [...past, ...current]) {
    on(s.admitAt, () async {
      Rec? bed;
      if (s.bed != null) {
        bed = bedByLabel[s.bed];
      } else {
        final free = <Rec>[];
        for (final b in pool) {
          final f = await freshBed(b.id);
          if (IpdService.isFree(f)) free.add(f);
        }
        bed = free.where((b) => wardKind[b.str('ward_id')] == s.wardKind).firstOrNull ?? free.firstOrNull;
      }
      if (bed == null) return;
      final doc = doctor(s.doctor);
      s.admission = await IpdService.admit(db,
          patientId: s.patient!.id,
          bedId: bed.id,
          attendingDoctorId: doc.id,
          diagnosis: s.diagnosis,
          reason: s.reason,
          expectedStayDays: s.expectedDays ?? (s.dischargeAt == null ? null : s.dischargeAt!.difference(s.admitAt).inDays + 1),
          at: s.admitAt);
    });
    if (s.transferAt != null) {
      on(s.transferAt!, () async {
        final adm = s.admission;
        final to = bedByLabel[s.transferTo];
        if (adm == null || to == null) return;
        final fromId = adm.str('bed_id');
        s.admission = await IpdService.transfer(db, adm, toBedId: to.id, reason: s.transferReason, byName: 'Mary Thomas', at: s.transferAt);
        s.admission = await db.get(IpdCol.admissions, adm.id);
        await IpdService.markReady(db, await freshBed(fromId), at: s.transferAt!.add(const Duration(hours: 2)));
      });
    }
    if (s.requestAt != null) {
      on(s.requestAt!, () async {
        final adm = s.admission == null ? null : await db.get(IpdCol.admissions, s.admission!.id);
        if (adm == null) return;
        s.admission = await IpdService.requestDischarge(db, adm,
            type: s.dischargeType,
            summary: _summary(s),
            advice: _advice(s),
            at: s.requestAt);
      });
    }
    if (s.dischargeAt != null) {
      on(s.dischargeAt!, () async {
        final adm = s.admission;
        if (adm == null) return;
        final bedId = adm.str('bed_id');
        await IpdService.completeDischarge(db, adm, at: s.dischargeAt);
        if (s.readyAfter != null) await IpdService.markReady(db, await freshBed(bedId), at: s.dischargeAt!.add(s.readyAfter!));
      });
    }
  }
  events.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  for (final (_, _, run) in events) {
    try {
      await run();
    } catch (e) {
      // Demo data should never stop the demo from opening.
      debugPrint('ipd demo: $e');
    }
  }

  // G-10: bed rail broken, waiting for the carpenter.
  final g10 = bedByLabel['G-10'];
  if (g10 != null) await IpdService.setMaintenance(db, await freshBed(g10.id), true, at: day(2, 15, 0));

  // ------------------------------------------------------------ bedside notes
  final ops = <WriteOp>[];
  for (final s in current) {
    final adm = s.admission;
    if (adm == null) continue;
    final icu = s.bed!.startsWith('ICU');
    final start = s.admitAt;
    final doc = doctor(s.doctor).str('display_name');
    void note(DateTime at, String kind, String text, String by, [Map<String, Object?>? vitals]) {
      if (at.isAfter(now)) return;
      ops.add(InsertOp(IpdCol.notes, {
        'admission_id': adm.id,
        'patient_id': adm.str('patient_id'),
        'kind': kind,
        'text': text,
        'vitals': vitals,
        'by_name': by,
        'recorded_at': at,
      }));
    }

    Map<String, Object?> vitals({bool unwell = false}) => {
          'bp_sys': unwell ? 100 + rnd.nextInt(20) : 112 + rnd.nextInt(24),
          'bp_dia': unwell ? 60 + rnd.nextInt(10) : 70 + rnd.nextInt(14),
          'pulse': unwell ? 104 + rnd.nextInt(16) : 74 + rnd.nextInt(18),
          'temp_c': ((unwell ? 378 + rnd.nextInt(10) : 366 + rnd.nextInt(8)) / 10),
          'spo2': unwell ? 92 + rnd.nextInt(3) : 96 + rnd.nextInt(4),
          'rr': unwell ? 22 + rnd.nextInt(5) : 16 + rnd.nextInt(4),
          if (s.diagnosis.contains('ketoacidosis') || rnd.nextInt(3) == 0) 'grbs': 110 + rnd.nextInt(90),
        };

    note(start.add(const Duration(minutes: 25)), 'nursing',
        'Received in ${s.bed}. ${s.reason}. Oriented, IV line secured, admission orders noted. Bystander informed about visiting hours.',
        'Mary Thomas', vitals(unwell: true));
    final days = now.difference(start).inDays;
    // Morning vitals for the last three days, up to today.
    for (var k = 2; k >= 0; k--) {
      final morning = DateTime(now.year, now.month, now.day - k, 6, 10 + rnd.nextInt(30));
      if (morning.isBefore(start.add(const Duration(hours: 2)))) continue;
      note(morning, 'vitals', icu ? 'Hourly charting continued overnight.' : '', 'Mary Thomas', vitals(unwell: icu && k == 2 && days < 4));
    }
    if (days >= 1) {
      final handover = DateTime(now.year, now.month, now.day, 8, 0);
      note(handover.isAfter(start) ? handover : now.subtract(const Duration(minutes: 30)), 'handover',
          icu ? 'Night handover: stable, on monitor. Watch urine output.' : 'Night handover: slept well, no fresh complaints.',
          'Mary Thomas');
    }
    final round = DateTime(now.year, now.month, now.day, 10, 30);
    note(round.isAfter(start) && round.isBefore(now) ? round : now.subtract(const Duration(minutes: 20)), 'progress', s.progress, doc);
  }
  await db.batch(ops);

  // ------------------------------------------------------------ charges
  await BedCharging.postAll(db, now: now);
  // Billing cancelled one bed charge while correcting a bill and never
  // raised it again: the unbilled bed-days agent has something to find.
  final victim = past.length > 3 ? past[3].admission : null;
  if (victim != null) {
    final c = await db.first(Query(Col.charges)
        .eq('source_collection', IpdCol.admissions)
        .startsWith('source_id', '${victim.id}:')
        .eq('category', Vals.bed)
        .sort('service_date', desc: true));
    if (c != null) {
      await db.update(Col.charges, c.id, {'status': Vals.cancelled, 'cancel_reason': 'Bill corrected — to be raised again'});
    }
  }
}

String _summary(_Stay s) =>
    'Admitted with ${s.diagnosis.toLowerCase()} (${s.reason.toLowerCase()}). Treated as per protocol; '
    'responded well. Afebrile and haemodynamically stable at discharge.';

String _advice(_Stay s) => s.dischargeType == 'lama'
    ? 'Leaving against medical advice. Risks explained to patient and relatives.'
    : 'Continue medicines as prescribed. Review in OPD after 7 days, earlier if fever, pain or bleeding.';

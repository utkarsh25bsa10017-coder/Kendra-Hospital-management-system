import 'package:kendra_hms/core/core.dart';

import 'bed_charging.dart';
import 'ipd_schema.dart';

/// Admission, transfer and discharge rules shared by the screens and the
/// demo seeder. Each change is one all-or-nothing batch.
abstract final class IpdService {
  /// Next admission number, e.g. IP-26-00042. Numbers never repeat.
  static Future<String> nextNumber(Db db, [DateTime? at]) async {
    final n = await db.nextSequence('admission');
    final yy = ((at ?? DateTime.now()).year % 100).toString().padLeft(2, '0');
    return 'IP-$yy-${n.toString().padLeft(5, '0')}';
  }

  static Future<Rec?> currentAdmission(ReadDb db, String patientId) =>
      db.first(Query(IpdCol.admissions).eq('patient_id', patientId).isIn('status', IpdVals.current));

  static bool isUsable(Rec bed) => !bed.archived && bed['active'] != false;
  static bool isFree(Rec bed) =>
      isUsable(bed) && (bed.str('status', IpdVals.available) == IpdVals.available || bed.str('status') == IpdVals.reserved);

  static Future<Rec> _freeBed(Db db, String bedId) async {
    final bed = await db.get(IpdCol.beds, bedId);
    if (bed == null || !isUsable(bed)) throw ValidationException('That bed is no longer in use. Choose another bed.');
    if (!isFree(bed)) {
      throw ValidationException('Bed ${bed.str('label')} is ${bedStatusLabel(bed.str('status')).toLowerCase()}. Choose a free bed.');
    }
    return bed;
  }

  static Future<List<Rec>> _guardBed(Future<List<Rec>> Function() write, Rec bed) async {
    try {
      return await write();
    } on ConflictException {
      throw ValidationException('Bed ${bed.str('label')} was just taken by someone else. Choose another bed.');
    }
  }

  /// Admits a patient: creates the IPD encounter and the admission and marks
  /// the bed occupied, in one batch.
  static Future<Rec> admit(
    Db db, {
    required String patientId,
    required String bedId,
    required String attendingDoctorId,
    String? admittingDoctorId,
    String diagnosis = '',
    String reason = '',
    int? expectedStayDays,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    final patient = await db.get(Col.patients, patientId);
    if (patient == null) throw ValidationException('Patient not found');
    final bed = await _freeBed(db, bedId);
    final existing = await currentAdmission(db, patientId);
    if (existing != null) {
      throw ValidationException('${patient.str('full_name')} is already admitted (${existing.str('number')})');
    }
    final doctor = await db.get(Col.users, attendingDoctorId);
    final number = await nextNumber(db, now);
    final encounterId = db.newId();
    final admissionId = db.newId();
    final out = await _guardBed(
        () => db.batch([
              InsertOp(
                  Col.encounters,
                  {
                    'patient_id': patientId,
                    'type': Vals.ipd,
                    'status': Vals.open,
                    'doctor_id': attendingDoctorId,
                    'department': doctor?.strOrNull('department'),
                    'started_at': now,
                    'source_module': 'ipd',
                    'source_id': admissionId,
                    'summary': diagnosis.trim().isEmpty ? null : diagnosis.trim(),
                  },
                  id: encounterId),
              InsertOp(
                  IpdCol.admissions,
                  {
                    'number': number,
                    'patient_id': patientId,
                    'encounter_id': encounterId,
                    'bed_id': bed.id,
                    'ward_id': bed.str('ward_id'),
                    'admitted_at': now,
                    'admitting_doctor_id': admittingDoctorId ?? attendingDoctorId,
                    'attending_doctor_id': attendingDoctorId,
                    'diagnosis': diagnosis.trim(),
                    'reason': reason.trim(),
                    'status': IpdVals.admitted,
                    'expected_discharge':
                        expectedStayDays == null ? null : DateTime(now.year, now.month, now.day + expectedStayDays),
                  },
                  id: admissionId),
              UpdateOp(IpdCol.beds, bed.id, {'status': IpdVals.occupied, 'admission_id': admissionId, 'status_since': now},
                  expectedVersion: bed.version),
            ]),
        bed);
    return out[1];
  }

  /// Moves a patient to another free bed. The old bed goes for cleaning.
  static Future<Rec> transfer(Db db, Rec admission,
      {required String toBedId, required String reason, String? byName, DateTime? at}) async {
    final now = at ?? DateTime.now();
    final adm = await db.get(IpdCol.admissions, admission.id) ?? admission;
    if (adm.str('status') == IpdVals.discharged) throw ValidationException('This patient has been discharged');
    if (adm.str('bed_id') == toBedId) throw ValidationException('The patient is already in that bed');
    final to = await _freeBed(db, toBedId);
    final from = await db.get(IpdCol.beds, adm.strOrNull('bed_id'));
    final transferId = db.newId();
    final out = await _guardBed(
        () => db.batch([
              InsertOp(
                  IpdCol.transfers,
                  {
                    'admission_id': adm.id,
                    'from_bed_id': from?.id,
                    'to_bed_id': to.id,
                    'from_ward_id': adm.strOrNull('ward_id') ?? from?.strOrNull('ward_id'),
                    'to_ward_id': to.str('ward_id'),
                    'at': now,
                    'reason': reason.trim(),
                    'by_name': byName,
                  },
                  id: transferId),
              UpdateOp(IpdCol.admissions, adm.id, {'bed_id': to.id, 'ward_id': to.str('ward_id')}),
              if (from != null && from.str('admission_id') == adm.id)
                UpdateOp(IpdCol.beds, from.id, {'status': IpdVals.cleaning, 'admission_id': null, 'status_since': now}),
              UpdateOp(IpdCol.beds, to.id, {'status': IpdVals.occupied, 'admission_id': adm.id, 'status_since': now},
                  expectedVersion: to.version),
            ]),
        to);
    return out.first;
  }

  /// Step 1 of discharge (doctor): summary, advice and type. The patient
  /// keeps the bed until the discharge is completed.
  static Future<Rec> requestDischarge(Db db, Rec admission,
      {required String type, required String summary, String advice = '', DateTime? at}) async {
    final st = admission.str('status');
    if (st == IpdVals.discharged) throw ValidationException('This patient has already been discharged');
    if (summary.trim().isEmpty) throw ValidationException('Write a discharge summary first');
    return db.update(
      IpdCol.admissions,
      admission.id,
      {
        'status': IpdVals.dischargePending,
        'discharge_requested_at':
            st == IpdVals.dischargePending ? (admission.date('discharge_requested_at') ?? at ?? DateTime.now()) : (at ?? DateTime.now()),
        'discharge_type': type,
        'discharge_summary': summary.trim(),
        'discharge_advice': advice.trim(),
      },
      expectedVersion: admission.version,
    );
  }

  /// Takes back a discharge sign-off (plans changed).
  static Future<Rec> cancelDischarge(Db db, Rec admission) async {
    if (admission.str('status') != IpdVals.dischargePending) throw ValidationException('No discharge is pending');
    return db.update(IpdCol.admissions, admission.id, {'status': IpdVals.admitted, 'discharge_requested_at': null},
        expectedVersion: admission.version);
  }

  /// Step 2 of discharge: posts the remaining bed-days, closes the
  /// encounter, sends the bed for cleaning and marks the admission
  /// discharged — all at once. Returns the number of bed-days posted now.
  static Future<int> completeDischarge(Db db, Rec admission, {DateTime? at}) => BedCharging.serial(() async {
        final now = at ?? DateTime.now();
        for (var attempt = 0;; attempt++) {
          final adm = await db.get(IpdCol.admissions, admission.id);
          if (adm == null) throw ValidationException('Admission not found');
          if (adm.str('status') == IpdVals.discharged) throw ValidationException('This patient has already been discharged');
          if (adm.str('status') != IpdVals.dischargePending) {
            throw ValidationException('The doctor has not signed off this discharge yet');
          }
          final posting = await BedCharging.prepare(db, adm, now: now, dischargedAt: now);
          final encounter = await db.get(Col.encounters, adm.strOrNull('encounter_id'));
          final bed = await db.get(IpdCol.beds, adm.strOrNull('bed_id'));
          final ops = <WriteOp>[
            ...posting.ops,
            UpdateOp(IpdCol.admissions, adm.id, {
              'status': IpdVals.discharged,
              'discharged_at': now,
              if (posting.postedUntil != null) 'bed_charges_posted_until': posting.postedUntil,
            }),
            if (encounter != null) UpdateOp(Col.encounters, encounter.id, {'status': Vals.closed, 'ended_at': now}),
            if (bed != null && bed.str('admission_id') == adm.id)
              UpdateOp(IpdCol.beds, bed.id, {'status': IpdVals.cleaning, 'admission_id': null, 'status_since': now}),
          ];
          try {
            await db.batch(ops);
            return posting.newDays;
          } on ValidationException {
            // A bed-day was posted by another device in the meantime; try once more.
            if (attempt >= 1) rethrow;
          }
        }
      });

  /// Cleaning done (or repairs finished): the bed is free again.
  static Future<Rec> markReady(Db db, Rec bed, {DateTime? at}) async {
    final st = bed.str('status');
    if (st == IpdVals.occupied) throw ValidationException('Bed ${bed.str('label')} is occupied');
    return db.update(IpdCol.beds, bed.id, {'status': IpdVals.available, 'admission_id': null, 'status_since': at ?? DateTime.now()},
        expectedVersion: bed.version);
  }

  static Future<Rec> setMaintenance(Db db, Rec bed, bool on, {DateTime? at}) async {
    if (bed.str('status') == IpdVals.occupied) {
      throw ValidationException('Bed ${bed.str('label')} is occupied. Move the patient first.');
    }
    return db.update(IpdCol.beds, bed.id, {'status': on ? IpdVals.maintenance : IpdVals.available, 'status_since': at ?? DateTime.now()},
        expectedVersion: bed.version);
  }

  /// Takes a bed out of the bed board for good (records are kept).
  static Future<Rec> retireBed(Db db, Rec bed) async {
    if (bed.str('status') == IpdVals.occupied) throw ValidationException('Bed ${bed.str('label')} is occupied');
    return db.update(IpdCol.beds, bed.id, {'active': false}, expectedVersion: bed.version);
  }

  static Future<Rec> addNote(
    Db db, {
    required Rec admission,
    required String kind,
    String text = '',
    Map<String, Object?>? vitals,
    String? byName,
    DateTime? at,
  }) async {
    final v = {...?vitals}..removeWhere((k, val) => val == null);
    if (text.trim().isEmpty && v.isEmpty) throw ValidationException('Write a note or enter at least one vital sign');
    return db.insert(IpdCol.notes, {
      'admission_id': admission.id,
      'patient_id': admission.str('patient_id'),
      'kind': kind,
      'text': text.trim(),
      'vitals': v.isEmpty ? null : v,
      'by_name': byName,
      'recorded_at': at ?? DateTime.now(),
    });
  }

  // ------------------------------------------------------------ wards & beds

  static Future<Rec> saveWard(Db db, {Rec? existing, required Map<String, Object?> data}) {
    final clean = {...data, 'name': (data['name'] as String? ?? '').trim()};
    if (existing == null) return db.insert(IpdCol.wards, {'active': true, ...clean});
    return db.update(IpdCol.wards, existing.id, clean, expectedVersion: existing.version);
  }

  /// "G-", 13, 16 → G-13, G-14, G-15, G-16.
  static List<String> bedLabels(String prefix, int from, int to, {int pad = 2}) => [
        if (from <= to && to - from < 200)
          for (var n = from; n <= to; n++) '${prefix.trim()}${n.toString().padLeft(pad, '0')}',
      ];

  /// Adds beds to a ward, skipping labels it already has. Returns how many were added.
  static Future<int> addBeds(Db db, Rec ward, List<String> labels, {DateTime? at}) async {
    final have = {
      for (final b in await db.query(Query(IpdCol.beds).eq('ward_id', ward.id).take(1000))) b.str('label').toLowerCase(),
    };
    final now = at ?? DateTime.now();
    final fresh = labels.where((l) => l.trim().isNotEmpty && !have.contains(l.trim().toLowerCase())).toList();
    await db.batch([
      for (final l in fresh)
        InsertOp(IpdCol.beds, {
          'ward_id': ward.id,
          'label': l.trim(),
          'status': IpdVals.available,
          'status_since': now,
          'active': true,
        }),
    ]);
    return fresh.length;
  }

  /// Wards in a stable, familiar order: general, semi-private, private,
  /// ICU, NICU, day care; then by name.
  static List<Rec> sortWards(List<Rec> wards) {
    int rank(Rec w) {
      final i = IpdVals.wardKinds.indexOf(w.str('kind'));
      return i < 0 ? IpdVals.wardKinds.length : i;
    }

    return [...wards]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.str('name').toLowerCase().compareTo(b.str('name').toLowerCase());
      });
  }

  /// Natural order for bed labels: G-2 before G-10.
  static int compareLabels(String a, String b) {
    final ra = RegExp(r'^(.*?)(\d+)$').firstMatch(a);
    final rb = RegExp(r'^(.*?)(\d+)$').firstMatch(b);
    if (ra != null && rb != null && ra.group(1) == rb.group(1)) {
      return int.parse(ra.group(2)!).compareTo(int.parse(rb.group(2)!));
    }
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  // ------------------------------------------------------------ defaults

  static const defaultServices = <(String, String, String, int)>[
    ('BED-GEN', 'Bed charges — general ward (per day)', Vals.bed, 120000),
    ('BED-SEMI', 'Bed charges — semi-private (per day)', Vals.bed, 250000),
    ('BED-PVT', 'Bed charges — private room (per day)', Vals.bed, 450000),
    ('BED-ICU', 'Bed charges — ICU (per day)', Vals.bed, 900000),
    ('NURSING-GEN', 'Nursing charges — ward (per day)', Vals.nursing, 50000),
    ('NURSING-ICU', 'Nursing charges — ICU (per day)', Vals.nursing, 150000),
  ];

  /// (name, kind, floor, bed prefix, beds)
  static const defaultWards = <(String, String, String, String, int)>[
    ('General Ward A', 'general', 'Ground floor', 'G-', 12),
    ('Semi-private', 'semi_private', 'First floor', 'S-', 6),
    ('Private rooms', 'private', 'Second floor', 'P-', 6),
    ('ICU', 'icu', 'First floor', 'ICU-', 6),
  ];

  /// Price-list entries and the standard wards, unless they already exist.
  static Future<void> seedDefaults(Db db) async {
    final codes = {
      for (final s in await db.query(Query(Col.services).isIn('code', [for (final s in defaultServices) s.$1]).withArchived()))
        s.str('code'),
    };
    await db.batch([
      for (final (code, name, category, price) in defaultServices)
        if (!codes.contains(code))
          InsertOp(Col.services, {
            'code': code,
            'name': name,
            'category': category,
            'price_paise': price,
            'department': 'Inpatients',
            'active': true,
            'tax_percent': 0.0,
          }),
    ]);
    if (await db.count(const Query(IpdCol.wards).withArchived()) > 0) return;
    final now = DateTime.now();
    final ops = <WriteOp>[];
    for (final (name, kind, floor, prefix, count) in defaultWards) {
      final wardId = db.newId();
      ops.add(InsertOp(
          IpdCol.wards,
          {
            'name': name,
            'kind': kind,
            'floor': floor,
            'bed_service_code': defaultBedCode(kind),
            'nursing_service_code': defaultNursingCode(kind),
            'active': true,
          },
          id: wardId));
      for (final label in bedLabels(prefix, 1, count)) {
        ops.add(InsertOp(IpdCol.beds,
            {'ward_id': wardId, 'label': label, 'status': IpdVals.available, 'status_since': now, 'active': true}));
      }
    }
    await db.batch(ops);
  }
}

/// "Dr. Farah Khan" → "Dr. Khan".
String shortDoctor(String name) {
  final n = name.trim();
  if (n.isEmpty) return '';
  final parts = n.split(RegExp(r'\s+'));
  if (parts.length >= 3 && parts.first.toLowerCase().startsWith('dr')) return '${parts.first} ${parts.last}';
  return n;
}

import 'package:kendra_hms/core/core.dart';

import 'clinical.dart';
import 'clinical_data.dart';
import 'opd_schema.dart';

/// What finishing a consultation did, for the summary shown to the doctor.
class FinishResult {
  const FinishResult({
    required this.consultation,
    this.prescriptionId,
    this.medicineCount = 0,
    this.orderCount = 0,
    this.chargePaise,
    this.alreadySigned = false,
  });
  final Rec consultation;
  final String? prescriptionId;
  final int medicineCount;
  final int orderCount;

  /// Null when a charge already existed (nothing new was added).
  final int? chargePaise;
  final bool alreadySigned;
}

/// The note fields a doctor may amend after signing.
const amendableFields = <String, String>{
  'chief_complaint': 'Chief complaint',
  'history': 'History',
  'examination': 'Examination',
  'diagnosis': 'Diagnosis',
  'icd_code': 'ICD code',
  'advice': 'Advice',
  'notes': 'Other notes',
  'follow_up_date': 'Follow-up date',
};

String doctorLabel(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Doctor';
  return n.toLowerCase().startsWith('dr') ? n : 'Dr. $n';
}

/// OPD rules shared by the screens, the agents and the demo seeder.
abstract final class OpdService {
  // ------------------------------------------------------------------ queue

  static String tokenSequence(String doctorId, DateTime day) =>
      'token:${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}:$doctorId';

  /// Today's OPD visits (all statuses), optionally for one doctor.
  static Query dayQuery({String? doctorId, DateTime? day}) {
    final d = startOfDay(day ?? DateTime.now());
    var q = const Query(Col.encounters).eq('type', Vals.opd).between('started_at', d, endOfDay(d));
    if (doctorId != null) q = q.eq('doctor_id', doctorId);
    return q.sort('started_at').take(1000);
  }

  /// Queue order: token, then arrival.
  static int byToken(Rec a, Rec b) {
    final t = (a.intOrNull('token_no') ?? 1 << 30).compareTo(b.intOrNull('token_no') ?? 1 << 30);
    if (t != 0) return t;
    return (a.date('checked_in_at') ?? a.date('started_at')!).compareTo(b.date('checked_in_at') ?? b.date('started_at')!);
  }

  static bool isWaiting(Rec e) => e.str('status') == Vals.open && e.str('queue_status', Vals.waiting) == Vals.waiting;

  /// The next patient waiting for [doctorId] today, by token.
  static Future<Rec?> nextWaiting(ReadDb db, String doctorId, {DateTime? now}) async {
    final rows = (await db.query(dayQuery(doctorId: doctorId, day: now).eq('status', Vals.open)))
        .where(isWaiting)
        .toList()
      ..sort(byToken);
    return rows.isEmpty ? null : rows.first;
  }

  /// Adds a walk-in to [doctor]'s queue with today's next token. If the
  /// patient already has an open visit with this doctor today, returns that
  /// one instead (second value false).
  static Future<(Rec, bool)> addWalkIn(Db db, {required String patientId, required Rec doctor, bool withDoctor = false, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final existing = await db.first(dayQuery(doctorId: doctor.id, day: t).eq('patient_id', patientId).eq('status', Vals.open));
    if (existing != null) return (existing, false);
    final token = await db.nextSequence(tokenSequence(doctor.id, t));
    final rec = await db.insert(Col.encounters, {
      'patient_id': patientId,
      'type': Vals.opd,
      'status': Vals.open,
      'doctor_id': doctor.id,
      'department': doctor.strOrNull('department'),
      'started_at': t,
      'source_module': 'opd',
      'token_no': token,
      'queue_status': withDoctor ? Vals.withDoctor : Vals.waiting,
      'checked_in_at': t,
      if (withDoctor) 'called_at': t,
    });
    return (rec, true);
  }

  static Future<Rec?> consultationFor(ReadDb db, String encounterId) =>
      db.first(Query(OpdCol.consultations).eq('encounter_id', encounterId).withArchived());

  /// The doctor calls the patient in: marks the visit "with doctor" and
  /// makes sure there is a draft note to write in. Returns the note.
  static Future<Rec> start(Db db, Rec encounter, {required Rec doctor, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final enc = await db.get(Col.encounters, encounter.id) ?? encounter;
    final existing = await consultationFor(db, enc.id);
    if (existing?.str('status') == ConsultStatus.signed) return existing!;
    if (enc.str('status') != Vals.open) {
      throw ValidationException('This visit is already ${enc.str('status')}. Start a new visit for the patient.');
    }
    final ops = <WriteOp>[];
    final patch = <String, Object?>{};
    if (enc.str('queue_status') != Vals.withDoctor) {
      patch['queue_status'] = Vals.withDoctor;
      patch['called_at'] = t;
    }
    if (enc.strOrNull('doctor_id') == null) {
      patch['doctor_id'] = doctor.id;
      patch['department'] = doctor.strOrNull('department');
    }
    if (patch.isNotEmpty) ops.add(UpdateOp(Col.encounters, enc.id, patch));
    String id;
    if (existing == null) {
      id = db.newId();
      ops.add(InsertOp(
        OpdCol.consultations,
        {
          'encounter_id': enc.id,
          'patient_id': enc.str('patient_id'),
          'doctor_id': doctor.id,
          'started_at': t,
          'status': ConsultStatus.draft,
          'rx_draft': const <Object?>[],
          'orders_draft': const <Object?>[],
        },
        id: id,
      ));
    } else {
      id = existing.id;
      if (existing.str('doctor_id') != doctor.id) {
        ops.add(UpdateOp(OpdCol.consultations, id, {'doctor_id': doctor.id}));
      }
    }
    try {
      await db.batch(ops);
    } on ValidationException {
      // Someone else opened the note at the same moment; use theirs.
      final again = await consultationFor(db, enc.id);
      if (again == null) rethrow;
      return again;
    }
    return (await db.get(OpdCol.consultations, id))!;
  }

  /// The patient went away without being seen.
  static Future<void> markLeft(Db db, Rec encounter, {DateTime? now}) async {
    final c = await consultationFor(db, encounter.id);
    if (c?.str('status') == ConsultStatus.signed) {
      throw ValidationException('This patient has already been seen');
    }
    await db.update(Col.encounters, encounter.id, {
      'queue_status': Vals.left,
      'status': Vals.cancelled,
      'ended_at': now ?? DateTime.now(),
    });
  }

  static Future<void> backToQueue(Db db, Rec encounter) => db.update(Col.encounters, encounter.id, {
        'queue_status': Vals.waiting,
        'status': Vals.open,
        'ended_at': null,
      });

  /// Nurse (or doctor) records vitals before the consultation.
  static Future<Rec> recordVitals(Db db, Rec encounter, Map<String, Object?> vitals,
      {required String byName, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final clean = Vitals.clean(vitals);
    if (clean.isEmpty) throw ValidationException('Enter at least one reading');
    final existing = await consultationFor(db, encounter.id);
    if (existing == null) {
      final doctorId = encounter.strOrNull('doctor_id');
      if (doctorId == null) throw ValidationException('Choose a doctor for this visit first');
      return db.insert(OpdCol.consultations, {
        'encounter_id': encounter.id,
        'patient_id': encounter.str('patient_id'),
        'doctor_id': doctorId,
        'started_at': encounter.date('checked_in_at') ?? encounter.date('started_at') ?? t,
        'vitals': clean,
        'vitals_at': t,
        'vitals_by_name': byName,
        'status': ConsultStatus.draft,
      });
    }
    if (existing.str('status') == ConsultStatus.signed) {
      throw ValidationException('The consultation is already signed');
    }
    return db.update(OpdCol.consultations, existing.id, {'vitals': clean, 'vitals_at': t, 'vitals_by_name': byName});
  }

  /// Autosave of the doctor's draft.
  static Future<Rec> saveDraft(Db db, String consultationId, Map<String, Object?> patch) async {
    final c = await db.get(OpdCol.consultations, consultationId);
    if (c == null) throw ValidationException('Consultation not found');
    if (c.str('status') == ConsultStatus.signed) {
      throw ValidationException('This consultation is already signed. Use Amend to correct it.');
    }
    return db.update(OpdCol.consultations, consultationId, patch);
  }

  // ------------------------------------------------------------------ finish

  static Future<int> consultationFee(ReadDb db, Rec? doctor) async {
    final fee = doctor?.intOrNull('consultation_fee_paise');
    if (fee != null) return fee;
    final svc = await db.first(const Query(Col.services).eq('code', 'CONSULT'));
    return svc?.intOrNull('price_paise') ?? 50000;
  }

  /// Signs the note and, in one all-or-nothing write: sends the medicines to
  /// pharmacy, the tests to the lab, adds the consultation charge and closes
  /// the visit. Finishing twice adds nothing the second time.
  static Future<FinishResult> finish(Db db, String consultationId, {required Rec signer, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final c = await db.get(OpdCol.consultations, consultationId);
    if (c == null) throw ValidationException('Consultation not found');
    if (c.str('status') == ConsultStatus.signed) {
      return FinishResult(consultation: c, prescriptionId: c.strOrNull('prescription_id'), alreadySigned: true);
    }
    final enc = await db.get(Col.encounters, c.str('encounter_id'));
    if (enc == null) throw ValidationException('The visit for this note was not found');
    final doctor = await db.get(Col.users, c.str('doctor_id')) ?? signer;
    final patientId = c.str('patient_id');
    final diagnosis = c.str('diagnosis').trim();
    final ops = <WriteOp>[];

    final items = [
      for (final m in c.maps('rx_draft'))
        if ((m['drug_name'] as String? ?? '').trim().isNotEmpty)
          {
            'medicine_id': m['medicine_id'],
            'drug_name': (m['drug_name'] as String).trim(),
            'generic_name': m['generic_name'],
            'dose': m['dose'],
            'frequency': m['frequency'],
            'duration_days': m['duration_days'],
            'route': m['route'],
            'instructions': m['instructions'],
            'quantity': m['quantity'],
          },
    ];
    String? rxId = c.strOrNull('prescription_id');
    if (items.isNotEmpty && rxId == null) {
      rxId = db.newId();
      ops.add(InsertOp(
        Col.prescriptions,
        {
          'patient_id': patientId,
          'encounter_id': enc.id,
          'doctor_id': doctor.id,
          'items': items,
          'status': Vals.active,
          'notes': diagnosis.isEmpty ? null : diagnosis,
        },
        id: rxId,
      ));
    }

    final orders = c.maps('orders_draft').where((o) => (o['name'] as String? ?? '').trim().isNotEmpty).toList();
    for (final o in orders) {
      final note = (o['clinical_notes'] as String? ?? '').trim();
      ops.add(InsertOp(Col.serviceOrders, {
        'patient_id': patientId,
        'encounter_id': enc.id,
        'order_type': o['order_type'] == Vals.radiology ? Vals.radiology : Vals.lab,
        'service_code': o['service_code'],
        'name': (o['name'] as String).trim(),
        'status': Vals.ordered,
        'priority': o['priority'] ?? 'routine',
        'ordered_by': doctor.id,
        'ordered_at': t,
        'clinical_notes': note.isNotEmpty ? note : (diagnosis.isEmpty ? null : diagnosis),
      }));
    }

    int? chargePaise;
    final existingCharge = await db.first(
        Query(Col.charges).eq('source_collection', OpdCol.consultations).eq('source_id', c.id).withArchived());
    if (existingCharge == null) {
      final fee = await consultationFee(db, doctor);
      chargePaise = fee;
      ops.add(InsertOp(Col.charges, {
        'patient_id': patientId,
        'encounter_id': enc.id,
        'service_code': 'CONSULT',
        'description': 'Consultation — ${doctorLabel(doctor.str('display_name'))}',
        'category': Vals.consultation,
        'quantity': 1,
        'unit_price_paise': fee,
        'amount_paise': fee,
        'status': Vals.pending,
        'source_module': 'opd',
        'source_collection': OpdCol.consultations,
        'source_id': c.id,
        'service_date': t,
        'ordered_by': doctor.id,
      }));
    }

    ops.add(UpdateOp(
      OpdCol.consultations,
      c.id,
      {
        'status': ConsultStatus.signed,
        'signed_at': t,
        'signed_by': signer.id,
        'signed_by_name': signer.str('display_name'),
        'prescription_id': rxId,
      },
      expectedVersion: c.version,
    ));
    if (enc.str('status') == Vals.open) {
      ops.add(UpdateOp(Col.encounters, enc.id, {
        'status': Vals.closed,
        'queue_status': Vals.done,
        'ended_at': t,
        if (enc.date('called_at') == null) 'called_at': c.date('started_at') ?? t,
        if (diagnosis.isNotEmpty) 'summary': diagnosis,
      }));
    }
    final written = await db.batch(ops);
    final signed = written.firstWhere((r) => r.collection == OpdCol.consultations && r.id == c.id);
    return FinishResult(
      consultation: signed,
      prescriptionId: rxId,
      medicineCount: items.length,
      orderCount: orders.length,
      chargePaise: chargePaise,
    );
  }

  // ------------------------------------------------------------------ amend

  static Object? _jsonValue(Object? v) {
    if (v is DateTime) return dayKey(v);
    if (v is String) return v.trim();
    return v;
  }

  static bool _same(Object? a, Object? b) {
    final x = _jsonValue(a);
    final y = _jsonValue(b);
    final xs = x is String && x.isEmpty ? null : x;
    final ys = y is String && y.isEmpty ? null : y;
    return xs == ys;
  }

  /// Corrects a signed note. Only the doctor who signed it may, a reason is
  /// required, and every changed field is recorded with its old and new value.
  static Future<Rec> amend(Db db, Rec consultation, Map<String, Object?> values,
      {required String reason, required String byName, DateTime? now}) async {
    if (reason.trim().isEmpty) throw ValidationException('Give a reason for the amendment');
    final c = await db.get(OpdCol.consultations, consultation.id);
    if (c == null) throw ValidationException('Consultation not found');
    if (c.str('status') != ConsultStatus.signed) {
      throw ValidationException('Only signed notes are amended. Edit the draft instead.');
    }
    final actor = db.actor;
    if (!actor.isSystem && c.str('signed_by') != actor.id) {
      throw PermissionDeniedException('Only the doctor who signed this note can amend it');
    }
    final changes = <Map<String, Object?>>[];
    final patch = <String, Object?>{};
    for (final e in values.entries) {
      if (!amendableFields.containsKey(e.key)) throw ValidationException('${e.key} cannot be amended');
      final old = c[e.key];
      if (_same(old, e.value)) continue;
      changes.add({'field': e.key, 'old': _jsonValue(old), 'new': _jsonValue(e.value)});
      patch[e.key] = e.value is String ? (e.value as String).trim() : e.value;
    }
    if (changes.isEmpty) throw ValidationException('Nothing was changed');
    final written = await db.batch([
      InsertOp(OpdCol.amendments, {
        'consultation_id': c.id,
        'patient_id': c.str('patient_id'),
        'reason': reason.trim(),
        'changes': changes,
        'amended_by_name': byName,
      }),
      UpdateOp(OpdCol.consultations, c.id, {...patch, 'amended_at': now ?? DateTime.now()}, expectedVersion: c.version),
    ]);
    return written.last;
  }

  // ------------------------------------------------------------------ helpers

  /// Opens (or reuses) today's visit of [patient] with [doctor] and starts it.
  static Future<Rec> startForPatient(Db db, Rec patient, Rec doctor) async {
    final (enc, _) = await addWalkIn(db, patientId: patient.id, doctor: doctor, withDoctor: true);
    await start(db, enc, doctor: doctor);
    return enc;
  }

  /// The patient's latest prescription (by visit date) and when it was written.
  static Future<(Rec, DateTime)?> lastPrescription(ReadDb db, String patientId, {String? excludeEncounterId}) async {
    final rows = (await db.query(Query(Col.prescriptions).eq('patient_id', patientId).take(40)))
        .where((r) => excludeEncounterId == null || r.str('encounter_id') != excludeEncounterId)
        .where((r) => r.maps('items').isNotEmpty)
        .toList();
    if (rows.isEmpty) return null;
    final encs = await db.byIds(Col.encounters, rows.map((r) => r.strOrNull('encounter_id')));
    DateTime when(Rec r) => encs[r.str('encounter_id')]?.date('started_at') ?? r.createdAt;
    rows.sort((a, b) => when(b).compareTo(when(a)));
    return (rows.first, when(rows.first));
  }

  /// The diagnoses this doctor writes most often, most frequent first.
  static Future<List<DiagnosisOption>> frequentDiagnoses(ReadDb db, String doctorId, {int limit = 8}) async {
    final rows = await db.query(Query(OpdCol.consultations)
        .eq('doctor_id', doctorId)
        .eq('status', ConsultStatus.signed)
        .sort('signed_at', desc: true)
        .take(400));
    final counts = <String, int>{};
    final names = <String, DiagnosisOption>{};
    for (final r in rows) {
      final d = r.str('diagnosis').trim();
      if (d.isEmpty) continue;
      final k = d.toLowerCase();
      counts[k] = (counts[k] ?? 0) + 1;
      names.putIfAbsent(k, () => DiagnosisOption(d, r.str('icd_code')));
    }
    final keys = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [for (final k in keys.take(limit)) names[k]!];
  }

  /// What this doctor prescribed the last time they made the same diagnosis.
  static Future<List<Map<String, Object?>>> usualPrescription(ReadDb db, String doctorId, String diagnosis) async {
    final d = diagnosis.trim();
    if (d.isEmpty) return const [];
    final c = await db.first(Query(OpdCol.consultations)
        .eq('doctor_id', doctorId)
        .eq('diagnosis', d)
        .eq('status', ConsultStatus.signed)
        .isNotNull('prescription_id')
        .sort('signed_at', desc: true));
    if (c == null) return const [];
    final rx = await db.get(Col.prescriptions, c.str('prescription_id'));
    return rx?.maps('items') ?? const [];
  }

  /// Medicines to prescribe from: the master list, or a built-in list.
  static Future<List<DrugOption>> drugOptions(ReadDb db) async {
    final rows = await db.query(const Query(Col.medicines).sort('name').take(5000));
    final active = rows.where((r) => r['active'] != false).toList();
    if (active.isEmpty) return commonMedicines;
    return [
      for (final m in active)
        DrugOption(
          id: m.id,
          name: m.str('name'),
          generic: m.str('generic_name'),
          form: m.str('form'),
          strength: m.str('strength'),
          defaultDose: m.str('default_dose'),
          defaultFrequency: m.str('default_frequency'),
        ),
    ];
  }

  /// Orderable tests: lab and radiology services, or a built-in list.
  static Future<List<TestOption>> testOptions(ReadDb db) async {
    final rows = await db.query(
        const Query(Col.services).isIn('category', [Vals.lab, Vals.radiology]).sort('name').take(2000));
    final active = rows.where((r) => r['active'] != false).toList();
    if (active.isEmpty) return commonTests;
    return [
      for (final s in active) TestOption(code: s.str('code'), name: s.str('name'), type: s.str('category')),
    ];
  }

  /// Turns a prescription item (or a draft row) into a draft row.
  static Map<String, Object?> draftItem(Map<String, Object?> item) => {
        'medicine_id': item['medicine_id'],
        'drug_name': item['drug_name'],
        'generic_name': item['generic_name'],
        'form': item['form'],
        'dose': item['dose'],
        'frequency': item['frequency'],
        'duration_days': item['duration_days'],
        'route': item['route'],
        'instructions': item['instructions'],
        'quantity': item['quantity'],
      };
}

import 'package:kendra_hms/core/core.dart';

abstract final class IpdPerms {
  static const view = 'ipd.view';
  static const admit = 'ipd.admit';
  static const notes = 'ipd.notes';
  static const discharge = 'ipd.discharge';
  static const setup = 'ipd.setup';
}

abstract final class IpdCol {
  static const wards = 'wards';
  static const beds = 'beds';
  static const admissions = 'ipd_admissions';
  static const transfers = 'ipd_transfers';
  static const notes = 'ipd_notes';
}

/// Value sets used by the IPD tables.
abstract final class IpdVals {
  // beds.status
  static const available = 'available';
  static const occupied = 'occupied';
  static const cleaning = 'cleaning';
  static const maintenance = 'maintenance';
  static const reserved = 'reserved';
  // ipd_admissions.status
  static const admitted = 'admitted';
  static const dischargePending = 'discharge_pending';
  static const discharged = 'discharged';
  static const current = [admitted, dischargePending];
  // ward kinds
  static const wardKinds = ['general', 'semi_private', 'private', 'icu', 'nicu', 'daycare'];
  // discharge types
  static const dischargeTypes = ['normal', 'lama', 'referred', 'death', 'absconded'];
  // note kinds
  static const noteKinds = ['nursing', 'vitals', 'progress', 'handover'];
}

String wardKindLabel(String kind) => switch (kind) {
      'general' => 'General',
      'semi_private' => 'Semi-private',
      'private' => 'Private',
      'icu' => 'ICU',
      'nicu' => 'NICU',
      'daycare' => 'Day care',
      _ => titleCase(kind),
    };

String dischargeTypeLabel(String type) => switch (type) {
      'normal' => 'Normal',
      'lama' => 'LAMA',
      'referred' => 'Referred',
      'death' => 'Death',
      'absconded' => 'Absconded',
      _ => titleCase(type),
    };

String noteKindLabel(String kind) => switch (kind) {
      'nursing' => 'Nursing note',
      'vitals' => 'Vitals',
      'progress' => 'Progress note',
      'handover' => 'Handover',
      _ => titleCase(kind),
    };

String _vitalValue(Object? v) {
  if (v is double) return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  return '$v';
}

/// A vitals note as short readings: "BP 120/80", "Pulse 84"…
List<String> vitalBits(Map<String, Object?> v) => [
      if (v['bp_sys'] != null || v['bp_dia'] != null) 'BP ${_vitalValue(v['bp_sys'] ?? '—')}/${_vitalValue(v['bp_dia'] ?? '—')}',
      if (v['pulse'] != null) 'Pulse ${_vitalValue(v['pulse'])}',
      if (v['temp_c'] != null) 'Temp ${_vitalValue(v['temp_c'])} °C',
      if (v['spo2'] != null) 'SpO2 ${_vitalValue(v['spo2'])}%',
      if (v['rr'] != null) 'RR ${_vitalValue(v['rr'])}',
      if (v['grbs'] != null) 'GRBS ${_vitalValue(v['grbs'])}',
    ];

String bedStatusLabel(String status) => switch (status) {
      IpdVals.available => 'Free',
      IpdVals.occupied => 'Occupied',
      IpdVals.cleaning => 'Cleaning',
      IpdVals.maintenance => 'Maintenance',
      IpdVals.reserved => 'Reserved',
      _ => titleCase(status),
    };

Tone bedStatusTone(String status) => switch (status) {
      IpdVals.available => Tone.success,
      IpdVals.occupied => Tone.info,
      IpdVals.cleaning => Tone.warning,
      _ => Tone.neutral,
    };

/// Price-list codes used when a ward has none set.
String defaultBedCode(String kind) => switch (kind) {
      'semi_private' => 'BED-SEMI',
      'private' => 'BED-PVT',
      'icu' || 'nicu' => 'BED-ICU',
      _ => 'BED-GEN',
    };

String defaultNursingCode(String kind) => switch (kind) {
      'icu' || 'nicu' => 'NURSING-ICU',
      _ => 'NURSING-GEN',
    };

const wardsCollection = CollectionSchema(
  name: IpdCol.wards,
  owner: 'ipd',
  description: 'Wards and their per-day bed and nursing price codes.',
  writePermissions: {IpdPerms.setup},
  fields: [
    Field.text('name', required: true, searchable: true),
    Field.text('kind', indexed: true), // general | semi_private | private | icu | nicu | daycare
    Field.text('floor'),
    Field.text('bed_service_code'), // services.code charged per bed-day
    Field.text('nursing_service_code'), // services.code charged per bed-day
    Field.boolean('active', indexed: true),
  ],
);

const bedsCollection = CollectionSchema(
  name: IpdCol.beds,
  owner: 'ipd',
  description: 'One row per bed. status says who can use it right now.',
  writePermissions: {IpdPerms.setup, IpdPerms.admit, IpdPerms.discharge},
  fields: [
    Field.ref('ward_id', IpdCol.wards, required: true),
    Field.text('label', required: true, searchable: true),
    Field.text('status', indexed: true), // available | occupied | cleaning | maintenance | reserved
    Field.text('admission_id'),
    Field.dateTime('status_since'),
    Field.boolean('active', indexed: true),
  ],
);

const admissionsCollection = CollectionSchema(
  name: IpdCol.admissions,
  owner: 'ipd',
  description: 'One inpatient stay. Creates an `encounters` row of type ipd; '
      'bed-day charges are posted to `charges` automatically.',
  writePermissions: {IpdPerms.admit, IpdPerms.discharge},
  fields: [
    Field.text('number', required: true, unique: true, searchable: true), // IP-26-00042
    Field.ref('patient_id', Col.patients, required: true),
    Field.ref('encounter_id', Col.encounters),
    Field.ref('bed_id', IpdCol.beds), // current bed
    Field.ref('ward_id', IpdCol.wards), // current ward
    Field.dateTime('admitted_at', required: true, indexed: true),
    Field.ref('admitting_doctor_id', Col.users),
    Field.ref('attending_doctor_id', Col.users),
    Field.text('diagnosis', searchable: true),
    Field.text('reason'),
    Field.text('status', indexed: true), // admitted | discharge_pending | discharged
    Field.dateTime('expected_discharge'),
    Field.dateTime('discharge_requested_at'),
    Field.dateTime('discharged_at', indexed: true),
    Field.text('discharge_type'), // normal | lama | referred | death | absconded
    Field.text('discharge_summary'),
    Field.text('discharge_advice'),
    // Every bed-day up to and including this day has been posted.
    Field.dateTime('bed_charges_posted_until'),
  ],
);

const transfersCollection = CollectionSchema(
  name: IpdCol.transfers,
  owner: 'ipd',
  description: 'Bed moves during a stay. Bed-days are charged at the ward occupied at the start of each day.',
  writePermissions: {IpdPerms.admit},
  fields: [
    Field.ref('admission_id', IpdCol.admissions, required: true),
    Field.ref('from_bed_id', IpdCol.beds),
    Field.ref('to_bed_id', IpdCol.beds),
    // The wards at the time of the move, so charges never depend on later bed edits.
    Field.ref('from_ward_id', IpdCol.wards),
    Field.ref('to_ward_id', IpdCol.wards),
    Field.dateTime('at', indexed: true),
    Field.text('reason'),
    Field.text('by_name'),
  ],
);

const notesCollection = CollectionSchema(
  name: IpdCol.notes,
  owner: 'ipd',
  description: 'Bedside notes and vitals.',
  writePermissions: {IpdPerms.notes},
  fields: [
    Field.ref('admission_id', IpdCol.admissions, required: true, indexed: true),
    Field.ref('patient_id', Col.patients),
    Field.text('kind'), // progress | nursing | vitals | handover
    Field.text('text'),
    Field.json('vitals'), // {bp_sys, bp_dia, pulse, temp_c, spo2, rr, grbs}
    Field.text('by_name'),
    // When the observation was made (defaults to when it was saved).
    Field.dateTime('recorded_at', indexed: true),
  ],
);

const ipdCollections = [wardsCollection, bedsCollection, admissionsCollection, transfersCollection, notesCollection];

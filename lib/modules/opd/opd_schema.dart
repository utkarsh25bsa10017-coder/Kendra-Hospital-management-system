import 'package:kendra_hms/core/core.dart';

abstract final class OpdPerms {
  static const consult = 'opd.consult';
  static const vitals = 'opd.vitals';
  static const viewNotes = 'opd.view_notes';
}

abstract final class OpdCol {
  static const consultations = 'consultations';
  static const amendments = 'clinical_amendments';
}

abstract final class ConsultStatus {
  static const draft = 'draft';
  static const signed = 'signed';
}

/// One clinical note per OPD visit. Starts as a draft (the nurse may add
/// vitals first), is autosaved while the doctor writes, and is signed when
/// the doctor finishes. After that it changes only through amendments.
const consultationsCollection = CollectionSchema(
  name: OpdCol.consultations,
  owner: 'opd',
  description: 'OPD consultation notes: vitals, complaint, examination, diagnosis and the drafts of '
      'medicines and tests. Signed notes are changed only through clinical_amendments.',
  writePermissions: {OpdPerms.consult, OpdPerms.vitals},
  compositeIndexes: [
    ['patient_id', 'started_at'],
    ['doctor_id', 'status'],
  ],
  fields: [
    Field('encounter_id', FieldType.ref, required: true, unique: true, indexed: true, refCollection: Col.encounters),
    Field.ref('patient_id', Col.patients, required: true),
    Field.ref('doctor_id', Col.users, required: true),
    Field.dateTime('started_at', indexed: true), // when the visit's note was opened
    // {bp_sys, bp_dia, pulse, temp_c, spo2, rr, weight_kg, height_cm, bmi, grbs}
    Field.json('vitals'),
    Field.dateTime('vitals_at', indexed: true),
    Field.text('vitals_by_name'),
    Field.text('chief_complaint', searchable: true),
    Field.text('history'),
    Field.text('examination'),
    Field.text('diagnosis', indexed: true, searchable: true),
    Field.text('icd_code'),
    Field.text('notes'),
    Field.text('advice'),
    Field.dateTime('follow_up_date'),
    // [{medicine_id?, drug_name, generic_name, form, dose, frequency, duration_days, route, instructions, quantity}]
    Field.json('rx_draft'),
    // [{service_code?, name, order_type, priority}]
    Field.json('orders_draft'),
    Field.text('status', required: true, indexed: true), // draft | signed
    Field.dateTime('signed_at', indexed: true),
    Field.ref('signed_by', Col.users),
    Field.text('signed_by_name'),
    Field.text('prescription_id'),
    Field.dateTime('amended_at'),
  ],
);

/// Every change to a signed note: who, why, and the old and new text.
const amendmentsCollection = CollectionSchema(
  name: OpdCol.amendments,
  owner: 'opd',
  description: 'Corrections to signed consultation notes, with the reason and the old and new values.',
  writePermissions: {OpdPerms.consult},
  fields: [
    Field.ref('consultation_id', OpdCol.consultations, required: true),
    Field.ref('patient_id', Col.patients),
    Field.text('reason', required: true),
    Field.json('changes'), // [{field, old, new}]
    Field.text('amended_by_name'),
  ],
);

import 'package:kendra_hms/core/core.dart';

import 'appointment_service.dart';

/// Weekly OPD sessions: one row per doctor, weekday and session
/// (e.g. Dr. Khan, Monday 9:00 AM – 1:00 PM, 15-minute slots, Room 3).
const doctorSchedulesCollection = CollectionSchema(
  name: ApptCol.schedules,
  owner: 'appointments',
  description: 'Weekly OPD sessions per doctor. Appointment slots are generated from these.',
  writePermissions: {AppointmentPerms.schedules},
  fields: [
    Field.ref('doctor_id', Col.users, required: true),
    Field.integer('weekday', indexed: true), // 1 = Monday … 7 = Sunday
    Field.integer('start_minute'), // minutes from midnight, e.g. 540 = 9:00 AM
    Field.integer('end_minute'),
    Field.integer('slot_minutes'),
    Field.text('room'),
    Field.boolean('active'),
  ],
);

/// Booked, walk-in and follow-up appointments. Once a patient is checked in
/// the visit itself is a core `encounters` row (the OPD queue) and the
/// appointment status follows it.
const appointmentsCollection = CollectionSchema(
  name: ApptCol.appointments,
  owner: 'appointments',
  description: 'OPD appointments. encounter_id links to the visit once the patient is checked in.',
  // Board members may approve the "mark missed appointments as no-show" suggestion.
  writePermissions: {AppointmentPerms.manage, CorePerms.approvalsDecide},
  compositeIndexes: [
    ['doctor_id', 'start_at'],
    ['patient_id', 'start_at'],
  ],
  fields: [
    Field.ref('patient_id', Col.patients, required: true),
    Field.ref('doctor_id', Col.users, required: true),
    Field.dateTime('start_at', required: true, indexed: true),
    Field.dateTime('end_at'),
    Field.text('kind'), // booked | walk_in | follow_up
    Field.text('status', indexed: true), // booked | checked_in | in_consultation | completed | cancelled | no_show
    Field.ref('encounter_id', Col.encounters),
    Field.integer('token_no'),
    Field.text('reason'),
    Field.text('notes'),
    Field.text('booked_via'), // phone | front_desk | follow_up
    Field.text('cancel_reason'),
  ],
);

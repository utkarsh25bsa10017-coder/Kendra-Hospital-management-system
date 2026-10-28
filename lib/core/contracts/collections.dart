/// Contract collections: the shared tables every module may read and write.
///
/// They live in core (not in any one module) so a module can be removed
/// without breaking the others. Modules talk to each other only through
/// these tables, never by importing each other's code. For example OPD writes
/// a row to [Col.charges] and Billing picks it up; if Billing is switched off
/// the charges simply wait.
///
/// Money is ALWAYS an integer number of paise (`*_paise`).
library;

import '../data/schema.dart';
import 'permissions.dart';

abstract final class Col {
  static const users = 'users';
  static const roles = 'roles';
  static const settings = 'settings';
  static const userPrefs = 'user_prefs';
  static const notifications = 'notifications';
  static const findings = 'findings';
  static const proposals = 'proposals';
  static const suppressions = 'suppressions';
  static const approvals = 'approvals';
  static const patients = 'patients';
  static const encounters = 'encounters';
  static const charges = 'charges';
  static const services = 'services';
  static const serviceOrders = 'service_orders';
  static const prescriptions = 'prescriptions';
  static const medicines = 'medicines';
}

/// Value sets used across modules.
abstract final class Vals {
  // encounters.type
  static const opd = 'opd';
  static const ipd = 'ipd';
  static const emergency = 'emergency';
  // encounters.status
  static const open = 'open';
  static const closed = 'closed';
  static const cancelled = 'cancelled';
  // charges.status
  static const pending = 'pending';
  static const billed = 'billed';
  // charges.category / services.category
  static const consultation = 'consultation';
  static const lab = 'lab';
  static const radiology = 'radiology';
  static const pharmacy = 'pharmacy';
  static const procedure = 'procedure';
  static const bed = 'bed';
  static const nursing = 'nursing';
  static const other = 'other';
  static const chargeCategories = [consultation, lab, radiology, pharmacy, procedure, bed, nursing, other];
  // service_orders.status
  static const ordered = 'ordered';
  static const collected = 'collected';
  static const inProgress = 'in_progress';
  static const resulted = 'resulted';
  static const verified = 'verified';
  // encounters.queue_status
  static const waiting = 'waiting';
  static const withDoctor = 'with_doctor';
  static const done = 'done';
  static const left = 'left';
  // prescriptions.status
  static const active = 'active';
  static const partiallyDispensed = 'partially_dispensed';
  static const dispensed = 'dispensed';
}

const coreCollections = <CollectionSchema>[
  medicinesCollection,
  CollectionSchema(
    name: Col.users,
    description: 'Staff accounts. id is generated; username is unique and lower-case.',
    writePermissions: {CorePerms.adminUsers},
    fields: [
      Field.text('username', required: true, unique: true, searchable: true),
      Field.text('display_name', required: true, searchable: true),
      Field.json('role_ids'), // ["doctor", ...]
      Field.text('password_hash', sensitive: true),
      Field.text('password_salt', sensitive: true),
      Field.integer('password_iterations'),
      Field.boolean('active', indexed: true),
      Field.integer('failed_attempts'),
      Field.dateTime('locked_until'),
      Field.boolean('must_change_password'),
      Field.dateTime('last_login_at'),
      Field.boolean('is_clinician', indexed: true), // shows up in doctor pickers
      Field.text('department', searchable: true),
      Field.text('specialization'),
      Field.text('registration_no'),
      Field.integer('consultation_fee_paise'),
      Field.integer('discount_limit_paise'), // discounts/refunds up to this need no approval
      Field.text('phone'),
      Field.text('email'),
    ],
  ),
  CollectionSchema(
    name: Col.roles,
    description: 'id is the role id (e.g. "doctor").',
    writePermissions: {CorePerms.adminRoles},
    fields: [
      Field.text('name', required: true),
      Field.text('description'),
      Field.json('permissions'), // ["billing.invoice", ...] or ["*"]
      Field.boolean('builtin'),
      Field.boolean('customized'),
      Field.json('known_permissions'),
    ],
  ),
  CollectionSchema(
    name: Col.settings,
    description: 'Hospital-wide settings. id is the key (see SettingKeys).',
    writePermissions: {CorePerms.adminSettings, CorePerms.agentsManage, CorePerms.adminModules},
    fields: [Field.json('value')],
  ),
  CollectionSchema(
    name: Col.userPrefs,
    description: 'Per-user preferences. id is the user id.',
    fields: [
      Field.json('seen_tour_steps'),
      Field.text('theme_mode'), // system | light | dark
      Field.text('last_route'),
    ],
  ),
  CollectionSchema(
    name: Col.notifications,
    fields: [
      Field.ref('user_id', Col.users, required: true),
      Field.text('title', required: true),
      Field.text('body'),
      Field.text('severity'), // info | low | medium | high | critical
      Field.text('route_id'),
      Field.json('route_args'),
      Field.boolean('read', indexed: true),
      Field.text('kind'), // finding | approval | proposal | briefing | system
    ],
  ),
  CollectionSchema(
    name: Col.findings,
    description: 'Problems raised by agents, decided by people in the control tower.',
    fields: [
      Field.text('agent_id', required: true, indexed: true),
      Field.text('module_id'),
      Field.text('fingerprint', required: true, unique: true),
      Field.text('subject_key', indexed: true),
      Field.text('title', required: true, searchable: true),
      Field.text('summary', searchable: true),
      Field.text('severity', required: true, indexed: true),
      Field.text('category', indexed: true),
      Field.integer('amount_at_risk_paise'),
      Field.ref('patient_id', Col.patients),
      Field.json('evidence'), // [{label, collection, id, route_id, route_args}]
      Field.text('status', required: true, indexed: true), // open|confirmed|assigned|dismissed|resolved|cleared
      Field.ref('assigned_to', Col.users),
      Field.ref('decided_by', Col.users),
      Field.dateTime('decided_at'),
      Field.text('decision_note'),
      Field.dateTime('first_seen_at'),
      Field.dateTime('last_seen_at', indexed: true),
      Field.integer('occurrences'),
      Field.json('data'),
    ],
  ),
  CollectionSchema(
    name: Col.proposals,
    description: 'Actions an agent suggests. Nothing happens until a person approves.',
    fields: [
      Field.text('agent_id', required: true, indexed: true),
      Field.text('module_id'),
      Field.text('fingerprint', required: true, unique: true),
      Field.text('handler', required: true),
      Field.text('title', required: true, searchable: true),
      Field.text('summary'),
      Field.json('payload'),
      Field.text('severity'),
      Field.text('required_permission'),
      Field.text('status', required: true, indexed: true), // pending|approved|rejected|failed|expired
      Field.ref('decided_by', Col.users),
      Field.dateTime('decided_at'),
      Field.text('decision_note'),
      Field.text('result'),
    ],
  ),
  CollectionSchema(
    name: Col.suppressions,
    description: '"Don\'t flag this again" rules created when a finding is dismissed.',
    fields: [
      Field.text('agent_id', required: true, indexed: true),
      Field.text('subject_key', required: true),
      Field.text('reason'),
      Field.boolean('active', indexed: true),
      Field.text('created_by_name'),
    ],
  ),
  CollectionSchema(
    name: Col.approvals,
    description: 'Discount / refund / exception requests. The requester can never approve their own.',
    fields: [
      Field.text('type', required: true, indexed: true), // e.g. billing.discount
      Field.text('status', required: true, indexed: true), // pending|approved|applied|rejected|cancelled|failed
      Field.text('title', required: true, searchable: true),
      Field.integer('amount_paise'),
      Field.ref('requested_by', Col.users, required: true),
      Field.text('requested_by_name'),
      Field.text('reason'),
      Field.text('subject_collection'),
      Field.text('subject_id', indexed: true),
      Field.ref('patient_id', Col.patients),
      Field.json('payload'),
      Field.integer('required_approvals'),
      Field.json('approvers'), // [{user_id, name, at, note}]
      Field.ref('rejected_by', Col.users),
      Field.text('decision_note'),
      Field.dateTime('decided_at'),
      Field.boolean('auto_approved'),
      Field.text('result'),
    ],
  ),
  CollectionSchema(
    name: Col.patients,
    description: 'One record per person. uhid is the hospital-facing id.',
    fields: [
      Field.text('uhid', required: true, unique: true, searchable: true),
      Field.text('first_name', required: true, searchable: true),
      Field.text('last_name', searchable: true),
      Field.text('full_name', indexed: true, searchable: true),
      Field.text('gender'), // male | female | other
      Field.dateTime('dob'),
      Field.integer('age_years'), // when the exact date of birth is unknown
      Field.text('phone', indexed: true, searchable: true),
      Field.text('alt_phone'),
      Field.text('email'),
      Field.text('address'),
      Field.text('city'),
      Field.text('state'),
      Field.text('pincode'),
      Field.text('blood_group'),
      Field.text('allergies'),
      Field.text('emergency_name'),
      Field.text('emergency_phone'),
      Field.text('referral_source'),
      Field.text('payer_type'), // self | insurance | corporate
      Field.text('insurer'),
      Field.text('policy_no'),
      Field.text('abha_number', searchable: true),
      Field.text('notes'),
    ],
  ),
  CollectionSchema(
    name: Col.encounters,
    description: 'One visit: an OPD consultation, an IPD stay or an emergency case.',
    compositeIndexes: [
      ['patient_id', 'started_at'],
    ],
    fields: [
      Field.ref('patient_id', Col.patients, required: true),
      Field.text('type', required: true, indexed: true), // opd | ipd | emergency
      Field.text('status', required: true, indexed: true), // open | closed | cancelled
      Field.ref('doctor_id', Col.users),
      Field.text('department'),
      Field.dateTime('started_at', required: true, indexed: true),
      Field.dateTime('ended_at'),
      Field.text('source_module'),
      Field.text('source_id', indexed: true),
      Field.text('summary'),
      // OPD queue (set by whoever checks the patient in; read by OPD).
      Field.integer('token_no'),
      Field.text('queue_status', indexed: true), // waiting | with_doctor | done | left
      Field.dateTime('checked_in_at', indexed: true),
      Field.dateTime('called_at'),
    ],
  ),
  CollectionSchema(
    name: Col.charges,
    description: 'Every billable thing that happened. Written by the module that '
        'delivered the service; turned into bill lines by Billing.',
    compositeIndexes: [
      ['patient_id', 'status'],
    ],
    fields: [
      Field.ref('patient_id', Col.patients, required: true),
      Field.ref('encounter_id', Col.encounters),
      Field.text('service_code', indexed: true),
      Field.text('description', required: true),
      Field.text('category', required: true, indexed: true),
      Field.integer('quantity'),
      Field.integer('unit_price_paise'),
      Field.integer('amount_paise', required: true),
      Field.text('source_module'),
      Field.text('source_collection'),
      Field.text('source_id', indexed: true),
      Field.text('status', required: true, indexed: true), // pending | billed | cancelled
      Field.text('invoice_id', indexed: true),
      Field.dateTime('service_date', indexed: true),
      Field.ref('ordered_by', Col.users),
      Field.text('cancel_reason'),
    ],
  ),
  CollectionSchema(
    name: Col.services,
    description: 'The price list (charge master).',
    writePermissions: {CorePerms.pricesEdit, CorePerms.adminSettings},
    fields: [
      Field.text('code', required: true, unique: true, searchable: true),
      Field.text('name', required: true, searchable: true),
      Field.text('category', required: true, indexed: true),
      Field.integer('price_paise', required: true),
      Field.text('department'),
      Field.boolean('active', indexed: true),
      Field.real('tax_percent'),
      Field.text('notes'),
    ],
  ),
  CollectionSchema(
    name: Col.serviceOrders,
    description: 'Lab, radiology and procedure orders placed by clinicians.',
    fields: [
      Field.ref('patient_id', Col.patients, required: true),
      Field.ref('encounter_id', Col.encounters),
      Field.text('order_type', required: true, indexed: true), // lab | radiology | procedure
      Field.text('service_code', indexed: true),
      Field.text('name', required: true, searchable: true),
      Field.text('status', required: true, indexed: true),
      Field.text('priority'), // routine | urgent | stat
      Field.ref('ordered_by', Col.users),
      Field.dateTime('ordered_at', required: true, indexed: true),
      Field.text('clinical_notes'),
      Field.text('sample_id', indexed: true),
      Field.dateTime('collected_at'),
      Field.text('result_summary'),
      Field.dateTime('resulted_at'),
      Field.ref('verified_by', Col.users),
      Field.dateTime('verified_at'),
      Field.boolean('abnormal'),
      Field.boolean('critical', indexed: true),
      Field.text('charge_id'),
    ],
  ),
  CollectionSchema(
    name: Col.prescriptions,
    description: 'Medicines prescribed in an encounter; dispensed by Pharmacy.',
    fields: [
      Field.ref('patient_id', Col.patients, required: true),
      Field.ref('encounter_id', Col.encounters),
      Field.ref('doctor_id', Col.users),
      // [{drug_name, product_id, dose, frequency, duration_days, route, instructions, quantity, dispensed_qty}]
      Field.json('items'),
      Field.text('status', required: true, indexed: true),
      Field.text('notes'),
      Field.dateTime('dispensed_at'),
    ],
  ),
];

/// The medicine master list. Doctors prescribe from it (OPD); Pharmacy keeps
/// stock against it. Either module can be switched off without the other.
const medicinesCollection = CollectionSchema(
  name: Col.medicines,
  description: 'Drug master: one row per medicine strength and form.',
  writePermissions: {'pharmacy.catalog', CorePerms.adminSettings},
  fields: [
    Field.text('name', required: true, searchable: true), // brand or common name, e.g. "Dolo 650"
    Field.text('generic_name', searchable: true), // e.g. "Paracetamol"
    Field.text('form'), // tablet | capsule | syrup | injection | ointment | drops | inhaler | other
    Field.text('strength'), // e.g. "650 mg"
    Field.text('unit'), // dispensing unit: tablet, ml, vial, tube...
    Field.text('schedule'), // OTC | H | H1 | X
    Field.text('default_dose'), // e.g. "1 tablet"
    Field.text('default_frequency'), // e.g. "1-0-1"
    Field.boolean('active', indexed: true),
  ],
);

/// Known keys in the `settings` collection.
abstract final class SettingKeys {
  static const hospitalName = 'hospital.name';
  static const hospitalAddress = 'hospital.address';
  static const hospitalPhone = 'hospital.phone';
  static const hospitalGstin = 'hospital.gstin';
  static const uhidPrefix = 'uhid.prefix';
  static const modulesEnabled = 'modules.enabled';
  static const agentsDisabled = 'agents.disabled';
  static const highValueLimitPaise = 'approvals.high_value_limit_paise';
  static const briefingHour = 'tower.briefing_hour';
  static const idleLockMinutes = 'security.idle_lock_minutes';
  static const setupComplete = 'setup.complete';
}

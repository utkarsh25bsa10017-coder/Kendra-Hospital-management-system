import 'package:kendra_hms/core/core.dart';

abstract final class LabPerms {
  static const view = 'lab.view';
  static const collect = 'lab.collect';
  static const result = 'lab.result';
  static const verify = 'lab.verify';
  static const order = 'lab.order';
  static const catalog = 'lab.catalog';
  static const acknowledge = 'lab.acknowledge';
}

abstract final class LabCol {
  static const tests = 'lab_tests';
  static const results = 'lab_results';
}

/// lab_results.status
abstract final class ResultStatus {
  static const entered = 'entered';
  static const verified = 'verified';

  /// A verified report was changed; it waits for verification again.
  static const amended = 'amended';
}

abstract final class Priority {
  static const routine = 'routine';
  static const urgent = 'urgent';
  static const stat = 'stat';
  static const all = [routine, urgent, stat];

  static int rank(String? p) => switch (p) { stat => 0, urgent => 1, _ => 2 };
  static String label(String? p) => switch (p) { stat => 'STAT', urgent => 'Urgent', _ => 'Routine' };
}

const labDepartments = <(String, String)>[
  ('haematology', 'Haematology'),
  ('biochemistry', 'Biochemistry'),
  ('serology', 'Serology'),
  ('microbiology', 'Microbiology'),
  ('clinical_pathology', 'Clinical pathology'),
];

String departmentLabel(String? d) {
  for (final (id, label) in labDepartments) {
    if (id == d) return label;
  }
  return titleCase(d ?? '');
}

/// The test catalogue. `code` is the same as the core `services` code, which
/// holds the price.
const labTestsCollection = CollectionSchema(
  name: LabCol.tests,
  owner: 'lab',
  description: 'Lab tests with their parameters, units and reference ranges.',
  writePermissions: {LabPerms.catalog},
  fields: [
    Field.text('code', required: true, unique: true, searchable: true),
    Field.text('name', required: true, searchable: true),
    Field.text('department', indexed: true),
    Field.text('sample_type'),
    Field.text('container'),
    Field.integer('tat_minutes'),
    // [{key, name, short, unit, low, high, female_low, female_high,
    //   critical_low, critical_high, ref_text, kind, choices, decimals}]
    Field.json('parameters'),
    Field.boolean('active', indexed: true),
  ],
);

/// One result set per order. Values keep the flag and range that applied
/// when they were entered, so old reports read the same forever.
const labResultsCollection = CollectionSchema(
  name: LabCol.results,
  owner: 'lab',
  description: 'Entered and verified lab results.',
  writePermissions: {LabPerms.result, LabPerms.verify, LabPerms.acknowledge},
  fields: [
    Field('order_id', FieldType.ref, refCollection: Col.serviceOrders, required: true, unique: true),
    Field.ref('patient_id', Col.patients),
    Field.text('test_code', indexed: true),
    // [{key, name, value, numeric, unit, flag, ref}]
    Field.json('values'),
    Field.text('status', required: true, indexed: true),
    Field.ref('entered_by', Col.users),
    Field.text('entered_by_name'),
    Field.dateTime('entered_at', indexed: true),
    Field.ref('verified_by', Col.users),
    Field.text('verified_by_name'),
    Field.dateTime('verified_at', indexed: true),
    Field.text('comments'),
    Field.boolean('critical', indexed: true),
    Field.ref('acknowledged_by', Col.users),
    Field.text('acknowledged_by_name'),
    Field.dateTime('acknowledged_at'),
    Field.text('acknowledge_note'),
    Field.text('amend_reason'),
    // Previous versions, oldest first: [{values, comments, entered_by_name, ...}]
    Field.json('history'),
  ],
);

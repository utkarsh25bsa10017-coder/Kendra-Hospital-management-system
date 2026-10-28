import 'package:kendra_hms/core/core.dart';

import 'briefing.dart';
import 'tower_data.dart';

/// Decisions the board made over the past week, one "don't flag this again"
/// rule and yesterday's briefing, so the history screens have something to
/// show. Live findings come from the other modules' agents.
Future<void> seedDemoTower(ModuleContext ctx) async {
  final sys = ctx.systemDb;
  final users = await sys.query(const Query(Col.users).take(100));
  Rec? user(String username) => users.where((u) => u.str('username') == username).firstOrNull;
  final board = user('board');
  if (board == null) return;
  final pharmacist = user('pharmacy');

  // Written as the board member, so the audit log shows who decided.
  final db = Db(
    ctx.services.store,
    () => Actor(
      id: board.id,
      name: board.str('display_name'),
      permissions: const {'*'},
      deviceId: ctx.services.config.deviceId,
    ),
  );

  final patients = await sys.query(const Query(Col.patients).sort('created_at').take(12));
  String? pid(int i) => patients.isEmpty ? null : patients[i % patients.length].id;
  List<Map<String, Object?>> patientEvidence(int i) {
    if (patients.isEmpty) return const [];
    final p = patients[i % patients.length];
    return [
      Evidence('${p.str('full_name')} · ${p.str('uhid')}',
              collection: Col.patients, id: p.id, routeId: 'patients.profile', routeArgs: {'id': p.id})
          .toJson(),
    ];
  }

  final now = DateTime.now();
  DateTime ago(int days, [int hours = 0]) => now.subtract(Duration(days: days, hours: hours));

  final rows = <Map<String, Object?>>[
    {
      'agent_id': 'billing.discounts',
      'module_id': 'billing',
      'key': 'discount:demo-118',
      'subject_key': 'user:${user('billing')?.id ?? 'billing'}',
      'title': 'Discount above the cashier\'s limit on a pharmacy bill',
      'summary': 'A ₹1,800 discount was given on a ₹6,200 bill. The cashier\'s limit is ₹500 and no approval '
          'was asked for.',
      'severity': 'high',
      'category': 'discounts',
      'amount_at_risk_paise': 180000,
      'patient': 0,
      'status': FindingStatus.confirmed,
      'note': 'Recover the difference and remind billing to ask for approval.',
      'seen': ago(6, 3),
      'decided': ago(5, 20),
    },
    {
      'agent_id': 'billing.bill_matching',
      'module_id': 'billing',
      'key': 'rate:demo-arthroscopy',
      'subject_key': 'service:ORTHO-ARTH-PKG',
      'title': 'Knee arthroscopy billed below the tariff',
      'summary': 'Billed at ₹42,000 against a tariff of ₹55,000 for a self-paying patient.',
      'severity': 'medium',
      'category': 'pricing',
      'amount_at_risk_paise': 1300000,
      'patient': 1,
      'status': FindingStatus.dismissed,
      'note': 'Approved package rate',
      'suppress': true,
      'seen': ago(5, 6),
      'decided': ago(5, 2),
    },
    {
      'agent_id': 'billing.bill_matching',
      'module_id': 'billing',
      'key': 'leak:demo-cbc',
      'title': 'Lab test done but never billed: Complete blood count',
      'summary': 'The result was verified two days ago and there is no charge for it.',
      'severity': 'medium',
      'category': 'leakage',
      'amount_at_risk_paise': 35000,
      'patient': 2,
      'status': FindingStatus.resolved,
      'note': 'Charge added to the patient\'s bill.',
      'seen': ago(4, 5),
      'decided': ago(3, 22),
    },
    {
      'agent_id': 'admin.access',
      'module_id': 'admin',
      'key': 'access:demo-night',
      'title': 'Patient record opened at 2:40 AM by a front-desk account',
      'summary': 'The account opened 6 records between 2:30 and 3:00 AM.',
      'severity': 'low',
      'category': 'access',
      'patient': 3,
      'status': FindingStatus.dismissed,
      'note': 'Doctor\'s instruction',
      'seen': ago(3, 8),
      'decided': ago(3, 1),
    },
    {
      'agent_id': 'pharmacy.stock',
      'module_id': 'pharmacy',
      'key': 'expiry:demo-amox',
      'title': 'Expired stock still on the shelf: Amoxicillin 500 mg',
      'summary': '40 capsules from batch AMX2203 expired last month and have not been written off.',
      'severity': 'medium',
      'category': 'stock',
      'amount_at_risk_paise': 64000,
      'status': pharmacist == null ? FindingStatus.confirmed : FindingStatus.assigned,
      'assigned_to': pharmacist?.id,
      'note': 'Please remove from the shelf and record the write-off.',
      'seen': ago(2, 7),
      'decided': ago(2, 2),
    },
    {
      'agent_id': 'billing.discounts',
      'module_id': 'billing',
      'key': 'refund:demo-cash',
      'title': 'Cash refund without a cancelled bill',
      'summary': 'A ₹2,500 cash refund was recorded but the original bill is still active.',
      'severity': 'high',
      'category': 'refunds',
      'amount_at_risk_paise': 250000,
      'patient': 4,
      'status': FindingStatus.resolved,
      'note': 'Bill cancelled with a credit note. Data entry slip.',
      'seen': ago(1, 9),
      'decided': ago(1, 4),
    },
  ];

  final ops = <WriteOp>[];
  for (final r in rows) {
    final i = r['patient'] as int?;
    final decided = r['decided'] as DateTime;
    ops.add(InsertOp(Col.findings, {
      'agent_id': r['agent_id'],
      'module_id': r['module_id'],
      'fingerprint': '${r['agent_id']}:${r['key']}',
      'subject_key': r['subject_key'] ?? r['key'],
      'title': r['title'],
      'summary': r['summary'],
      'severity': r['severity'],
      'category': r['category'],
      'amount_at_risk_paise': r['amount_at_risk_paise'],
      'patient_id': i == null ? null : pid(i),
      'evidence': i == null ? const [] : patientEvidence(i),
      'status': r['status'],
      'assigned_to': r['assigned_to'],
      'decided_by': board.id,
      'decided_at': decided,
      'decision_note': r['note'],
      'first_seen_at': r['seen'],
      'last_seen_at': r['seen'],
      'occurrences': 1,
      'data': const {'demo': true},
    }));
    if (r['suppress'] == true) {
      ops.add(InsertOp(Col.suppressions, {
        'agent_id': r['agent_id'],
        'subject_key': r['subject_key'] ?? r['key'],
        'reason': r['note'],
        'active': true,
        'created_by_name': board.str('display_name'),
      }));
    }
  }
  await db.batch(ops);

  // Yesterday's briefing, as it would have gone out at the briefing hour.
  final hour = ctx.services.settings.briefingHour;
  final yesterday = startOfDay(now).subtract(const Duration(days: 1)).add(Duration(hours: hour));
  final summary = await Briefings.buildSummary(sys, ctx.services, now: yesterday);
  await sys.insert(briefingsCol, {'briefing_date': dayKey(yesterday), 'summary': summary, 'sent_at': yesterday});
}

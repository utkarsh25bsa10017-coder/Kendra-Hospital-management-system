import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

/// A stand-in for the billing and pharmacy modules, used only in the tower
/// tests: two agents that raise findings of every severity and two
/// suggestions, plus a few approval requests in its demo data.
class FakeChecksModule extends HmsModule {
  final appliedApprovals = <String>[];
  final ranProposals = <String>[];

  @override
  String get id => 'checks';
  @override
  String get name => 'Billing checks';
  @override
  String get description => 'Test module';
  @override
  IconData get icon => Icons.fact_check_outlined;

  @override
  List<HmsAgent> get agents => [FakeBillAgent(), FakeStockAgent()];

  @override
  Map<String, ProposalHandler> get proposalHandlers => {
        'checks.reorder': (ctx, p, db) async {
          ranProposals.add(p.id);
          return 'Purchase order PO-0043 created';
        },
        'checks.add_charge': (ctx, p, db) async {
          ranProposals.add(p.id);
          return 'Charge added to the bill';
        },
      };

  @override
  Map<String, ApprovalHandler> get approvalHandlers => {
        'billing.discount': (ctx, a, db) async {
          appliedApprovals.add(a.id);
          return 'Discount of ${formatMoney(a.integer('amount_paise'))} applied';
        },
        'billing.refund': (ctx, a, db) async {
          appliedApprovals.add(a.id);
          return 'Refund of ${formatMoney(a.integer('amount_paise'))} recorded';
        },
      };

  @override
  Future<void> seedDemo(ModuleContext ctx) async {
    final db = ctx.systemDb;
    final users = await db.query(const Query(Col.users).take(50));
    Rec user(String u) => users.firstWhere((r) => r.str('username') == u);
    final billing = user('billing');
    final board = user('board');
    final owner = user('owner');
    final patients = await db.query(const Query(Col.patients).sort('created_at').take(8));
    final now = DateTime.now();
    Map<String, Object?> base(Rec by, String type, String title, int paise, {String? reason, int patient = 0}) => {
          'type': type,
          'title': title,
          'amount_paise': paise,
          'requested_by': by.id,
          'requested_by_name': by.str('display_name'),
          'reason': reason,
          'subject_collection': 'invoices',
          'subject_id': 'inv-$patient',
          'patient_id': patients[patient % patients.length].id,
          'payload': {'invoice_number': title.split(' ').last},
        };
    await db.batch([
      InsertOp(Col.approvals, {
        ...base(billing, 'billing.discount', 'Discount on INV-2026-0151', 120000,
            reason: 'Senior citizen, regular patient for ten years', patient: 5),
        'status': 'pending',
        'required_approvals': 1,
        'approvers': const [],
      }),
      InsertOp(Col.approvals, {
        ...base(billing, 'billing.refund', 'Refund for cancelled MRI on INV-2026-0147', 1450000,
            reason: 'MRI cancelled because the machine is down. The patient paid in advance.', patient: 6),
        'status': 'pending',
        'required_approvals': 2,
        'approvers': [
          {
            'user_id': owner.id,
            'name': owner.str('display_name'),
            'at': now.subtract(const Duration(hours: 2)).toIso8601String(),
            'note': 'Checked with radiology',
          },
        ],
      }),
      InsertOp(Col.approvals, {
        ...base(board, 'billing.discount', 'Staff family discount on INV-2026-0149', 300000,
            reason: 'My mother\'s cataract surgery, under the staff family scheme', patient: 7),
        'status': 'pending',
        'required_approvals': 1,
        'approvers': const [],
      }),
      InsertOp(Col.approvals, {
        ...base(billing, 'billing.discount', 'Rounding off on INV-2026-0144', 4000, patient: 1),
        'status': 'applied',
        'auto_approved': true,
        'required_approvals': 0,
        'approvers': const [],
        'result': 'Discount of ₹40.00 applied',
        'decided_at': now.subtract(const Duration(days: 1)),
      }),
      InsertOp(Col.approvals, {
        ...base(billing, 'billing.discount', 'Discount on INV-2026-0139', 250000, reason: 'Patient asked', patient: 2),
        'status': 'rejected',
        'required_approvals': 1,
        'approvers': const [],
        'rejected_by': board.id,
        'decision_note': 'Not justified',
        'decided_at': now.subtract(const Duration(days: 2)),
      }),
      InsertOp(Col.approvals, {
        ...base(billing, 'billing.refund', 'Refund for duplicate lab charge on INV-2026-0131', 90000, patient: 3),
        'status': 'applied',
        'required_approvals': 1,
        'approvers': [
          {'user_id': board.id, 'name': board.str('display_name'), 'at': now.subtract(const Duration(days: 3)).toIso8601String()},
        ],
        'result': 'Refund of ₹900.00 recorded',
        'decided_at': now.subtract(const Duration(days: 3)),
      }),
      InsertOp(Col.proposals, {
        'agent_id': 'checks.stock',
        'module_id': 'checks',
        'fingerprint': 'checks.stock:demo-po-42',
        'handler': 'checks.reorder',
        'title': 'Reorder 2 medicines from Sai Distributors',
        'summary': 'Both run out within a week at the current rate.',
        'payload': const {'supplier': 'Sai Distributors'},
        'severity': 'low',
        'required_permission': CorePerms.approvalsDecide,
        'status': 'approved',
        'decided_by': board.id,
        'decided_at': now.subtract(const Duration(days: 2)),
        'result': 'Purchase order PO-0042 created',
      }),
    ]);
  }
}

Evidence _patient(Rec p) => Evidence('${p.str('full_name')} · ${p.str('uhid')}',
    collection: Col.patients, id: p.id, routeId: 'patients.profile', routeArgs: {'id': p.id});

class FakeBillAgent extends HmsAgent {
  @override
  String get id => 'checks.bill_matching';
  @override
  String get name => 'Bill matching';
  @override
  String get description => 'Checks every bill line against the service delivered, the tariff and the discount limit.';
  @override
  Duration get interval => const Duration(hours: 1);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final p = await ctx.db.query(const Query(Col.patients).sort('created_at').take(6));
    return AgentReport(
      findings: [
        FindingDraft(
          key: 'inv:0142',
          title: 'Discount above the cashier\'s limit on INV-2026-0142',
          summary: 'Vikram Singh gave ₹2,400 off a ₹10,000 bill (24%). His limit is ₹500 and no approval was asked for.',
          severity: Severity.critical,
          category: 'discounts',
          amountAtRiskPaise: 240000,
          patientId: p[0].id,
          subjectKey: 'user:billing',
          evidence: [
            const Evidence('Bill INV-2026-0142', collection: 'invoices', id: 'inv-0142', routeId: 'billing.invoice', routeArgs: {'id': 'inv-0142'}),
            _patient(p[0]),
          ],
        ),
        FindingDraft(
          key: 'leak:lipid',
          title: 'Lab test done but never billed: Lipid profile',
          summary: 'The result was verified yesterday at 4:10 PM and there is no charge for it on any bill.',
          severity: Severity.high,
          category: 'leakage',
          amountAtRiskPaise: 85000,
          patientId: p[1].id,
          evidence: [
            const Evidence('Lab order LAB-3381', collection: 'service_orders', id: 'lab-3381', routeId: 'lab.order', routeArgs: {'id': 'lab-3381'}),
            _patient(p[1]),
          ],
        ),
        FindingDraft(
          key: 'refund:cash',
          title: 'Cash refund without a cancelled bill',
          summary: 'A ₹1,500 cash refund was recorded at 9:40 PM but the original bill is still active.',
          severity: Severity.high,
          category: 'refunds',
          amountAtRiskPaise: 150000,
          patientId: p[2].id,
          evidence: [_patient(p[2])],
        ),
        FindingDraft(
          key: 'rate:consult',
          title: 'Consultation billed below the tariff',
          summary: 'Charged ₹300 against the ₹500 tariff for Dr. Farah Khan, with no discount recorded.',
          severity: Severity.medium,
          category: 'pricing',
          amountAtRiskPaise: 20000,
          patientId: p[3].id,
          evidence: [_patient(p[3])],
        ),
        FindingDraft(
          key: 'late:discharge',
          title: 'Bill finalised three days after discharge',
          summary: 'Late bills are harder to collect. The patient was discharged on Tuesday.',
          severity: Severity.low,
          category: 'timeliness',
          patientId: p[4].id,
          evidence: [_patient(p[4])],
        ),
      ],
      proposals: [
        ProposalDraft(
          key: 'charge:lipid',
          title: 'Add the missed Lipid profile charge',
          summary: 'Adds the charge to ${p[1].str('full_name')}\'s open bill at the tariff rate.',
          handler: 'checks.add_charge',
          severity: Severity.high,
          payload: {'patient': p[1].str('full_name'), 'patient_id': p[1].id, 'service': 'Lipid profile', 'amount_paise': 85000},
        ),
      ],
    );
  }
}

class FakeStockAgent extends HmsAgent {
  @override
  String get id => 'checks.stock';
  @override
  String get name => 'Pharmacy and stock';
  @override
  String get description => 'Compares stock movements with sales and counts, and suggests purchase orders before medicines run out.';
  @override
  Set<String> get watches => const {Col.prescriptions};
  @override
  Duration get interval => const Duration(hours: 2);

  @override
  Future<AgentReport> run(AgentContext ctx) async => const AgentReport(
        findings: [
          FindingDraft(
            key: 'count:panto',
            title: 'Stock count mismatch: Pantoprazole 40 mg',
            summary: 'The shelf count is 140 tablets short of the system stock. No sale or return explains it.',
            severity: Severity.high,
            category: 'stock',
            amountAtRiskPaise: 64000,
          ),
          FindingDraft(
            key: 'expiry:ceftri',
            title: 'Expiring within 30 days: Ceftriaxone 1 g injections',
            summary: '22 vials from batch CF2291 expire on 20 November. Use them first or return them to the supplier.',
            severity: Severity.medium,
            category: 'expiry',
            amountAtRiskPaise: 121000,
          ),
        ],
        proposals: [
          ProposalDraft(
            key: 'po:medline',
            title: 'Reorder 3 medicines from MedLine Pharma',
            summary: 'At the current rate these run out in 4 to 6 days.',
            handler: 'checks.reorder',
            payload: {
              'supplier': 'MedLine Pharma',
              'items': [
                {'medicine': 'Pantoprazole 40 mg', 'qty': 300, 'rate_paise': 450, 'amount_paise': 135000},
                {'medicine': 'Paracetamol 650 mg', 'qty': 500, 'rate_paise': 120, 'amount_paise': 60000},
                {'medicine': 'Ceftriaxone 1 g', 'qty': 40, 'rate_paise': 5500, 'amount_paise': 220000},
              ],
              'total_paise': 415000,
              'deliver_by': '2026-10-27',
            },
          ),
        ],
      );
}

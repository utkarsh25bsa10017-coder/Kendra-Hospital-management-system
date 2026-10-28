import 'package:kendra_hms/core/core.dart';

/// The control tower's own table: one morning briefing per day.
const briefingsCol = 'tower_briefings';

const towerBriefingsCollection = CollectionSchema(
  name: briefingsCol,
  owner: 'tower',
  description: 'The board\'s morning briefing: what the agents found since the last one.',
  writePermissions: {CorePerms.towerView},
  fields: [
    Field.text('briefing_date', required: true, unique: true), // yyyy-MM-dd
    Field.json('summary'),
    Field.dateTime('sent_at', indexed: true),
  ],
);

/// Finding statuses, in the order the filter chips show them.
abstract final class FindingStatus {
  static const open = 'open';
  static const confirmed = 'confirmed';
  static const assigned = 'assigned';
  static const dismissed = 'dismissed';
  static const resolved = 'resolved';
  static const cleared = 'cleared';

  static const all = [open, confirmed, assigned, dismissed, resolved, cleared];

  /// Not fixed and not dismissed: the money is still at risk.
  static const unfixed = [open, confirmed, assigned];

  static String label(String s) => switch (s) {
        open => 'Open',
        confirmed => 'Confirmed',
        assigned => 'Assigned',
        dismissed => 'Dismissed',
        resolved => 'Resolved',
        cleared => 'Cleared',
        _ => sentenceCase(s),
      };

  static Tone tone(String s) => switch (s) {
        open => Tone.warning,
        confirmed => Tone.danger,
        assigned => Tone.info,
        resolved || cleared => Tone.success,
        _ => Tone.neutral,
      };
}

/// Highest first: critical, high, medium, low, info.
int severityRank(String? s) => Severity.parse(s).index;

/// Sorts findings for triage: most severe first, then the most recent.
List<Rec> sortForTriage(Iterable<Rec> findings) => findings.toList()
  ..sort((a, b) {
    final s = severityRank(b.str('severity')).compareTo(severityRank(a.str('severity')));
    if (s != 0) return s;
    final bt = b.date('last_seen_at') ?? b.createdAt;
    final at = a.date('last_seen_at') ?? a.createdAt;
    return bt.compareTo(at);
  });

String sentenceCase(String s) {
  final t = s.replaceAll('_', ' ').trim();
  return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
}

/// Agent names by id, from every installed module (also switched-off ones,
/// so old findings still show a readable name).
Map<String, String> agentNames(AppServices app) => {
      for (final m in app.registry.all)
        for (final a in m.agents) a.id: a.name,
    };

/// A readable name for an agent id, even if no installed module has it.
String agentLabel(Map<String, String> names, String agentId) =>
    names[agentId] ?? sentenceCase(agentId.contains('.') ? agentId.split('.').last : agentId);

/// Screens that show records of well-known collections. Links are only shown
/// when the module that owns the screen is switched on.
const _subjectRoutes = <String, String>{
  Col.patients: 'patients.profile',
  'invoices': 'billing.invoice',
  'billing_invoices': 'billing.invoice',
  'pharmacy_products': 'pharmacy.product',
  'products': 'pharmacy.product',
  Col.serviceOrders: 'lab.order',
  'lab_orders': 'lab.order',
  'admissions': 'ipd.admission',
  'ipd_admissions': 'ipd.admission',
  'consultations': 'opd.consultation',
  'opd_consultations': 'opd.consultation',
};

const _subjectNames = <String, String>{
  Col.patients: 'Patient',
  'invoices': 'Bill',
  'billing_invoices': 'Bill',
  'pharmacy_products': 'Medicine',
  'products': 'Medicine',
  Col.serviceOrders: 'Order',
  'lab_orders': 'Lab order',
  'admissions': 'Admission',
  'ipd_admissions': 'Admission',
  'consultations': 'Consultation',
  'opd_consultations': 'Consultation',
  Col.charges: 'Charge',
  Col.encounters: 'Visit',
};

/// Route id that opens a record of [collection], if that screen exists.
String? routeForCollection(AppServices app, String? collection) {
  final r = _subjectRoutes[collection];
  return r != null && app.registry.route(r) != null ? r : null;
}

String subjectName(String? collection) =>
    _subjectNames[collection] ?? (collection == null ? 'Record' : sentenceCase(collection));

/// "Discount", "Refund", "Write-off"... from an approval type like `billing.discount`.
String approvalTypeLabel(String type) => switch (type.split('.').last) {
      'discount' => 'Discount',
      'refund' => 'Refund',
      'write_off' || 'writeoff' => 'Write-off',
      'credit_note' => 'Credit note',
      'cancel' || 'cancellation' => 'Cancellation',
      final t => sentenceCase(t),
    };

/// "Approved", "Rejected"... for an approval's status.
(String, Tone) approvalOutcome(Rec a) {
  if (a.flag('auto_approved')) return ('Within own limit', Tone.info);
  return switch (a.str('status')) {
    'pending' => ('Waiting', Tone.warning),
    'approved' => ('Approved', Tone.success),
    'applied' => ('Approved and applied', Tone.success),
    'rejected' => ('Rejected', Tone.danger),
    'cancelled' => ('Withdrawn', Tone.neutral),
    'failed' => ('Approved, not applied', Tone.danger),
    final s => (sentenceCase(s), Tone.neutral),
  };
}

/// "1 of 2 approvals".
String approvalProgress(Rec a) {
  final need = a.integer('required_approvals', 1);
  final have = a.maps('approvers').length;
  return need <= 1 && have == 0 ? 'Needs 1 approval' : '$have of $need approvals';
}

(String, Tone) proposalOutcome(Rec p) => switch (p.str('status')) {
      'pending' => ('Waiting', Tone.warning),
      'approved' => ('Approved', Tone.success),
      'rejected' => ('Rejected', Tone.neutral),
      'failed' => ('Failed', Tone.danger),
      'expired' => ('No longer needed', Tone.neutral),
      final s => (sentenceCase(s), Tone.neutral),
    };

/// Things a person can do with a finding in its current state.
enum FindingAction { confirm, dismiss, assign, fix, reopen }

/// The rules for which buttons a finding shows. The real checks are in
/// core's [TowerService]; this only hides buttons that would be refused.
Set<FindingAction> findingActions(Session? s, Rec f) {
  if (s == null) return const {};
  final decide = s.can(CorePerms.towerDecide);
  final assignee = f.strOrNull('assigned_to') == s.userId;
  return switch (f.str('status')) {
    FindingStatus.open => {
        if (decide) ...{FindingAction.confirm, FindingAction.dismiss, FindingAction.assign, FindingAction.fix},
      },
    FindingStatus.confirmed => {
        if (decide) ...{FindingAction.assign, FindingAction.fix, FindingAction.dismiss, FindingAction.reopen},
      },
    FindingStatus.assigned => {
        if (decide || assignee) FindingAction.fix,
        if (decide) ...{FindingAction.assign, FindingAction.reopen},
      },
    FindingStatus.dismissed || FindingStatus.resolved => {if (decide) FindingAction.reopen},
    _ => const {},
  };
}

/// What the screens call when someone decides. These are thin on purpose:
/// the rules (permissions, reasons, the requester rule, two approvals for
/// large amounts) live in core's TowerService and ApprovalService so they
/// apply on every device.
abstract final class TowerDecisions {
  static const dismissPresets = [
    'Approved package rate',
    'Doctor\'s instruction',
    'Data entry already corrected',
    'Not a problem',
  ];

  static const rejectPresets = [
    'Not justified',
    'Needs more detail',
    'Above what we allow',
  ];

  static String? _clean(String? note) => (note == null || note.trim().isEmpty) ? null : note.trim();

  static Future<Rec> confirm(AppServices app, Rec finding, {String? note}) async =>
      app.tower.confirm(finding, note: _clean(note));

  /// [dontFlagAgain] also creates a suppression so the agent learns.
  static Future<Rec> dismiss(AppServices app, Rec finding, {required String reason, bool dontFlagAgain = false}) async =>
      app.tower.dismiss(finding, reason: reason.trim(), suppress: dontFlagAgain);

  static Future<Rec> assign(AppServices app, Rec finding, String userId, {String? note}) async =>
      app.tower.assign(finding, userId, note: _clean(note));

  static Future<Rec> markFixed(AppServices app, Rec finding, {String? note}) async =>
      app.tower.resolve(finding, note: _clean(note));

  static Future<Rec> reopen(AppServices app, Rec finding) async => app.tower.reopen(finding);

  /// Null if the signed-in person may approve [approval], else why not.
  static String? whyCannotApprove(AppServices app, Rec approval) {
    final s = app.auth.session;
    if (s == null) return 'Please sign in again';
    return app.approvals.whyCannotApprove(approval, s.userId, s.can(CorePerms.approvalsDecide));
  }

  /// Null if the signed-in person may reject [approval], else why not.
  static String? whyCannotReject(AppServices app, Rec approval) {
    final s = app.auth.session;
    if (s == null) return 'Please sign in again';
    if (!s.can(CorePerms.approvalsDecide)) return 'You do not have permission to decide requests';
    if (approval.str('status') != 'pending') return 'This request is no longer pending';
    if (approval.str('requested_by') == s.userId) return 'You cannot decide your own request';
    return null;
  }

  static Future<Rec> approve(AppServices app, Rec approval, {String? note}) async =>
      app.approvals.approve(approval, note: _clean(note));

  static Future<Rec> reject(AppServices app, Rec approval, {required String reason}) async {
    if (reason.trim().isEmpty) throw ValidationException('Say why it is not approved');
    return app.approvals.reject(approval, note: reason.trim());
  }

  static bool canDecideProposal(AppServices app, Rec p) =>
      p.str('status') == 'pending' && app.auth.can(p.strOrNull('required_permission') ?? CorePerms.approvalsDecide);

  static Future<Rec> approveProposal(AppServices app, Rec proposal, {String? note}) async =>
      app.tower.approveProposal(proposal, note: _clean(note));

  static Future<Rec> rejectProposal(AppServices app, Rec proposal, {String? note}) async =>
      app.tower.rejectProposal(proposal, note: _clean(note));
}

/// Numbers for the control tower's top row.
class TowerKpis {
  const TowerKpis({
    required this.openUrgent,
    required this.openTotal,
    required this.atRiskPaise,
    required this.approvalsWaiting,
    required this.suggestionsWaiting,
  });
  final int openUrgent;
  final int openTotal;
  final int atRiskPaise;
  final int approvalsWaiting;
  final int suggestionsWaiting;

  static Future<TowerKpis> load(ReadDb db) async {
    const f = Query(Col.findings);
    return TowerKpis(
      openUrgent: await db.count(f.eq('status', FindingStatus.open).isIn('severity', ['critical', 'high'])),
      openTotal: await db.count(f.eq('status', FindingStatus.open)),
      atRiskPaise: (await db.sum(f.isIn('status', FindingStatus.unfixed), 'amount_at_risk_paise')).toInt(),
      approvalsWaiting: await db.count(const Query(Col.approvals).eq('status', 'pending')),
      suggestionsWaiting: await db.count(const Query(Col.proposals).eq('status', 'pending')),
    );
  }
}

/// Findings first seen on each of the last [days] days (oldest first).
Future<List<(DateTime, int)>> findingsPerDay(ReadDb db, {int days = 14, DateTime? now}) async {
  final today = startOfDay(now ?? DateTime.now());
  final from = today.subtract(Duration(days: days - 1));
  final rows = await db.aggregate(AggQuery.of(
    const Query(Col.findings).gte('first_seen_at', from).withArchived(),
    groupByDay: 'first_seen_at',
  ));
  final byDay = {for (final r in rows) r.key as String?: r.count};
  return [
    for (var i = 0; i < days; i++)
      (from.add(Duration(days: i)), byDay[dayKey(from.add(Duration(days: i)))] ?? 0),
  ];
}

/// Short labels when bars are narrow ("24"), longer ones when there is room ("24 Oct").
List<String> dayLabels(List<DateTime> days, double width) {
  final roomy = days.isEmpty ? false : width / days.length >= 44;
  return [for (final d in days) roomy ? formatDateShort(d) : '${d.day}'];
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';
import '../widgets/tower_widgets.dart';
import 'decision_flows.dart';

/// Discounts, refunds and other exceptions waiting for the board, and the
/// history of what was decided.
class ApprovalsScreen extends StatelessWidget {
  const ApprovalsScreen({super.key, this.highlightId});
  final String? highlightId;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: PageScaffold(
        title: 'Approvals',
        subtitle: 'Requests above the staff member\'s own limit. Nobody can approve their own.',
        scrollable: false,
        headerBottom: LiveBuilder<int>(
          watch: const {Col.approvals},
          loading: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [Tab(text: 'Waiting'), Tab(text: 'History')]),
          load: (db) => db.count(const Query(Col.approvals).eq('status', 'pending')),
          builder: (context, n) => TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: n == 0 ? 'Waiting' : 'Waiting ($n)'), const Tab(text: 'History')],
          ),
        ),
        body: TabBarView(children: [_Pending(highlightId: highlightId), const _History()]),
      ),
    );
  }
}

class _PendingData {
  const _PendingData(this.pending, this.patients, this.highlighted);
  final List<Rec> pending;
  final Map<String, Rec> patients;

  /// The request a link pointed at, when it is no longer waiting.
  final Rec? highlighted;
}

class _Pending extends StatelessWidget {
  const _Pending({this.highlightId});
  final String? highlightId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_PendingData>(
      watch: const {Col.approvals},
      deps: [highlightId],
      load: (db) async {
        final pending = [...await db.query(const Query(Col.approvals).eq('status', 'pending').sort('created_at').take(100))];
        final i = pending.indexWhere((a) => a.id == highlightId);
        if (i > 0) pending.insert(0, pending.removeAt(i));
        final other = (highlightId != null && i < 0) ? await db.get(Col.approvals, highlightId) : null;
        final patients = await db.byIds(Col.patients, [for (final a in pending) a.strOrNull('patient_id')]);
        return _PendingData(pending, patients, other);
      },
      builder: (context, d) {
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (d.highlighted != null) ...[
                SectionCard(
                  child: InlineNote(
                    '"${d.highlighted!.str('title')}" was already decided: ${approvalOutcome(d.highlighted!).$1.toLowerCase()}. '
                    'See the History tab.',
                  ),
                ),
                Gap.v16,
              ],
              if (d.pending.isEmpty)
                const EmptyState(
                  icon: Icons.how_to_reg_outlined,
                  title: 'No requests waiting',
                  message: 'When staff ask for a discount or refund above their limit, it appears here.',
                )
              else
                TourAnchor(
                  id: 'tower.approvals_list',
                  child: ResponsiveGrid(
                    minWidth: 440,
                    maxColumns: 2,
                    children: [
                      for (final a in d.pending)
                        _ApprovalCard(
                          approval: a,
                          patient: d.patients[a.strOrNull('patient_id')],
                          highlighted: a.id == highlightId,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.approval, required this.patient, required this.highlighted});
  final Rec approval;
  final Rec? patient;
  final bool highlighted;

  static String? _subjectLabel(Rec a) {
    final payload = a.map('payload');
    for (final k in ['invoice_number', 'invoice_no', 'bill_no', 'number', 'receipt_no']) {
      final v = payload[k];
      if (v is String && v.isNotEmpty) return '${subjectName(a.strOrNull('subject_collection'))} $v';
    }
    return a.strOrNull('subject_collection') == null ? null : subjectName(a.strOrNull('subject_collection'));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = approval;
    final blocked = TowerDecisions.whyCannotApprove(app, a);
    final rejectBlocked = TowerDecisions.whyCannotReject(app, a);
    final subjectRoute = routeForCollection(app, a.strOrNull('subject_collection'));
    final subjectLabel = _subjectLabel(a);
    final need = a.integer('required_approvals', 1);
    final approvers = a.maps('approvers');

    final card = SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    StatusChip(approvalTypeLabel(a.str('type')), tone: Tone.board),
                    StatusChip(approvalProgress(a), tone: need > 1 ? Tone.warning : Tone.neutral),
                  ],
                ),
              ),
              Gap.h8,
              MoneyText(a.integer('amount_paise'), style: theme.textTheme.titleLarge),
            ],
          ),
          Gap.v12,
          Text(a.str('title'), style: theme.textTheme.titleMedium),
          Gap.v4,
          Text('Asked by ${a.str('requested_by_name', 'staff')} · ${formatRelative(a.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (a.str('reason').isNotEmpty) ...[
            Gap.v12,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(left: BorderSide(color: cs.outline, width: 3)),
              ),
              child: Text(a.str('reason'), style: theme.textTheme.bodyMedium),
            ),
          ],
          if (subjectLabel != null || patient != null) ...[
            Gap.v8,
            if (subjectLabel != null)
              LinkRow(
                icon: Icons.receipt_long_outlined,
                label: subjectLabel,
                caption: subjectRoute == null ? 'Its module is switched off' : null,
                onTap: subjectRoute == null || a.strOrNull('subject_id') == null
                    ? null
                    : () => app.nav.open(subjectRoute, {'id': a.str('subject_id')}),
              ),
            if (patient != null)
              LinkRow(
                icon: Icons.person_outline,
                label: '${patient!.str('full_name')} · ${patient!.str('uhid')}',
                onTap: () => app.nav.open('patients.profile', {'id': patient!.id}),
              ),
          ],
          for (final ap in approvers) ...[
            Gap.v8,
            InlineNote(
              [
                'Approved by ${ap['name'] ?? 'a board member'}',
                if (ap['at'] is String) formatRelative(DateTime.tryParse(ap['at'] as String)?.toLocal()),
                if ((ap['note'] as String?)?.isNotEmpty ?? false) '"${ap['note']}"',
              ].join(' · '),
              icon: Icons.check_circle_outline,
              tone: Tone.success,
            ),
          ],
          Gap.v16,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              FilledButton.icon(
                onPressed: blocked == null ? () => DecisionFlows.approve(context, a) : null,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Approve'),
              ),
              OutlinedButton.icon(
                onPressed: rejectBlocked == null ? () => DecisionFlows.reject(context, a) : null,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Reject'),
              ),
            ],
          ),
          if (blocked != null) ...[Gap.v8, InlineNote(blocked, icon: Icons.block)],
        ],
      ),
    );
    if (!highlighted) return card;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: cs.primary, width: 2),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: card,
    );
  }
}

class _HistoryData {
  const _HistoryData(this.items, this.users);
  final List<Rec> items;
  final Map<String, Rec> users;
}

class _History extends StatelessWidget {
  const _History();

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_HistoryData>(
      watch: const {Col.approvals},
      load: (db) async {
        final items = await db.query(const Query(Col.approvals).neq('status', 'pending').sort('updated_at', desc: true).take(100));
        final users = await db.byIds(Col.users, [for (final a in items) a.strOrNull('rejected_by')]);
        return _HistoryData(items, users);
      },
      builder: (context, d) {
        String decidedBy(Rec a) {
          if (a.flag('auto_approved')) return 'Within ${a.str('requested_by_name', 'their')}\'s own limit';
          if (a.str('status') == 'rejected') {
            return 'Rejected by ${d.users[a.strOrNull('rejected_by')]?.str('display_name') ?? 'a board member'}';
          }
          if (a.str('status') == 'cancelled') return 'Withdrawn by the requester';
          final names = [for (final ap in a.maps('approvers')) ap['name']].whereType<String>();
          return names.isEmpty ? '—' : names.join(', ');
        }

        String note(Rec a) => a.str('status') == 'rejected' ? a.str('decision_note') : a.str('result');

        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl),
          child: DataList<Rec>(
            items: d.items,
            empty: const EmptyState(icon: Icons.history, title: 'Nothing decided yet'),
            title: (a) => a.str('title'),
            subtitle: (a) => [
              approvalTypeLabel(a.str('type')),
              formatMoney(a.integer('amount_paise')),
              a.str('requested_by_name'),
              decidedBy(a),
              formatDate(a.date('decided_at') ?? a.updatedAt),
              if (note(a).isNotEmpty) note(a),
            ].where((s) => s.isNotEmpty).join(' · '),
            trailing: (a) => StatusChip(approvalOutcome(a).$1, tone: approvalOutcome(a).$2),
            columns: [
              ListColumn('Request', (a) => TwoLine(a.str('title'), '${approvalTypeLabel(a.str('type'))} · asked by ${a.str('requested_by_name', 'staff')}'), flex: 5),
              ListColumn('Amount', (a) => MoneyText(a.integer('amount_paise')), numeric: true),
              ListColumn('Decision', (a) => TwoLine(decidedBy(a), note(a)), flex: 4),
              ListColumn('When', (a) => Text(formatDate(a.date('decided_at') ?? a.updatedAt))),
              ListColumn('Outcome', (a) => StatusChip(approvalOutcome(a).$1, tone: approvalOutcome(a).$2), width: 190),
            ],
          ),
        );
      },
    );
  }
}

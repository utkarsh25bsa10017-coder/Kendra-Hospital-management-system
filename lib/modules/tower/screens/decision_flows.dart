import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';

/// The dialogs around each decision. Every write goes through
/// [TowerDecisions], which calls core's TowerService / ApprovalService.
abstract final class DecisionFlows {
  static String _short(Rec r) {
    final t = r.str('title');
    return t.length > 60 ? '${t.substring(0, 57)}…' : t;
  }

  static Future<bool> confirm(BuildContext context, Rec finding) {
    final app = context.app;
    return runGuarded(context, () => TowerDecisions.confirm(app, finding),
        success: 'Confirmed: ${_short(finding)}');
  }

  static Future<bool> dismiss(BuildContext context, Rec finding) async {
    final app = context.app;
    final r = await showDialog<(String, bool)>(context: context, builder: (c) => _DismissDialog(finding: finding));
    if (r == null || !context.mounted) return false;
    final (reason, suppress) = r;
    return runGuarded(
      context,
      () => TowerDecisions.dismiss(app, finding, reason: reason, dontFlagAgain: suppress),
      success: suppress ? 'Dismissed. The agent will not flag this again.' : 'Dismissed: ${_short(finding)}',
    );
  }

  static Future<bool> assign(BuildContext context, Rec finding) async {
    final app = context.app;
    final user = await pickRecord(
      context,
      title: 'Assign to',
      query: (s) => const Query(Col.users).eq('active', true).matching(s).sort('display_name').take(50),
      itemTitle: (u) => u.str('display_name'),
      itemSubtitle: (u) => [
        u.list<String>('role_ids').map((r) => Roles.template(r)?.name ?? sentenceCase(r)).join(', '),
        u.str('department'),
      ].where((s) => s.isNotEmpty).join(' · '),
      emptyText: 'No active staff match',
    );
    if (user == null || !context.mounted) return false;
    return runGuarded(context, () => TowerDecisions.assign(app, finding, user.id),
        success: 'Assigned to ${user.str('display_name')}. They have been notified.');
  }

  static Future<bool> markFixed(BuildContext context, Rec finding) {
    final app = context.app;
    return runGuarded(context, () => TowerDecisions.markFixed(app, finding), success: 'Marked fixed: ${_short(finding)}');
  }

  static Future<bool> reopen(BuildContext context, Rec finding) {
    final app = context.app;
    return runGuarded(context, () => TowerDecisions.reopen(app, finding), success: 'Reopened: ${_short(finding)}');
  }

  static Future<bool> run(BuildContext context, FindingAction action, Rec finding) => switch (action) {
        FindingAction.confirm => confirm(context, finding),
        FindingAction.dismiss => dismiss(context, finding),
        FindingAction.assign => assign(context, finding),
        FindingAction.fix => markFixed(context, finding),
        FindingAction.reopen => reopen(context, finding),
      };

  // ------------------------------------------------------------ approvals

  /// [askNote] shows a small dialog for an optional note first.
  static Future<bool> approve(BuildContext context, Rec approval, {bool askNote = true}) async {
    final app = context.app;
    String? note;
    if (askNote) {
      final r = await showDialog<String>(
        context: context,
        builder: (c) => _NoteDialog(
          title: 'Approve ${approvalTypeLabel(approval.str('type')).toLowerCase()} of ${formatMoney(approval.integer('amount_paise'))}?',
          message: approval.str('title'),
          confirmLabel: 'Approve',
        ),
      );
      if (r == null || !context.mounted) return false;
      note = r;
    }
    final need = approval.integer('required_approvals', 1);
    final have = approval.maps('approvers').length + 1;
    return runGuarded(
      context,
      () => TowerDecisions.approve(app, approval, note: note),
      success: have < need ? 'Approved. It needs ${need - have} more approval from another board member.' : 'Approved',
    );
  }

  static Future<bool> reject(BuildContext context, Rec approval) async {
    final app = context.app;
    final reason = await reasonDialog(
      context,
      title: 'Reject this request?',
      message: '${approval.str('title')} · ${formatMoney(approval.integer('amount_paise'))}. '
          '${approval.str('requested_by_name', 'The requester')} will see your reason.',
      presets: TowerDecisions.rejectPresets,
      confirmLabel: 'Reject',
      destructive: true,
    );
    if (reason == null || !context.mounted) return false;
    return runGuarded(context, () => TowerDecisions.reject(app, approval, reason: reason), success: 'Rejected');
  }

  // ------------------------------------------------------------ proposals

  static Future<bool> approveProposal(BuildContext context, Rec proposal) async {
    final app = context.app;
    Rec? done;
    final ok = await runGuarded(context, () async => done = await TowerDecisions.approveProposal(app, proposal));
    if (!ok || done == null) return false;
    final failed = done!.str('status') == 'failed';
    app.nav.toast(failed ? done!.str('result') : (done!.strOrNull('result') ?? 'Approved'), error: failed);
    return !failed;
  }

  static Future<bool> rejectProposal(BuildContext context, Rec proposal) async {
    final app = context.app;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => _NoteDialog(
        title: 'Reject this suggestion?',
        message: proposal.str('title'),
        confirmLabel: 'Reject',
        hint: 'Why not? (optional)',
        destructive: true,
      ),
    );
    if (r == null || !context.mounted) return false;
    return runGuarded(context, () => TowerDecisions.rejectProposal(app, proposal, note: r), success: 'Suggestion rejected');
  }
}

/// Dismiss with a reason, and optionally tell the agent not to flag this
/// subject again.
class _DismissDialog extends StatefulWidget {
  const _DismissDialog({required this.finding});
  final Rec finding;

  @override
  State<_DismissDialog> createState() => _DismissDialogState();
}

class _DismissDialogState extends State<_DismissDialog> {
  final _ctrl = TextEditingController();
  bool _suppress = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Dismiss this finding?'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.finding.str('title'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Gap.v8,
              Text('Your reason is recorded and helps the agents learn.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Gap.v12,
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final p in TowerDecisions.dismissPresets)
                    ChoiceChip(
                      label: Text(p),
                      selected: _ctrl.text == p,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _ctrl.text = p),
                    ),
                ],
              ),
              Gap.v12,
              TextField(
                controller: _ctrl,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              Gap.v8,
              CheckboxListTile(
                value: _suppress,
                onChanged: (v) => setState(() => _suppress = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Don\'t flag this again'),
                subtitle: const Text('The agent stops raising this for the same subject. You can undo it on the Agents screen.'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, (_ctrl.text.trim(), _suppress)) : null,
          child: const Text('Dismiss'),
        ),
      ],
    );
  }
}

/// A confirmation with an optional note. Returns the note ('' if none) or
/// null when cancelled.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.hint = 'Note (optional)',
    this.destructive = false,
  });
  final String title;
  final String message;
  final String confirmLabel;
  final String hint;
  final bool destructive;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            Gap.v12,
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: widget.hint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: widget.destructive ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

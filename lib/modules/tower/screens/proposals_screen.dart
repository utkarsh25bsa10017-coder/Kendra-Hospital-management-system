import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';
import '../widgets/tower_widgets.dart';
import 'decision_flows.dart';

/// Actions the agents prepared ("reorder these 4 medicines"). Nothing
/// happens until a person approves.
class ProposalsScreen extends StatelessWidget {
  const ProposalsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: PageScaffold(
        title: 'Agent suggestions',
        subtitle: 'The agents did the legwork. Nothing happens until you approve.',
        scrollable: false,
        headerBottom: LiveBuilder<int>(
          watch: const {Col.proposals},
          loading: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [Tab(text: 'Waiting'), Tab(text: 'History')]),
          load: (db) => db.count(const Query(Col.proposals).eq('status', 'pending')),
          builder: (context, n) => TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: n == 0 ? 'Waiting' : 'Waiting ($n)'), const Tab(text: 'History')],
          ),
        ),
        body: const TabBarView(children: [_Pending(), _History()]),
      ),
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending();

  @override
  Widget build(BuildContext context) {
    final names = agentNames(context.app);
    return LiveBuilder<List<Rec>>(
      watch: const {Col.proposals},
      load: (db) => db.query(const Query(Col.proposals).eq('status', 'pending').sort('created_at').take(100)),
      builder: (context, items) => SingleChildScrollView(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl),
        child: items.isEmpty
            ? const EmptyState(
                icon: Icons.lightbulb_outline,
                title: 'No suggestions waiting',
                message: 'When an agent prepares something for you, such as a purchase order, it appears here.',
              )
            : ResponsiveGrid(
                minWidth: 440,
                maxColumns: 2,
                children: [for (final p in items) _ProposalCard(proposal: p, agent: agentLabel(names, p.str('agent_id')))],
              ),
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.proposal, required this.agent});
  final Rec proposal;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = proposal;
    final payload = p.map('payload');
    final can = TowerDecisions.canDecideProposal(app, p);
    final handlerOn = app.registry.proposalHandler(p.str('handler')) != null;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const ToneIcon(Icons.lightbulb_outline, tone: Tone.agent, size: 32),
            Gap.h12,
            Expanded(
              child: Text('From $agent · ${formatRelative(p.updatedAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            if (severityRank(p.str('severity')) >= Severity.medium.index) SeverityChip(p.str('severity')),
          ]),
          Gap.v12,
          Text(p.str('title'), style: theme.textTheme.titleMedium),
          if (p.str('summary').isNotEmpty) ...[
            Gap.v4,
            Text(p.str('summary'), style: theme.textTheme.bodyMedium),
          ],
          if (payload.isNotEmpty) ...[Gap.v12, PayloadView(payload)],
          Gap.v16,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              FilledButton.icon(
                onPressed: can && handlerOn ? () => DecisionFlows.approveProposal(context, p) : null,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Approve'),
              ),
              OutlinedButton.icon(
                onPressed: can ? () => DecisionFlows.rejectProposal(context, p) : null,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Reject'),
              ),
            ],
          ),
          if (!handlerOn) ...[
            Gap.v8,
            const InlineNote('The module that carries this out is switched off, so it cannot be approved now.', icon: Icons.block),
          ] else if (!can) ...[
            Gap.v8,
            const InlineNote('You do not have permission to approve this suggestion.', icon: Icons.block),
          ],
        ],
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History();

  @override
  Widget build(BuildContext context) {
    final names = agentNames(context.app);
    return LiveBuilder<(List<Rec>, Map<String, Rec>)>(
      watch: const {Col.proposals},
      load: (db) async {
        final items = await db.query(const Query(Col.proposals).neq('status', 'pending').sort('updated_at', desc: true).take(100));
        return (items, await db.byIds(Col.users, [for (final p in items) p.strOrNull('decided_by')]));
      },
      builder: (context, data) {
        final (items, users) = data;
        String by(Rec p) {
          final u = users[p.strOrNull('decided_by')]?.str('display_name');
          return switch (p.str('status')) {
            'expired' => 'Withdrawn by the agent',
            _ => u == null ? '—' : '${proposalOutcome(p).$1} by $u',
          };
        }

        String result(Rec p) => p.str('result').isNotEmpty ? p.str('result') : p.str('decision_note');
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl),
          child: DataList<Rec>(
            items: items,
            empty: const EmptyState(icon: Icons.history, title: 'Nothing decided yet'),
            title: (p) => p.str('title'),
            subtitle: (p) => [
              agentLabel(names, p.str('agent_id')),
              by(p),
              formatDate(p.date('decided_at') ?? p.updatedAt),
              if (result(p).isNotEmpty) result(p),
            ].join(' · '),
            trailing: (p) => StatusChip(proposalOutcome(p).$1, tone: proposalOutcome(p).$2),
            columns: [
              ListColumn('Suggestion', (p) => TwoLine(p.str('title'), agentLabel(names, p.str('agent_id'))), flex: 5),
              ListColumn('Decision', (p) => TwoLine(by(p), formatDateTime(p.date('decided_at') ?? p.updatedAt)), flex: 3),
              ListColumn('Result', (p) => Text(result(p).isEmpty ? '—' : result(p), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 4),
              ListColumn('Outcome', (p) => StatusChip(proposalOutcome(p).$1, tone: proposalOutcome(p).$2), width: 150),
            ],
          ),
        );
      },
    );
  }
}

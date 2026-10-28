import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';
import '../widgets/tower_widgets.dart';

/// Every monitoring agent, whether it is on, how its last run went, and the
/// subjects the board told the agents to ignore.
class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PageScaffold(
      title: 'Agents',
      subtitle: 'They read the data and report problems. None of them can change anything.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (app.agents == null) ...[
            const SectionCard(
              child: InlineNote(
                'Agents run on the hub device. Their findings appear here as soon as they are raised.',
                icon: Icons.dns_outlined,
              ),
            ),
            Gap.v16,
          ],
          const TourAnchor(id: 'tower.agents_list', child: _AgentList()),
          Gap.v24,
          const _Suppressions(),
        ],
      ),
    );
  }
}

class _AgentList extends StatelessWidget {
  const _AgentList();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final groups = <String, (HmsModule, List<HmsAgent>)>{};
    for (final (m, a) in app.registry.agents) {
      groups.putIfAbsent(m.id, () => (m, <HmsAgent>[])).$2.add(a);
    }
    if (groups.isEmpty) {
      return const EmptyState(
        icon: Icons.smart_toy_outlined,
        title: 'No agents installed',
        message: 'Modules such as Billing and Pharmacy bring their own agents when they are switched on.',
      );
    }
    return LiveBuilder<Map<String, int>>(
      watch: const {Col.findings},
      load: (db) async {
        final rows = await db.aggregate(AggQuery.of(const Query(Col.findings).eq('status', FindingStatus.open), groupBy: 'agent_id'));
        return {for (final r in rows) '${r.key}': r.count};
      },
      builder: (context, open) => ListenableBuilder(
        listenable: app.settings,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (m, agents) in groups.values) ...[
              SubHeading(m.name),
              ResponsiveGrid(
                minWidth: 380,
                maxColumns: 2,
                children: [for (final a in agents) _AgentCard(agent: a, openFindings: open[a.id] ?? 0)],
              ),
              Gap.v16,
            ],
          ],
        ),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.agent, required this.openFindings});
  final HmsAgent agent;
  final int openFindings;

  static bool isEnabled(AppServices app, HmsAgent a) {
    final runner = app.agents;
    if (runner != null) return runner.isEnabled(a);
    if (app.settings.list(SettingKeys.agentsDisabled).contains(a.id)) return false;
    return a.enabledByDefault || app.settings.list('agents.enabled').contains(a.id);
  }

  Future<void> _toggle(BuildContext context, bool on) async {
    final app = context.app;
    final a = agent;
    final disabled = app.settings.list(SettingKeys.agentsDisabled).toSet();
    final enabled = app.settings.list('agents.enabled').toSet();
    final wasEnabled = enabled.contains(a.id);
    if (on) {
      disabled.remove(a.id);
      if (!a.enabledByDefault) enabled.add(a.id);
    } else {
      disabled.add(a.id);
      enabled.remove(a.id);
    }
    await runGuarded(
      context,
      () async {
        await app.settings.set(app.db, SettingKeys.agentsDisabled, disabled.toList()..sort());
        if (wasEnabled != enabled.contains(a.id)) {
          await app.settings.set(app.db, 'agents.enabled', enabled.toList()..sort());
        }
      },
      success: on ? '${a.name} is on' : '${a.name} is off. Its open findings stay until someone decides them.',
    );
  }

  Future<void> _runNow(BuildContext context) async {
    final app = context.app;
    final runner = app.agents;
    if (runner == null) return;
    await runner.runById(agent.id);
    final st = runner.status.value[agent.id];
    if (st?.lastError != null) {
      app.nav.toast('${agent.name} failed: ${st!.lastError}', error: true);
    } else {
      app.nav.toast('${agent.name} checked everything: ${plural(st?.findings ?? 0, 'finding')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = agent;
    final on = isEnabled(app, a);
    final canManage = context.can(CorePerms.agentsManage);
    final runner = app.agents;
    final schedule = a.watches.isEmpty
        ? 'Checks every ${formatDuration(a.interval)}'
        : 'Checks when its data changes, and every ${formatDuration(a.interval)}';

    Widget status(BuildContext context) {
      if (runner == null) return const InlineNote('Runs on the hub device', icon: Icons.dns_outlined);
      return ValueListenableBuilder(
        valueListenable: runner.status,
        builder: (context, statuses, _) {
          final st = statuses[a.id];
          if (st == null) {
            return InlineNote(on ? 'Not run yet since the app started' : 'Switched off', icon: Icons.schedule);
          }
          if (st.running) {
            return Row(children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              Gap.h8,
              Text('Checking now…', style: theme.textTheme.bodySmall),
            ]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InlineNote(
                [
                  'Last run ${formatRelative(st.lastRun)}',
                  if (st.lastDuration != null)
                    'took ${st.lastDuration!.inMilliseconds < 1000 ? '${st.lastDuration!.inMilliseconds} ms' : '${(st.lastDuration!.inMilliseconds / 1000).toStringAsFixed(1)} s'}',
                  if (st.lastError == null) plural(st.findings, 'finding'),
                  if (st.lastError == null && st.proposals > 0) plural(st.proposals, 'suggestion'),
                ].join(' · '),
                icon: st.lastError == null ? Icons.check_circle_outline : Icons.error_outline,
                tone: st.lastError == null ? Tone.success : Tone.danger,
              ),
              if (st.lastError != null) ...[
                Gap.v4,
                Text(st.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(color: ToneColors.of(context, Tone.danger).foreground),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          );
        },
      );
    }

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ToneIcon(Icons.smart_toy_outlined, tone: on ? Tone.agent : Tone.neutral),
              Gap.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name, style: theme.textTheme.titleMedium),
                    Text(schedule, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Tooltip(
                message: canManage ? (on ? 'Switch off' : 'Switch on') : 'Only board members and administrators can switch agents',
                child: Switch(value: on, onChanged: canManage ? (v) => _toggle(context, v) : null),
              ),
            ],
          ),
          Gap.v12,
          Text(a.description, style: theme.textTheme.bodyMedium),
          Gap.v12,
          status(context),
          Gap.v8,
          Row(
            children: [
              StatusChip(openFindings == 0 ? 'No open findings' : plural(openFindings, 'open finding'),
                  tone: openFindings == 0 ? Tone.success : Tone.warning),
              const Spacer(),
              if (runner != null)
                TextButton.icon(
                  onPressed: () => _runNow(context),
                  icon: const Icon(Icons.play_arrow_outlined, size: 20),
                  label: const Text('Run now'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Ignored {
  const _Ignored(this.rule, this.subject, this.example);
  final Rec rule;
  final String subject;
  final String? example;
}

/// "Don't flag this again" rules, and a way to undo them.
class _Suppressions extends StatelessWidget {
  const _Suppressions();

  static Future<String> _subjectLabel(ReadDb db, String key) async {
    final i = key.indexOf(':');
    if (i <= 0) return key;
    final kind = key.substring(0, i);
    final id = key.substring(i + 1);
    switch (kind) {
      case 'user':
        final u = await db.get(Col.users, id);
        if (u != null) return 'Staff: ${u.str('display_name')}';
      case 'patient':
        final p = await db.get(Col.patients, id);
        if (p != null) return 'Patient: ${p.str('full_name')} · ${p.str('uhid')}';
    }
    return '${sentenceCase(kind)}: $id';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final names = agentNames(app);
    final canDecide = context.can(CorePerms.towerDecide);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SectionCard(
      title: 'Ignored subjects',
      subtitle: 'Created when a board member dismissed a finding with "Don\'t flag this again"',
      child: LiveBuilder<List<_Ignored>>(
        watch: const {Col.suppressions},
        load: (db) async {
          final rules = await db.query(const Query(Col.suppressions).eq('active', true).take(100));
          return [
            for (final r in rules)
              _Ignored(
                r,
                await _subjectLabel(db, r.str('subject_key')),
                (await db.first(Query(Col.findings)
                        .eq('agent_id', r.str('agent_id'))
                        .eq('subject_key', r.str('subject_key'))
                        .sort('last_seen_at', desc: true)))
                    ?.str('title'),
              ),
          ];
        },
        builder: (context, items) {
          if (items.isEmpty) {
            return Text('Nothing is being ignored. Every agent reports everything it finds.',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, it) in items.indexed) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.md),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: Gap.md,
                    runSpacing: Gap.sm,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const ToneIcon(Icons.visibility_off_outlined, size: 32),
                            Gap.h12,
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${agentLabel(names, it.rule.str('agent_id'))} · ${it.subject}',
                                      style: theme.textTheme.titleSmall),
                                  if (it.example != null)
                                    Text('Last time: ${it.example}',
                                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                                  Gap.v4,
                                  Text(
                                    [
                                      if (it.rule.str('reason').isNotEmpty) '"${it.rule.str('reason')}"',
                                      'by ${it.rule.str('created_by_name', 'a board member')}',
                                      formatDate(it.rule.createdAt),
                                    ].join(' · '),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canDecide)
                        OutlinedButton(
                          onPressed: () => runGuarded(
                            context,
                            () => app.tower.liftSuppression(it.rule),
                            success: 'The agent will flag this again',
                          ),
                          child: const Text('Stop ignoring'),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

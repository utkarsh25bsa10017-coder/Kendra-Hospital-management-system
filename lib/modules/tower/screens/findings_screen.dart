import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';
import '../widgets/tower_widgets.dart';
import 'decision_flows.dart';

/// True while the person is typing in a text field, so single-letter
/// shortcuts don't fire.
bool _typing() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool _modifierDown() {
  final k = HardwareKeyboard.instance;
  return k.isControlPressed || k.isMetaPressed || k.isAltPressed;
}

FindingAction? _actionForKey(LogicalKeyboardKey key) => switch (key) {
      LogicalKeyboardKey.keyC => FindingAction.confirm,
      LogicalKeyboardKey.keyD => FindingAction.dismiss,
      LogicalKeyboardKey.keyA => FindingAction.assign,
      LogicalKeyboardKey.keyF => FindingAction.fix,
      _ => null,
    };

const _hints = [('J K', 'next / previous'), ('C', 'confirm'), ('D', 'dismiss'), ('A', 'assign'), ('F', 'mark fixed')];

class FindingsScreen extends StatefulWidget {
  const FindingsScreen({super.key, this.initialId});
  final String? initialId;

  @override
  State<FindingsScreen> createState() => _FindingsScreenState();
}

class _FindingsScreenState extends State<FindingsScreen> {
  String _status = FindingStatus.open;
  String? _severity;
  String? _agent;
  String _search = '';
  String? _selected;
  List<Rec> _items = const [];
  final _focus = FocusNode(debugLabel: 'tower.findings');

  @override
  void initState() {
    super.initState();
    _selected = widget.initialId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      final id = widget.initialId;
      if (id != null && !SplitView.isSplit(context)) _openPage(id);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Query _query() {
    var q = const Query(Col.findings).matching(_search);
    if (_status != 'all') q = q.eq('status', _status);
    if (_severity != null) q = q.eq('severity', _severity);
    if (_agent != null) q = q.eq('agent_id', _agent);
    return q.sort('last_seen_at', desc: true).take(200);
  }

  void _openPage(String id) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (c) => FindingPage(findingId: id)));
  }

  void _select(Rec f) {
    if (SplitView.isSplit(context)) {
      setState(() => _selected = f.id);
      _focus.requestFocus();
    } else {
      _openPage(f.id);
    }
  }

  void _move(int delta) {
    if (_items.isEmpty) return;
    final i = _items.indexWhere((f) => f.id == _selected);
    final next = (i < 0 ? 0 : i + delta).clamp(0, _items.length - 1);
    setState(() => _selected = _items[next].id);
  }

  /// After a decision, move on to the next finding (the decided one usually
  /// leaves the list).
  void _advanceFrom(String id) {
    if (_status == 'all' || !mounted) return;
    final i = _items.indexWhere((f) => f.id == id);
    if (i < 0) return;
    final next = i + 1 < _items.length ? _items[i + 1] : (i > 0 ? _items[i - 1] : null);
    setState(() => _selected = next?.id);
  }

  Future<void> _act(FindingAction action) async {
    final id = _selected;
    if (id == null) return;
    final app = context.app;
    final f = await app.readDb.get(Col.findings, id);
    if (f == null || !mounted) return;
    if (!findingActions(app.auth.session, f).contains(action)) return;
    final ok = await DecisionFlows.run(context, action, f);
    if (ok) _advanceFrom(id);
    if (mounted) _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _typing() || _modifierDown() || !SplitView.isSplit(context)) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyJ || e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyK || e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    final action = _actionForKey(e.logicalKey);
    if (action != null && _selected != null) {
      _act(action);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final split = SplitView.isSplit(context);
    final names = agentNames(context.app);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: PageScaffold(
        title: 'Findings',
        subtitle: 'Problems the agents found, with the records that prove them',
        scrollable: false,
        headerBottom: _Filters(
          status: _status,
          severity: _severity,
          agent: _agent,
          names: names,
          onSearch: (v) => setState(() => _search = v),
          onStatus: (v) => setState(() => _status = v),
          onSeverity: (v) => setState(() => _severity = v),
          onAgent: (v) => setState(() => _agent = v),
        ),
        body: LiveBuilder<List<Rec>>(
          watch: const {Col.findings},
          deps: [_status, _severity, _agent, _search],
          load: (db) async => sortForTriage(await db.query(_query())),
          builder: (context, items) {
            _items = items;
            if (split && items.isNotEmpty && (_selected == null)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _selected == null) setState(() => _selected = items.first.id);
              });
            }
            final empty = EmptyState(
              icon: Icons.verified_outlined,
              title: _status == FindingStatus.open && _search.isEmpty && _severity == null && _agent == null
                  ? 'Nothing open'
                  : 'No findings match',
              message: _status == FindingStatus.open
                  ? 'The agents keep watching. New problems show up here, critical ones straight away.'
                  : 'Try another filter.',
            );
            if (!split) {
              return SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                child: items.isEmpty ? empty : _table(context, items, names),
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 400,
                  child: items.isEmpty
                      ? SingleChildScrollView(child: empty)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: Gap.lg),
                          child: Card(
                            child: ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                              itemCount: items.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: Gap.lg, endIndent: Gap.lg),
                              itemBuilder: (c, i) => _FindingTile(
                                finding: items[i],
                                agentName: agentLabel(names, items[i].str('agent_id')),
                                selected: items[i].id == _selected,
                                onTap: () => _select(items[i]),
                              ),
                            ),
                          ),
                        ),
                ),
                Gap.h16,
                Expanded(
                  child: _selected == null
                      ? const Center(
                          child: EmptyState(icon: Icons.touch_app_outlined, title: 'Select a finding to see its evidence'))
                      : FindingDetail(
                          key: ValueKey(_selected),
                          findingId: _selected!,
                          showHints: true,
                          onAction: (a, f) async {
                            final ok = await DecisionFlows.run(context, a, f);
                            if (ok) _advanceFrom(f.id);
                            if (mounted) _focus.requestFocus();
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _table(BuildContext context, List<Rec> items, Map<String, String> names) {
    String agent(Rec f) => agentLabel(names, f.str('agent_id'));
    return DataList<Rec>(
      items: items,
      onTap: _select,
      leading: (f) => ToneIcon(Icons.flag_outlined, tone: toneForSeverity(f.str('severity'))),
      title: (f) => f.str('title'),
      subtitle: (f) => [
        Severity.parse(f.str('severity')).label,
        agent(f),
        if ((f.intOrNull('amount_at_risk_paise') ?? 0) > 0) '${formatMoneyShort(f.integer('amount_at_risk_paise'))} at risk',
        formatRelative(f.date('last_seen_at') ?? f.createdAt),
        if (f.str('status') != FindingStatus.open) FindingStatus.label(f.str('status')),
      ].join(' · '),
      columns: [
        ListColumn('Severity', (f) => SeverityChip(f.str('severity')), width: 110),
        ListColumn('Finding', (f) => TwoLine(f.str('title'), agent(f)), flex: 6),
        ListColumn('At risk',
            (f) => (f.intOrNull('amount_at_risk_paise') ?? 0) > 0 ? MoneyText(f.integer('amount_at_risk_paise')) : const Text('—'),
            numeric: true),
        ListColumn('Last seen', (f) => Text(formatRelative(f.date('last_seen_at') ?? f.createdAt), overflow: TextOverflow.ellipsis)),
        ListColumn('Status', (f) => FindingStatusChip(f.str('status')), width: 110),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.status,
    required this.severity,
    required this.agent,
    required this.names,
    required this.onSearch,
    required this.onStatus,
    required this.onSeverity,
    required this.onAgent,
  });
  final String status;
  final String? severity;
  final String? agent;
  final Map<String, String> names;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onStatus;
  final ValueChanged<String?> onSeverity;
  final ValueChanged<String?> onAgent;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return LiveBuilder<(Map<String, int>, List<String>)>(
      watch: const {Col.findings},
      deps: [severity, agent],
      loading: const SizedBox(height: 100),
      load: (db) async {
        var q = const Query(Col.findings);
        if (severity != null) q = q.eq('severity', severity);
        if (agent != null) q = q.eq('agent_id', agent);
        final byStatus = await db.aggregate(AggQuery.of(q, groupBy: 'status'));
        final byAgent = await db.aggregate(const AggQuery(Col.findings, groupBy: 'agent_id'));
        return (
          {for (final r in byStatus) '${r.key}': r.count},
          [for (final r in byAgent) '${r.key}'],
        );
      },
      builder: (context, data) {
        final (counts, agentIds) = data;
        final total = counts.values.fold<int>(0, (a, b) => a + b);
        String withCount(String label, int n) => n == 0 ? label : '$label $n';
        final severityMenu = _MenuFilter<String?>(
          icon: Icons.signal_cellular_alt,
          label: severity == null ? 'All severities' : Severity.parse(severity).label,
          active: severity != null,
          options: [
            (null, 'All severities'),
            for (final s in Severity.values.reversed) (s.name, s.label),
          ],
          onSelected: onSeverity,
        );
        final agentMenu = _MenuFilter<String?>(
          icon: Icons.smart_toy_outlined,
          label: agent == null ? 'All agents' : agentLabel(names, agent!),
          active: agent != null,
          options: [
            (null, 'All agents'),
            for (final id in ({...agentIds, ...names.keys}.toList()..sort((a, b) => agentLabel(names, a).compareTo(agentLabel(names, b)))))
              (id, agentLabel(names, id)),
          ],
          onSelected: onAgent,
        );
        final search = SearchField(hint: 'Search findings', onChanged: onSearch);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compact) ...[
              search,
              Gap.v8,
              Row(children: [Flexible(child: severityMenu), Gap.h8, Flexible(child: agentMenu)]),
            ] else
              Row(children: [
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: search),
                Gap.h12,
                Flexible(child: severityMenu),
                Gap.h8,
                Flexible(child: agentMenu),
                const Spacer(),
              ]),
            Gap.v12,
            FilterChips<String>(
              options: [
                for (final s in FindingStatus.all) (s, withCount(FindingStatus.label(s), counts[s] ?? 0)),
                ('all', withCount('All', total)),
              ],
              value: status,
              onChanged: onStatus,
            ),
          ],
        );
      },
    );
  }
}

/// A compact dropdown that looks like a filter chip.
class _MenuFilter<T> extends StatelessWidget {
  const _MenuFilter({
    required this.icon,
    required this.label,
    required this.options,
    required this.onSelected,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return PopupMenuButton<int>(
      tooltip: 'Filter',
      position: PopupMenuPosition.under,
      onSelected: (i) => onSelected(options[i].$1),
      itemBuilder: (c) => [for (final (i, o) in options.indexed) PopupMenuItem(value: i, child: Text(o.$2))],
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? cs.primaryContainer : cs.surface,
          border: Border.all(color: active ? cs.primary.withValues(alpha: 0.4) : cs.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
            Gap.h8,
            Flexible(
              child: Text(label,
                  style: theme.textTheme.labelLarge?.copyWith(color: active ? cs.onPrimaryContainer : cs.onSurface),
                  overflow: TextOverflow.ellipsis),
            ),
            Gap.h4,
            Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding, required this.agentName, required this.selected, required this.onTap});
  final Rec finding;
  final String agentName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final f = finding;
    final tone = ToneColors.of(context, toneForSeverity(f.str('severity')));
    final amount = f.intOrNull('amount_at_risk_paise') ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 2),
      child: Material(
        color: selected ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(color: tone.foreground, borderRadius: BorderRadius.circular(2)),
                ),
                Gap.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.str('title'), style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Gap.v4,
                      Text(
                        '${Severity.parse(f.str('severity')).label} · $agentName · ${formatRelative(f.date('last_seen_at') ?? f.createdAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (f.str('status') != FindingStatus.open) ...[Gap.v8, FindingStatusChip(f.str('status'))],
                    ],
                  ),
                ),
                if (amount > 0) ...[
                  Gap.h8,
                  Text(formatMoneyShort(amount),
                      style: theme.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A finding on its own page (phones and tablets).
class FindingPage extends StatefulWidget {
  const FindingPage({super.key, required this.findingId});
  final String findingId;

  @override
  State<FindingPage> createState() => _FindingPageState();
}

class _FindingPageState extends State<FindingPage> {
  final _focus = FocusNode(debugLabel: 'tower.finding');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _act(FindingAction action, [Rec? rec]) async {
    final app = context.app;
    final f = rec ?? await app.readDb.get(Col.findings, widget.findingId);
    if (f == null || !mounted) return;
    if (!findingActions(app.auth.session, f).contains(action)) return;
    final ok = await DecisionFlows.run(context, action, f);
    // Back to the list for the next one.
    if (ok && mounted && action != FindingAction.reopen) Navigator.of(context).maybePop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _typing() || _modifierDown()) return KeyEventResult.ignored;
    final action = _actionForKey(e.logicalKey);
    if (action == null) return KeyEventResult.ignored;
    _act(action);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: PageScaffold(
        title: 'Finding',
        body: FindingDetail(
          findingId: widget.findingId,
          scrollable: false,
          showHints: !context.isCompact,
          onAction: (a, f) => _act(a, f),
        ),
      ),
    );
  }
}

class _DetailData {
  const _DetailData(this.finding, this.patient, this.users, this.history);
  final Rec finding;
  final Rec? patient;
  final Map<String, Rec> users;
  final List<AuditEntry> history;
}

/// Everything about one finding, and the buttons to decide it.
class FindingDetail extends StatelessWidget {
  const FindingDetail({
    super.key,
    required this.findingId,
    required this.onAction,
    this.showHints = false,
    this.scrollable = true,
  });
  final String findingId;
  final Future<void> Function(FindingAction action, Rec finding) onAction;
  final bool showHints;

  /// False when the page around it already scrolls.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_DetailData?>(
      watch: const {Col.findings, Col.users},
      deps: [findingId],
      load: (db) async {
        final f = await db.get(Col.findings, findingId);
        if (f == null) return null;
        var history = const <AuditEntry>[];
        try {
          history = await db.store.auditLog(AuditFilter(collection: Col.findings, recordId: findingId, limit: 40));
        } catch (_) {
          // Client devices without audit access fall back to the decision fields.
        }
        final userIds = <String?>{
          f.strOrNull('assigned_to'),
          f.strOrNull('decided_by'),
          for (final h in history) ...[h.actorId, _changed(h, 'assigned_to')],
        };
        return _DetailData(
          f,
          await db.get(Col.patients, f.strOrNull('patient_id')),
          await db.byIds(Col.users, userIds),
          history,
        );
      },
      builder: (context, d) {
        if (d == null) {
          return const EmptyState(icon: Icons.search_off, title: 'This finding is no longer here');
        }
        final content = _content(context, d);
        return scrollable
            ? SingleChildScrollView(padding: const EdgeInsets.only(bottom: Gap.xl), child: content)
            : content;
      },
    );
  }

  static String? _changed(AuditEntry h, String field) {
    final c = (h.details['changes'] as Map?)?[field];
    if (c is List && c.length == 2) return c[1]?.toString();
    if (h.action == 'insert') return (h.details['data'] as Map?)?[field]?.toString();
    return null;
  }

  Widget _content(BuildContext context, _DetailData d) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final f = d.finding;
    final names = agentNames(app);
    final agent = agentLabel(names, f.str('agent_id'));
    final module = app.registry.module(f.str('module_id'))?.name ?? sentenceCase(f.str('module_id', '—'));
    final amount = f.intOrNull('amount_at_risk_paise') ?? 0;
    final actions = findingActions(app.auth.session, f);
    final ordered = [
      for (final a in FindingAction.values)
        if (actions.contains(a)) a,
    ];
    String userName(String? id) => id == null ? '—' : (d.users[id]?.str('display_name') ?? 'Someone');
    final evidence = f.maps('evidence');
    final p = d.patient;

    final header = SectionCard(
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
                    SeverityChip(f.str('severity')),
                    FindingStatusChip(f.str('status')),
                    if (f.strOrNull('category') != null) StatusChip(sentenceCase(f.str('category'))),
                  ],
                ),
              ),
              if (amount > 0)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    MoneyText(amount, style: theme.textTheme.titleLarge),
                    Text('at risk', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
            ],
          ),
          Gap.v12,
          Text(f.str('title'), style: theme.textTheme.titleLarge),
          Gap.v4,
          Text(
            [
              'Found by $agent',
              'first seen ${formatRelative(f.date('first_seen_at') ?? f.createdAt)}',
              if (f.integer('occurrences', 1) > 1) 'seen ${f.integer('occurrences')} times',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (f.str('summary').isNotEmpty) ...[
            Gap.v12,
            Text(f.str('summary'), style: theme.textTheme.bodyLarge),
          ],
          if (f.strOrNull('decision_note') != null && f.str('status') != FindingStatus.open) ...[
            Gap.v12,
            _DecisionBanner(finding: f, by: userName(f.strOrNull('decided_by')), assignee: userName(f.strOrNull('assigned_to'))),
          ],
          if (ordered.isNotEmpty) ...[
            Gap.v16,
            TourAnchor(
              id: 'tower.decision_bar',
              child: Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final (i, a) in ordered.indexed) _actionButton(a, f, primary: i == 0),
                ],
              ),
            ),
            if (showHints) ...[Gap.v12, const KeyHints(_hints)],
          ] else if (!context.can(CorePerms.towerDecide) && f.str('status') == FindingStatus.open) ...[
            Gap.v12,
            const InlineNote('Board members decide findings. You can see them and their evidence.'),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Gap.v16,
        SectionCard(title: 'Evidence', subtitle: 'The records the agent looked at', child: EvidenceList(evidence)),
        if (p != null) ...[
          Gap.v16,
          SectionCard(
            title: 'Patient',
            child: LinkRow(
              icon: Icons.person_outline,
              label: '${p.str('full_name')} · ${p.str('uhid')}',
              caption: 'Open the patient\'s profile',
              onTap: () => app.nav.open('patients.profile', {'id': p.id}),
            ),
          ),
        ],
        Gap.v16,
        SectionCard(
          title: 'Details',
          child: InfoGrid([
            ('Agent', agent),
            ('Module', module),
            ('First seen', formatDateTime(f.date('first_seen_at'))),
            ('Last seen', formatDateTime(f.date('last_seen_at'))),
            ('Times seen', '${f.integer('occurrences', 1)}'),
            if (f.strOrNull('assigned_to') != null) ('Assigned to', userName(f.strOrNull('assigned_to'))),
            if (f.strOrNull('decided_by') != null) ('Last decision by', userName(f.strOrNull('decided_by'))),
            if (f.date('decided_at') != null) ('Decided', formatDateTime(f.date('decided_at'))),
          ], minItemWidth: 180),
        ),
        Gap.v16,
        SectionCard(title: 'History', child: _History(finding: f, entries: d.history, users: d.users, agent: agent)),
      ],
    );
  }

  Widget _actionButton(FindingAction a, Rec f, {required bool primary}) {
    final (label, icon) = switch (a) {
      FindingAction.confirm => ('Confirm', Icons.check),
      FindingAction.dismiss => ('Dismiss', Icons.close),
      FindingAction.assign => (f.strOrNull('assigned_to') == null ? 'Assign' : 'Reassign', Icons.person_add_alt),
      FindingAction.fix => ('Mark fixed', Icons.task_alt),
      FindingAction.reopen => ('Reopen', Icons.undo),
    };
    void tap() => onAction(a, f);
    return primary
        ? FilledButton.icon(onPressed: tap, icon: Icon(icon, size: 18), label: Text(label))
        : OutlinedButton.icon(onPressed: tap, icon: Icon(icon, size: 18), label: Text(label));
  }
}

class _DecisionBanner extends StatelessWidget {
  const _DecisionBanner({required this.finding, required this.by, required this.assignee});
  final Rec finding;
  final String by;
  final String assignee;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final status = f.str('status');
    final c = ToneColors.of(context, FindingStatus.tone(status));
    final theme = Theme.of(context);
    final who = status == FindingStatus.cleared ? 'Cleared automatically' : '${FindingStatus.label(status)} by $by';
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              who,
              if (status == FindingStatus.assigned) 'to $assignee',
              formatRelative(f.date('decided_at')),
            ].join(' · '),
            style: theme.textTheme.labelLarge?.copyWith(color: c.foreground),
          ),
          Gap.v4,
          Text(f.str('decision_note'), style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Who did what to this finding, newest first, from the audit log.
class _History extends StatelessWidget {
  const _History({required this.finding, required this.entries, required this.users, required this.agent});
  final Rec finding;
  final List<AuditEntry> entries;
  final Map<String, Rec> users;
  final String agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = <(DateTime, String, String?, Tone)>[];
    String name(String? id) => id == null ? 'someone' : (users[id]?.str('display_name') ?? 'someone');
    for (final h in entries) {
      final status = FindingDetail._changed(h, 'status');
      final note = FindingDetail._changed(h, 'decision_note');
      final actor = h.actorId == 'system' ? null : h.actorName;
      if (h.action == 'insert') {
        if (status == null || status == FindingStatus.open) {
          items.add((h.ts, 'Raised by $agent', null, Tone.agent));
        } else {
          items.add((h.ts, '${FindingStatus.label(status)} by ${actor ?? 'the system'}', note, FindingStatus.tone(status)));
        }
      } else if (h.action == 'update' && status != null) {
        final label = switch (status) {
          FindingStatus.open => actor == null ? 'Seen again by $agent' : 'Reopened by $actor',
          FindingStatus.cleared => 'Cleared: $agent no longer sees it',
          FindingStatus.assigned => 'Assigned to ${name(FindingDetail._changed(h, 'assigned_to') ?? finding.strOrNull('assigned_to'))} by ${actor ?? 'the system'}',
          FindingStatus.resolved => 'Marked fixed by ${actor ?? 'the system'}',
          _ => '${FindingStatus.label(status)} by ${actor ?? 'the system'}',
        };
        items.add((h.ts, label, status == FindingStatus.cleared || note == 'Reopened' ? null : note, FindingStatus.tone(status)));
      }
    }
    if (items.isEmpty) {
      // No audit access: show what the record itself says.
      items.add((finding.date('first_seen_at') ?? finding.createdAt, 'Raised by $agent', null, Tone.agent));
      if (finding.str('status') != FindingStatus.open && finding.date('decided_at') != null) {
        items.insert(0, (
          finding.date('decided_at')!,
          '${FindingStatus.label(finding.str('status'))} by ${name(finding.strOrNull('decided_by'))}',
          finding.strOrNull('decision_note'),
          FindingStatus.tone(finding.str('status')),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (ts, label, note, tone)) in items.indexed)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 20,
                  child: Column(
                    children: [
                      Gap.v4,
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: ToneColors.of(context, tone).foreground, shape: BoxShape.circle),
                      ),
                      if (i < items.length - 1) Expanded(child: Container(width: 2, color: cs.outlineVariant)),
                    ],
                  ),
                ),
                Gap.h8,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Gap.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        if (note != null && note.isNotEmpty) Text(note, style: theme.textTheme.bodyMedium),
                        Text(formatDateTime(ts), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

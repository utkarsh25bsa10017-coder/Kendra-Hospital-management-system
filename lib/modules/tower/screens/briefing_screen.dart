import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../briefing.dart';
import '../tower_data.dart';
import '../widgets/tower_widgets.dart';

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _longDate(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

String _dayName(String key) {
  final d = DateTime.tryParse(key);
  if (d == null) return key;
  final today = startOfDay(DateTime.now());
  if (d == today) return 'Today';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return formatDate(d);
}

/// Today's briefing (or prepare it now) and the previous ones.
class BriefingScreen extends StatefulWidget {
  const BriefingScreen({super.key});

  @override
  State<BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<BriefingScreen> {
  String? _selectedId;
  bool _busy = false;

  Future<void> _prepare() async {
    final app = context.app;
    setState(() => _busy = true);
    Rec? made;
    final ok = await runGuarded(context, () async {
      made = await Briefings.create(app, app.db, exceptUserId: app.auth.session?.userId);
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (made != null) _selectedId = made!.id;
    });
    if (ok) app.nav.toast(made == null ? 'Today\'s briefing was already prepared' : 'Briefing prepared and sent to the board');
  }

  @override
  Widget build(BuildContext context) {
    final hour = context.app.settings.briefingHour;
    return PageScaffold(
      title: 'Morning briefing',
      subtitle: 'Prepared at $hour:00 every morning: what changed since the last one',
      body: LiveBuilder<List<Rec>>(
        watch: const {briefingsCol},
        load: (db) => Briefings.recent(db, limit: 30),
        builder: (context, recent) {
          final todayKey = dayKey(DateTime.now());
          final today = recent.where((b) => b.str('briefing_date') == todayKey).firstOrNull;
          final selected = recent.where((b) => b.id == _selectedId).firstOrNull ?? today ?? recent.firstOrNull;
          final main = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (today == null) ...[
                SectionCard(
                  child: Row(
                    children: [
                      const ToneIcon(Icons.schedule, tone: Tone.board),
                      Gap.h12,
                      Expanded(
                        child: Text(
                          DateTime.now().hour < hour
                              ? 'Today\'s briefing will be prepared at $hour:00.'
                              : 'Today\'s briefing has not been prepared yet.',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                      Gap.h12,
                      FilledButton.icon(
                        onPressed: _busy ? null : _prepare,
                        icon: const Icon(Icons.wb_sunny_outlined, size: 18),
                        label: const Text('Prepare now'),
                      ),
                    ],
                  ),
                ),
                Gap.v16,
              ],
              if (selected != null)
                BriefingView(briefing: selected)
              else
                const EmptyState(
                  icon: Icons.wb_sunny_outlined,
                  title: 'No briefings yet',
                  message: 'Each morning the control tower sums up what the agents found.',
                ),
            ],
          );
          if (recent.length < 2) return main;
          return TwoColumns(
            breakpoint: 1000,
            mainFlex: 5,
            sideFlex: 2,
            main: main,
            side: SectionCard(
              title: 'Previous briefings',
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final b in recent)
                    _BriefingRow(
                      briefing: b,
                      selected: b.id == selected?.id,
                      onTap: () => setState(() => _selectedId = b.id),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BriefingRow extends StatelessWidget {
  const _BriefingRow({required this.briefing, required this.selected, required this.onTap});
  final Rec briefing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: selected ? cs.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_dayName(briefing.str('briefing_date')), style: theme.textTheme.titleSmall),
              Gap.v4,
              Text(briefing.map('summary')['headline'] as String? ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// One briefing, laid out for a quick read.
class BriefingView extends StatelessWidget {
  const BriefingView({super.key, required this.briefing});
  final Rec briefing;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = briefing.map('summary');
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    final sent = briefing.date('sent_at') ?? briefing.createdAt;
    final since = DateTime.tryParse(s['since'] as String? ?? '')?.toLocal();
    final sev = (s['new_by_severity'] as Map?)?.cast<String, Object?>() ?? const {};
    final severities = [
      for (final e in Severity.values.reversed)
        if (((sev[e.name] as num?) ?? 0) > 0) (e, (sev[e.name] as num).toInt()),
    ];
    final agents = [
      for (final a in (s['new_by_agent'] as List? ?? const []).whereType<Map>())
        ((a['name'] as String?) ?? 'Agent', (a['count'] as num?) ?? 0),
    ];
    final top = (s['top'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, Object?>()).toList();
    final canApprove = context.can(CorePerms.approvalsDecide);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const ToneIcon(Icons.wb_sunny_outlined, tone: Tone.board, size: 44),
                  Gap.h12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_longDate(sent), style: theme.textTheme.titleLarge),
                        Text(
                          [
                            'Prepared ${formatTime(sent)}',
                            if (since != null) 'covers everything since ${formatDateShort(since)}, ${formatTime(since)}',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Gap.v16,
              Text(s['headline'] as String? ?? '', style: theme.textTheme.titleMedium),
              Gap.v16,
              ResponsiveGrid(
                minWidth: 150,
                maxColumns: 5,
                spacing: Gap.md,
                children: [
                  _Stat('New findings', formatNumber(n('new_total')), tone: n('new_total') > 0 ? Tone.warning : Tone.success),
                  _Stat('Amount at risk', formatMoneyShort(n('amount_at_risk_paise')), tone: Tone.board),
                  _Stat('Approvals waiting', formatNumber(n('approvals_waiting')),
                      caption: n('approvals_amount_paise') > 0 ? formatMoneyShort(n('approvals_amount_paise')) : null),
                  _Stat('Suggestions waiting', formatNumber(n('suggestions_waiting'))),
                  _Stat('Cleared or fixed', formatNumber(n('cleared') + n('resolved')), tone: Tone.success),
                ],
              ),
              Gap.v16,
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  FilledButton.icon(
                    onPressed: () => app.nav.open('tower.findings'),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Review findings'),
                  ),
                  if (canApprove && n('approvals_waiting') > 0)
                    OutlinedButton(onPressed: () => app.nav.open('tower.approvals'), child: const Text('Approvals')),
                  if (canApprove && n('suggestions_waiting') > 0)
                    OutlinedButton(onPressed: () => app.nav.open('tower.proposals'), child: const Text('Suggestions')),
                ],
              ),
            ],
          ),
        ),
        Gap.v16,
        ResponsiveGrid(
          minWidth: 320,
          maxColumns: 2,
          children: [
            SectionCard(
              title: 'New findings by severity',
              child: severities.isEmpty
                  ? Text('Nothing new since the last briefing.', style: theme.textTheme.bodyMedium)
                  : Column(
                      children: [
                        for (final (sv, count) in severities)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(children: [
                              SizedBox(width: 96, child: Align(alignment: Alignment.centerLeft, child: SeverityChip(sv.name))),
                              Gap.h8,
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: count / n('new_total').clamp(1, 1 << 30),
                                    minHeight: 8,
                                    color: ToneColors.of(context, toneForSeverity(sv.name)).foreground,
                                    backgroundColor: cs.surfaceContainerHigh,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text('$count', textAlign: TextAlign.right, style: theme.textTheme.titleSmall),
                              ),
                            ]),
                          ),
                      ],
                    ),
            ),
            SectionCard(
              title: 'New findings by agent',
              child: agents.isEmpty
                  ? Text('No agent raised anything new.', style: theme.textTheme.bodyMedium)
                  : ShareBars(items: agents, format: (v) => formatNumber(v)),
            ),
          ],
        ),
        if (top.isNotEmpty) ...[
          Gap.v16,
          SectionCard(
            title: 'Look at these first',
            subtitle: 'New since the last briefing and not yet fixed',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, t) in top.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  InkWell(
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: () => app.nav.open('tower.findings', {'id': t['id']}),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.xs),
                      child: Row(
                        children: [
                          SizedBox(width: 96, child: Align(alignment: Alignment.centerLeft, child: SeverityChip(t['severity'] as String?))),
                          Gap.h8,
                          Expanded(
                            child: TwoLine((t['title'] as String?) ?? '', t['agent_name'] as String?),
                          ),
                          if (((t['amount_paise'] as num?) ?? 0) > 0) ...[
                            Gap.h8,
                            MoneyText((t['amount_paise'] as num).toInt()),
                          ],
                          Icon(Icons.chevron_right, color: cs.outline),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.caption, this.tone = Tone.neutral});
  final String label;
  final String value;
  final String? caption;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = ToneColors.of(context, tone);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tone == Tone.neutral ? cs.surfaceContainerLow : c.background,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tone == Tone.neutral ? cs.outlineVariant : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelMedium?.copyWith(color: tone == Tone.neutral ? cs.onSurfaceVariant : c.foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Gap.v4,
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              if (caption != null) ...[
                Gap.h8,
                Flexible(
                  child: Text(caption!, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

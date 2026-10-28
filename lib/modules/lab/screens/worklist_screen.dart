import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';
import 'lab_widgets.dart';

enum WorkTab {
  collect('To collect'),
  progress('In progress'),
  verify('To verify'),
  done('Completed today');

  const WorkTab(this.label);
  final String label;

  static WorkTab? parse(Object? s) => WorkTab.values.where((t) => t.name == s).firstOrNull;
}

class _Work {
  _Work(this.collect, this.progress, this.done);
  final List<LabItem> collect;
  final List<LabItem> progress;
  final List<LabItem> done;
  List<LabItem> get verify => progress.where((i) => i.status == Vals.resulted).toList();
}

/// Soonest due (or most overdue) first; STAT wins a tie.
int _byUrgency(LabItem a, LabItem b) {
  final d = a.due.compareTo(b.due);
  return d != 0 ? d : Priority.rank(a.priority).compareTo(Priority.rank(b.priority));
}

/// The lab's day: samples to collect, work on the bench, reports to sign.
class LabWorklistScreen extends StatefulWidget {
  const LabWorklistScreen({super.key, this.initialTab});
  final String? initialTab;

  @override
  State<LabWorklistScreen> createState() => _LabWorklistScreenState();
}

class _LabWorklistScreenState extends State<LabWorklistScreen> with TickerProviderStateMixin {
  TabController? _tabs;
  List<WorkTab> _visible = const [];
  String _search = '';
  DateTime _now = DateTime.now();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keep the countdowns honest.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tabs != null) return;
    final canVerify = context.can(LabPerms.verify);
    _visible = [WorkTab.collect, WorkTab.progress, if (canVerify) WorkTab.verify, WorkTab.done];
    var initial = WorkTab.parse(widget.initialTab);
    if (initial == null || !_visible.contains(initial)) {
      // Pathologists start where their work is.
      initial = canVerify && !context.can(LabPerms.collect) ? WorkTab.verify : WorkTab.collect;
    }
    _tabs = TabController(length: _visible.length, vsync: this, initialIndex: _visible.indexOf(initial))
      ..addListener(() {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tabs?.dispose();
    super.dispose();
  }

  WorkTab get _tab => _visible[_tabs!.index];

  Future<_Work> _load(ReadDb db) async {
    final today = startOfDay(DateTime.now());
    final q = LabService.labOrders();
    final collect = await db.query(q.eq('status', Vals.ordered).sort('ordered_at').take(200));
    final progress = await db.query(q.isIn('status', [Vals.collected, Vals.resulted]).sort('ordered_at').take(200));
    final done = await db.query(q.eq('status', Vals.verified).gte('verified_at', today).sort('verified_at', desc: true).take(200));
    final tests = await LabService.testsByCode(db);
    final items = await LabService.loadItems(db, [...collect, ...progress, ...done], tests: tests);
    return _Work(
      items.where((i) => i.status == Vals.ordered).toList()..sort(_byUrgency),
      items.where((i) => i.status == Vals.collected || i.status == Vals.resulted).toList()..sort(_byUrgency),
      items.where((i) => i.status == Vals.verified).toList(),
    );
  }

  bool _matches(LabItem i) {
    if (_search.isEmpty) return true;
    final hay = [i.patientName, i.uhid, i.testName, i.order.str('sample_id'), i.doctorName, i.order.str('service_code')]
        .join(' ')
        .toLowerCase();
    return _search.toLowerCase().split(RegExp(r'\s+')).every(hay.contains);
  }

  int _count(_Work w, WorkTab t) => switch (t) {
        WorkTab.collect => w.collect.length,
        WorkTab.progress => w.progress.length,
        WorkTab.verify => w.verify.length,
        WorkTab.done => w.done.length,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canOrder = context.can(LabPerms.order);
    final subtitle = 'Today · ${formatWeekday(_now)} ${formatDate(_now)}';
    PageScaffold page(_Work? w, Widget body) => PageScaffold(
          title: 'Lab worklist',
          subtitle: subtitle,
          primaryAction: canOrder
              ? PageAction('New lab order', Icons.add, () => app.nav.open('lab.new_order'), tourAnchor: 'lab.new_order')
              : null,
          actions: [
            if (context.can(LabPerms.catalog))
              IconButton(
                tooltip: 'Lab tests and prices',
                icon: const Icon(Icons.science_outlined),
                onPressed: () => app.nav.open('lab.tests'),
              ),
          ],
          headerBottom: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchField(
                hint: 'Patient, UHID, sample ID or test',
                initial: _search,
                onChanged: (v) => setState(() => _search = v),
              ),
              Gap.v8,
              TourAnchor(
                id: 'lab.worklist.tabs',
                child: TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    for (final t in _visible) Tab(child: _TabLabel(t.label, w == null ? null : _count(w, t), urgent: t == WorkTab.verify)),
                  ],
                ),
              ),
            ],
          ),
          body: body,
        );

    return LiveBuilder<_Work>(
      watch: const {Col.serviceOrders, LabCol.results, LabCol.tests, Col.patients},
      load: _load,
      loading: page(null, const LoadingView()),
      builder: (context, w) {
        final items = switch (_tab) {
          WorkTab.collect => w.collect,
          WorkTab.progress => w.progress,
          WorkTab.verify => w.verify,
          WorkTab.done => w.done,
        }.where(_matches).toList();
        final body = switch (_tab) {
          WorkTab.collect => _CollectList(items: items, now: _now, searching: _search.isNotEmpty),
          WorkTab.progress => _ProgressList(items: items, now: _now, searching: _search.isNotEmpty),
          WorkTab.verify => _VerifyList(items: items, now: _now, searching: _search.isNotEmpty),
          WorkTab.done => _DoneList(items: items, now: _now, searching: _search.isNotEmpty),
        };
        return page(w, Padding(padding: const EdgeInsets.only(top: Gap.sm), child: body));
      },
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.label, this.count, {this.urgent = false});
  final String label;
  final int? count;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, urgent && (count ?? 0) > 0 ? Tone.warning : Tone.neutral);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (count != null) ...[
          Gap.h8,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: c.foreground, fontWeight: FontWeight.w700)),
          ),
        ],
      ],
    );
  }
}

Widget _empty(IconData icon, String title, String message, bool searching) => EmptyState(
      icon: searching ? Icons.search_off : icon,
      title: searching ? 'Nothing matches your search' : title,
      message: searching ? 'Try a patient name, UHID or sample ID.' : message,
    );

// ---------------------------------------------------------------- to collect

/// Grouped by patient, so all of one person's tubes are drawn at once.
class _CollectList extends StatelessWidget {
  const _CollectList({required this.items, required this.now, required this.searching});
  final List<LabItem> items;
  final DateTime now;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _empty(Icons.check_circle_outline, 'Nothing to collect',
          'New orders from doctors and the front desk appear here.', searching);
    }
    final groups = <String, List<LabItem>>{};
    for (final i in items) {
      groups.putIfAbsent(i.order.str('patient_id'), () => []).add(i);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (n, g) in groups.values.indexed) ...[
          _PatientGroup(items: g, now: now, anchorCollect: n == 0),
          Gap.v12,
        ],
      ],
    );
  }
}

class _PatientGroup extends StatelessWidget {
  const _PatientGroup({required this.items, required this.now, required this.anchorCollect});
  final List<LabItem> items;
  final DateTime now;
  final bool anchorCollect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = items.first;
    final canCollect = context.can(LabPerms.collect);
    final hasStat = items.any((i) => i.isStat);
    final overdue = items.any((i) => i.due.isBefore(now));
    // Notes written once for a batch of tests are shown once.
    final notes = items.map((i) => i.order.str('clinical_notes')).toSet();
    final sharedNotes = items.length > 1 && notes.length == 1 ? notes.first : '';
    Widget collectAll = FilledButton.icon(
      onPressed: () => collectSamples(context, items),
      icon: const Icon(Icons.colorize_outlined, size: 18),
      label: Text(items.length == 1 ? 'Collect sample' : 'Collect all ${items.length}'),
    );
    if (anchorCollect) collectAll = TourAnchor(id: 'lab.collect', child: collectAll);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: hasStat && overdue
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.lg),
              side: BorderSide(color: ToneColors.of(context, Tone.danger).border, width: 1.5))
          : null,
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 620;
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.md, Gap.md),
          child: Row(
            children: [
              Avatar(first.patientName, size: 36),
              Gap.h12,
              Expanded(
                child: InkWell(
                  onTap: () => context.app.nav.open('patients.profile', {'id': first.order.str('patient_id')}),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(first.patientName, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      Text(patientLine(first.patient),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
              if (canCollect && wide) ...[Gap.h8, collectAll],
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const Divider(height: 1),
            if (sharedNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                child: Row(children: [
                  Icon(Icons.notes, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  Gap.h8,
                  Expanded(
                    child: Text(sharedNotes,
                        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ]),
              ),
            for (final (n, i) in items.indexed) ...[
              if (n > 0) Divider(height: 1, indent: Gap.lg, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
              _CollectRow(item: i, now: now, wide: wide, canCollect: canCollect && items.length > 1, showNotes: sharedNotes.isEmpty),
            ],
            if (canCollect && !wide)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                child: collectAll,
              ),
          ],
        );
      }),
    );
  }
}

class _CollectRow extends StatelessWidget {
  const _CollectRow({required this.item, required this.now, required this.wide, required this.canCollect, this.showNotes = true});
  final LabItem item;
  final DateTime now;
  final bool wide;
  final bool canCollect;
  final bool showNotes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final notes = showNotes ? item.order.str('clinical_notes') : '';
    final meta = [
      'Ordered ${formatTime(item.orderedAt)}${startOfDay(item.orderedAt) == startOfDay(now) ? '' : ', ${formatDateShort(item.orderedAt)}'}',
      if (item.doctorName.isNotEmpty) item.doctorName,
      if (item.container.isNotEmpty) item.container,
    ].join(' · ');
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(item.testName, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            PriorityChip(item.priority, showRoutine: false),
          ],
        ),
        Gap.v4,
        Text(meta, style: muted),
        if (notes.isNotEmpty) ...[
          Gap.v4,
          Text(notes, style: muted?.copyWith(fontStyle: FontStyle.italic), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ],
    );
    final single = OutlinedButton(onPressed: () => collectSamples(context, [item]), child: const Text('Collect'));
    return InkWell(
      onTap: () => context.app.nav.open('lab.order', {'id': item.id}),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        child: wide
            ? Row(
                children: [
                  Expanded(child: info),
                  Gap.h12,
                  SizedBox(width: 170, child: Align(alignment: Alignment.centerLeft, child: TatLabel(item, now: now))),
                  if (canCollect) ...[Gap.h8, single],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  info,
                  Gap.v8,
                  Row(children: [
                    Expanded(child: TatLabel(item, now: now)),
                    if (canCollect) single,
                  ]),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------- in progress

Widget _patientCell(LabItem i) => TwoLine(i.patientName, i.uhid);
Widget _testCell(LabItem i) => TwoLine(i.testName, i.order.str('sample_id'));
Widget _testWithPriority(LabItem i) => Row(children: [
      Flexible(child: _testCell(i)),
      if (i.priority != Priority.routine) ...[Gap.h8, PriorityChip(i.priority, showRoutine: false)],
    ]);

class _ProgressList extends StatelessWidget {
  const _ProgressList({required this.items, required this.now, required this.searching});
  final List<LabItem> items;
  final DateTime now;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canResult = context.can(LabPerms.result);
    final canVerify = context.can(LabPerms.verify);
    var anchored = false;
    Widget action(LabItem i) {
      if (i.status == Vals.collected && canResult) {
        final b = OutlinedButton(
          onPressed: () => app.nav.open('lab.order', {'id': i.id}),
          child: const Text('Enter results'),
        );
        if (anchored) return b;
        anchored = true;
        return TourAnchor(id: 'lab.enter_results', child: b);
      }
      if (i.status == Vals.resulted && canVerify) {
        return OutlinedButton(onPressed: () => app.nav.open('lab.order', {'id': i.id}), child: const Text('Review'));
      }
      return TextButton(onPressed: () => app.nav.open('lab.order', {'id': i.id}), child: const Text('Open'));
    }

    final wide = context.isExpanded;
    return DataList<LabItem>(
      items: items,
      empty: _empty(Icons.science_outlined, 'No samples in progress', 'Collected samples wait here for their results.', searching),
      onTap: (i) => app.nav.open('lab.order', {'id': i.id}),
      title: (i) => '${i.testName} · ${i.patientName}',
      subtitle: (i) => [
        i.order.str('sample_id'),
        i.status == Vals.collected ? 'Awaiting results' : 'Awaiting verification',
        if (i.doctorName.isNotEmpty) i.doctorName,
      ].where((s) => s.isNotEmpty).join(' · '),
      trailing: (i) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [PriorityChip(i.priority, showRoutine: false), Gap.v4, TatLabel(i, now: now)],
      ),
      columns: [
        ListColumn('Patient', _patientCell, flex: 3),
        ListColumn('Test · sample', wide ? _testCell : _testWithPriority, flex: wide ? 3 : 4),
        if (wide) ListColumn('Priority', (i) => PriorityChip(i.priority), width: 100),
        ListColumn('Stage', (i) => OrderStatusChip(i.status, resultStatus: i.result?.str('status')), width: 170),
        if (wide) ListColumn('Ordered', (i) => TwoLine(formatTime(i.orderedAt), i.doctorName), flex: 2),
        ListColumn('Turnaround', (i) => TatLabel(i, now: now), width: 150),
        if (wide) ListColumn('', action, width: 150, numeric: true),
      ],
    );
  }
}

// ---------------------------------------------------------------- to verify

class _VerifyList extends StatelessWidget {
  const _VerifyList({required this.items, required this.now, required this.searching});
  final List<LabItem> items;
  final DateTime now;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final me = context.session?.userId;
    final wide = context.isExpanded;
    // Criticals first, then the longest waiting.
    final sorted = [...items]..sort((a, b) {
        final c = (b.order.flag('critical') ? 1 : 0) - (a.order.flag('critical') ? 1 : 0);
        if (c != 0) return c;
        return (a.order.date('resulted_at') ?? now).compareTo(b.order.date('resulted_at') ?? now);
      });
    String entered(LabItem i) {
      final by = i.result?.str('entered_by_name') ?? '';
      final at = i.order.date('resulted_at');
      return [if (by.isNotEmpty) by, formatRelative(at)].join(' · ');
    }

    return DataList<LabItem>(
      items: sorted,
      empty: _empty(Icons.verified_outlined, 'Nothing waiting for verification',
          'Results entered by the technicians appear here for you to check and sign.', searching),
      onTap: (i) => app.nav.open('lab.order', {'id': i.id}),
      title: (i) => '${i.testName} · ${i.patientName}',
      subtitle: (i) => '${i.order.str('result_summary')}\nEntered by ${entered(i)}',
      trailing: (i) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (i.order.flag('critical'))
            const StatusChip('Critical', tone: Tone.danger, icon: Icons.warning_amber_rounded)
          else
            PriorityChip(i.priority, showRoutine: false),
          Gap.v4,
          TatLabel(i, now: now),
        ],
      ),
      columns: [
        ListColumn('Patient', _patientCell, flex: 3),
        ListColumn('Test · sample', _testCell, flex: 3),
        ListColumn('Result', (i) => SummaryText(i.order), flex: 4),
        ListColumn('Entered by', (i) => TwoLine(i.result?.str('entered_by_name') ?? '—', formatRelative(i.order.date('resulted_at'))),
            flex: 2),
        if (wide) ListColumn('Turnaround', (i) => TatLabel(i, now: now), width: 150),
        if (wide)
          ListColumn(
            '',
            (i) => i.result?.str('entered_by') == me
                ? const Tooltip(message: 'You entered these results', child: Text('Entered by you'))
                : OutlinedButton(onPressed: () => app.nav.open('lab.order', {'id': i.id}), child: const Text('Review')),
            width: 130,
            numeric: true,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- done

class _DoneList extends StatelessWidget {
  const _DoneList({required this.items, required this.now, required this.searching});
  final List<LabItem> items;
  final DateTime now;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final wide = context.isExpanded;
    final times = items.map((i) => i.turnaround).whereType<Duration>().toList();
    final onTime = items.where((i) => (i.turnaround?.inMinutes ?? 0) <= targetMinutes(i.priority, i.tatMinutes)).length;
    final avg = times.isEmpty ? null : Duration(minutes: (times.fold<int>(0, (a, d) => a + d.inMinutes) / times.length).round());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isNotEmpty && !searching) ...[
          Text(
            '${plural(items.length, 'report')} verified today · average turnaround ${formatDuration(avg!)} · '
            '$onTime of ${items.length} on time',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Gap.v12,
        ],
        DataList<LabItem>(
          items: items,
          empty: _empty(Icons.task_alt, 'No reports verified today yet', 'Verified reports for today are listed here.', searching),
          onTap: (i) => app.nav.open('lab.order', {'id': i.id, 'report': true}),
          title: (i) => '${i.testName} · ${i.patientName}',
          subtitle: (i) => '${i.order.str('result_summary')}\nVerified ${formatTime(i.order.date('verified_at'))} · '
              '${i.result?.str('verified_by_name') ?? ''}',
          trailing: (i) => TatLabel(i, now: now),
          columns: [
            ListColumn('Patient', _patientCell, flex: 3),
            ListColumn('Test · sample', _testCell, flex: 3),
            ListColumn('Result', (i) => SummaryText(i.order), flex: 4),
            if (wide)
              ListColumn('Verified', (i) => TwoLine(formatTime(i.order.date('verified_at')), i.result?.str('verified_by_name')),
                  flex: 2),
            ListColumn('Turnaround', (i) => TatLabel(i, now: now), width: 110, numeric: true),
          ],
        ),
      ],
    );
  }
}

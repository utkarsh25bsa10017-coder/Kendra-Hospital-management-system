import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';
import 'lab_widgets.dart';
import 'report_print.dart';
import 'report_view.dart';
import 'result_entry.dart';

class _OrderData {
  _OrderData(this.item, this.previous);
  final LabItem item;
  final PreviousValues previous;
}

/// One lab order from start to finish: collect, enter results, verify,
/// amend, acknowledge a critical value, and the printable report.
class LabOrderScreen extends StatelessWidget {
  const LabOrderScreen({super.key, required this.orderId, this.report = false});
  final String orderId;
  final bool report;

  Future<_OrderData?> _load(ReadDb db) async {
    final o = await db.get(Col.serviceOrders, orderId);
    if (o == null) return null;
    final item = (await LabService.loadItems(db, [o])).first;
    final previous = await LabService.previousValues(db, o.str('patient_id'),
        excludeOrderId: o.id, before: o.date('ordered_at'));
    return _OrderData(item, previous);
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_OrderData?>(
      watch: const {Col.serviceOrders, LabCol.results, LabCol.tests, Col.patients},
      deps: [orderId],
      load: _load,
      builder: (context, d) => d == null
          ? const PageScaffold(
              title: 'Lab order',
              body: EmptyState(icon: Icons.search_off, title: 'Order not found'),
            )
          : _OrderView(data: d, startWithReport: report),
    );
  }
}

enum _Mode { view, edit, amend }

class _OrderView extends StatefulWidget {
  const _OrderView({required this.data, required this.startWithReport});
  final _OrderData data;
  final bool startWithReport;

  @override
  State<_OrderView> createState() => _OrderViewState();
}

class _OrderViewState extends State<_OrderView> {
  late bool _report = widget.startWithReport;
  _Mode? _explicit;
  String _amendReason = '';
  final _form = GlobalKey<ResultEntryFormState>();

  LabItem get item => widget.data.item;
  Rec? get result => item.result;
  String? get sex => item.patient?.strOrNull('gender');
  String get doctor => item.doctorName.isEmpty ? 'the doctor' : item.doctorName;

  _Mode get mode {
    if (_explicit != null) return _explicit!;
    if (item.status == Vals.collected && context.can(LabPerms.result)) return _Mode.edit;
    return _Mode.view;
  }

  Map<String, String> get _currentRaw => {
        for (final v in result?.maps('values') ?? const <Map<String, Object?>>[]) '${v['key']}': '${v['value'] ?? ''}',
      };

  // ------------------------------------------------------------ actions

  Future<void> _collect() async {
    await collectSamples(context, [item]);
  }

  Future<void> _save(Map<String, String> raw, String comments) async {
    final app = context.app;
    final db = context.db;
    final nav = Navigator.of(context);
    if (mode == _Mode.amend) {
      final ok = await runGuarded(
        context,
        () => LabService.amend(db,
            order: item.order, test: item.test, raw: raw, reason: _amendReason, comments: comments, sex: sex),
        success: 'Report amended. It must be verified again.',
      );
      if (ok && mounted) setState(() => _explicit = null);
      return;
    }
    Rec? saved;
    final ok = await runGuarded(context, () async {
      saved = await LabService.saveResults(db, order: item.order, test: item.test, raw: raw, comments: comments, sex: sex);
    });
    if (!ok || saved == null) return;
    final critical = saved!.flag('critical');
    if (critical) {
      final crit = criticalText(saved!.maps('values'), item.params);
      try {
        await app.notifications.notifyPermission(db,
            permission: LabPerms.verify,
            title: 'Critical value to verify: $crit · ${item.patientName}',
            body: '${item.testName} for ${item.patientName}. Verify it before other reports and inform $doctor.',
            severity: 'critical',
            routeId: 'lab.order',
            routeArgs: {'id': item.id},
            exceptUserId: app.auth.session?.userId);
      } catch (_) {
        // The result is saved; the critical-results agent still raises it.
      }
    }
    app.nav.toast(critical
        ? 'Results saved. The pathologist has been alerted to the critical value.'
        : 'Results saved for ${item.testName}. Waiting for verification.');
    if (!mounted) return;
    if (nav.canPop()) {
      nav.pop();
    } else {
      setState(() => _explicit = null);
    }
  }

  Future<void> _verify() async {
    final critical = result?.flag('critical') ?? false;
    final ok = await confirmDialog(
      context,
      title: 'Verify this report?',
      message: 'You confirm the values are correct. The report is released to $doctor'
          '${critical ? ', who is alerted to the critical value at once' : ''}.',
      confirmLabel: 'Verify report',
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    final done = await runGuarded(
      context,
      () => LabService.verify(context.db, order: item.order, seen: result),
      success: 'Report verified and sent to $doctor',
    );
    if (done && mounted && nav.canPop()) nav.pop();
  }

  Future<void> _acknowledge() async {
    final r = result;
    if (r == null) return;
    final note = await reasonDialog(
      context,
      title: 'Acknowledge critical result',
      message: '${criticalText(r.maps('values'), item.params)} for ${item.patientName}. What was done?',
      label: 'Action taken',
      presets: const ['Patient called back', 'Treatment started', 'Admitted for management', 'Discussed with family', 'Already aware'],
      confirmLabel: 'Acknowledge',
    );
    if (note == null || !mounted) return;
    await runGuarded(context, () => LabService.acknowledge(context.db, result: r, note: note),
        success: 'Critical result acknowledged');
  }

  Future<void> _amend() async {
    final reason = await reasonDialog(
      context,
      title: 'Amend this report?',
      message: 'The current version is kept in the report history. The corrected values must be verified again.',
      label: 'Reason for the amendment',
      presets: const ['Transcription error', 'Value entered against the wrong parameter', 'Re-run on a repeat sample', 'Unit or calculation error'],
      confirmLabel: 'Continue',
    );
    if (reason == null || !mounted) return;
    setState(() {
      _amendReason = reason;
      _explicit = _Mode.amend;
      _report = false;
    });
  }

  Future<void> _cancel() async {
    final reason = await reasonDialog(
      context,
      title: 'Cancel this order?',
      message: 'No sample was taken, so nothing has been charged.',
      presets: const ['Ordered by mistake', 'Duplicate order', 'Patient declined', 'Patient left without giving a sample'],
      confirmLabel: 'Cancel order',
      destructive: true,
    );
    if (reason == null || !mounted) return;
    final nav = Navigator.of(context);
    final ok = await runGuarded(context, () => LabService.cancel(context.db, item.order, reason), success: 'Order cancelled');
    if (ok && mounted && nav.canPop()) nav.pop();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final status = item.status;
    final r = result;
    final me = context.session?.userId;
    final canCollect = context.can(LabPerms.collect);
    final canResult = context.can(LabPerms.result);
    final canVerify = context.can(LabPerms.verify);
    final canAck = context.can(LabPerms.acknowledge);
    final enteredByMe = r != null && r.str('entered_by') == me;
    final critical = r?.flag('critical') ?? false;
    final unacknowledged = critical && status == Vals.verified && r?.date('acknowledged_at') == null;
    final editing = !_report && mode != _Mode.view && (status == Vals.collected || status == Vals.resulted || mode == _Mode.amend);

    PageAction? primary;
    if (_report) {
      primary = null;
    } else if (status == Vals.ordered && canCollect) {
      primary = PageAction('Collect sample', Icons.colorize_outlined, _collect);
    } else if (editing) {
      primary = PageAction(mode == _Mode.amend ? 'Save amended results' : 'Save results', Icons.check,
          () => _form.currentState?.save(), tourAnchor: 'lab.save_results');
    } else if (status == Vals.resulted && canVerify && !enteredByMe) {
      primary = PageAction('Verify report', Icons.verified_outlined, _verify);
    } else if (unacknowledged && canAck) {
      primary = PageAction('Acknowledge', Icons.task_alt, _acknowledge);
    }

    final menu = <PopupMenuEntry<String>>[
      if (status == Vals.ordered && (canCollect || context.can(LabPerms.order)))
        const PopupMenuItem(value: 'cancel', child: ListTile(leading: Icon(Icons.block), title: Text('Cancel order'))),
      if (status == Vals.resulted && canResult && mode == _Mode.view && !_report)
        const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Correct results'))),
      if (status == Vals.verified && (canResult || canVerify))
        const PopupMenuItem(value: 'amend', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Amend report'))),
    ];

    return PageScaffold(
      title: item.testName,
      subtitle: '${item.patientName} · ${patientLine(item.patient)}',
      primaryAction: primary,
      actions: [
        if (r != null)
          PrintButton(
            name: 'Lab report ${item.testName} ${item.patientName}',
            build: () => labReportPdf(item, Letterhead.of(app.settings)),
          ),
        if (r != null)
          IconButton(
            tooltip: _report ? 'Show results' : 'Report view',
            icon: Icon(_report ? Icons.fact_check_outlined : Icons.description_outlined),
            onPressed: () => setState(() => _report = !_report),
          ),
        IconButton(
          tooltip: 'Open patient',
          icon: const Icon(Icons.person_outline),
          onPressed: () => app.nav.open('patients.profile', {'id': item.order.str('patient_id')}),
        ),
        if (menu.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: 'More',
            itemBuilder: (_) => menu,
            onSelected: (v) => switch (v) {
              'cancel' => _cancel(),
              'edit' => setState(() => _explicit = _Mode.edit),
              'amend' => _amend(),
              _ => null,
            },
          ),
      ],
      headerBottom: _HeaderChips(item: item),
      body: _report ? LabReportView(item: item) : _body(context, editing, enteredByMe, unacknowledged, canAck, canVerify, canResult),
    );
  }

  Widget _body(BuildContext context, bool editing, bool enteredByMe, bool unacknowledged, bool canAck, bool canVerify,
      bool canResult) {
    final r = result;
    final status = item.status;
    final banners = <Widget>[
      if (unacknowledged)
        LabBanner(
          tone: Tone.danger,
          icon: Icons.warning_amber_rounded,
          title: 'Critical result: ${criticalText(r!.maps('values'), item.params)}',
          message: 'Verified by ${r.str('verified_by_name')} ${formatRelative(r.date('verified_at'))}. '
              '${canAck ? 'Please acknowledge once you have acted on it.' : 'Not yet acknowledged by a doctor. Phone $doctor.'}',
          action: canAck ? FilledButton(onPressed: _acknowledge, child: const Text('Acknowledge')) : null,
        ),
      if (r != null && r.date('acknowledged_at') != null)
        LabBanner(
          tone: Tone.success,
          icon: Icons.task_alt,
          title: 'Critical result acknowledged by ${r.str('acknowledged_by_name')}',
          message: [formatDateTime(r.date('acknowledged_at')), r.str('acknowledge_note')].where((s) => s.isNotEmpty).join(' · '),
        ),
      if (status == Vals.resulted && enteredByMe && canVerify)
        const LabBanner(
          tone: Tone.info,
          icon: Icons.people_outline,
          title: 'You entered these results',
          message: 'A different pathologist must verify them.',
        ),
      if (r?.str('status') == ResultStatus.amended && mode != _Mode.amend)
        LabBanner(
          tone: Tone.warning,
          icon: Icons.edit_note,
          title: 'Amended: ${r!.str('amend_reason')}',
          message: 'The corrected report is waiting for verification.',
        ),
      if (mode == _Mode.amend)
        LabBanner(
          tone: Tone.warning,
          icon: Icons.edit_note,
          title: 'Amending a verified report',
          message: 'Reason: $_amendReason. The current version is kept in the history.',
        ),
    ];

    Widget main;
    if (status == Vals.ordered) {
      main = _CollectCard(item: item, onCollect: context.can(LabPerms.collect) ? _collect : null);
    } else if (status == Vals.cancelled) {
      main = const SectionCard(
          child: EmptyState(icon: Icons.block, title: 'This order was cancelled', message: 'No sample was taken and nothing was charged.'));
    } else if (editing) {
      main = ResultEntryForm(
        key: _form,
        params: item.params,
        sex: sex,
        initial: _currentRaw,
        initialComments: r?.str('comments') ?? '',
        previous: widget.data.previous,
        saveLabel: mode == _Mode.amend ? 'Save amended results' : 'Save results',
        doctorName: item.doctorName,
        onSave: _save,
        onCancel: _explicit != null ? () => setState(() => _explicit = null) : null,
      );
    } else {
      main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ResultsCard(item: item, previous: widget.data.previous),
          if (!context.isCompact && (status == Vals.resulted || status == Vals.verified)) ...[
            Gap.v16,
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              if (status == Vals.resulted && canVerify)
                FilledButton.icon(
                  onPressed: enteredByMe ? null : _verify,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Verify report'),
                ),
              if (status == Vals.resulted && canResult)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _explicit = _Mode.edit),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Correct results'),
                ),
              if (status == Vals.verified)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _report = true),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('Report view'),
                ),
              if (status == Vals.verified && (canResult || canVerify))
                OutlinedButton.icon(
                  onPressed: _amend,
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Amend'),
                ),
            ]),
          ],
          if ((r?.maps('history') ?? const []).isNotEmpty) ...[Gap.v16, _HistoryCard(result: r!)],
        ],
      );
    }

    final side = _TimelineCard(item: item);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 1000;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in banners) ...[b, Gap.v16],
          main,
        ],
      );
      if (wide) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            Gap.h24,
            SizedBox(width: 320, child: side),
          ],
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [content, Gap.v16, side]);
    });
  }
}

class _HeaderChips extends StatelessWidget {
  const _HeaderChips({required this.item});
  final LabItem item;

  @override
  Widget build(BuildContext context) {
    final o = item.order;
    final active = item.status != Vals.verified && item.status != Vals.cancelled;
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OrderStatusChip(item.status, resultStatus: item.result?.str('status')),
        PriorityChip(item.priority),
        if (o.strOrNull('sample_id') != null) StatusChip(o.str('sample_id'), icon: Icons.label_outline, tone: Tone.info),
        if (o.flag('critical')) const StatusChip('Critical', tone: Tone.danger, icon: Icons.warning_amber_rounded),
        if (active) TatLabel(item, now: DateTime.now()),
        if (!active && item.turnaround != null)
          Text('Turnaround ${formatDuration(item.turnaround!)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _CollectCard extends StatelessWidget {
  const _CollectCard({required this.item, required this.onCollect});
  final LabItem item;
  final VoidCallback? onCollect;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Sample not collected yet',
      subtitle: 'Results can be entered once the sample is in the lab',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoGrid([
            ('Sample', item.test?.str('sample_type') ?? '—'),
            ('Container', item.container),
            ('Report due', formatDateTime(item.due)),
            ('Clinical notes', item.order.str('clinical_notes')),
          ]),
          Gap.v16,
          if (onCollect != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onCollect,
                icon: const Icon(Icons.colorize_outlined, size: 18),
                label: const Text('Collect sample'),
              ),
            )
          else
            Text('Waiting for a nurse or technician to collect the sample.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Read-only values with flags, ranges and the previous result.
class _ResultsCard extends StatelessWidget {
  const _ResultsCard({required this.item, required this.previous});
  final LabItem item;
  final PreviousValues previous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = item.result;
    final values = r?.maps('values') ?? const [];
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final head = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    final flagged = values.where((v) => LabFlag.isAbnormal(v['flag'] as String?)).length;
    return SectionCard(
      title: 'Results',
      subtitle: r == null
          ? 'Not entered yet'
          : 'Entered by ${r.str('entered_by_name')} · ${formatDateTime(r.date('entered_at'))}'
              '${flagged > 0 ? ' · $flagged flagged' : ''}',
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 600;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(children: [
                  Expanded(flex: 4, child: Text('Parameter', style: head)),
                  Expanded(flex: 3, child: Text('Result', style: head)),
                  Expanded(flex: 3, child: Text('Reference range', style: head)),
                  Expanded(flex: 3, child: Text('Previous', style: head)),
                ]),
              ),
            for (final (i, v) in values.indexed) ...[
              if (i > 0 || wide) const Divider(height: 1),
              Container(
                color: LabFlag.isCritical(v['flag'] as String?) ? ToneColors.of(context, Tone.danger).background : null,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: wide
                    ? Row(children: [
                        Expanded(flex: 4, child: _name(context, v)),
                        Expanded(flex: 3, child: FlaggedValue(v)),
                        Expanded(flex: 3, child: Text('${v['ref'] ?? ''}', style: theme.textTheme.bodyMedium)),
                        Expanded(flex: 3, child: _prev(context, v, muted)),
                      ])
                    : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _name(context, v),
                            if ('${v['ref'] ?? ''}'.isNotEmpty) Text('Ref ${v['ref']}', style: muted),
                            _prev(context, v, muted),
                          ]),
                        ),
                        Gap.h8,
                        FlaggedValue(v),
                      ]),
              ),
            ],
            if (r != null && r.str('comments').isNotEmpty) ...[
              const Divider(height: 1),
              Gap.v12,
              Text('Comments', style: head),
              Gap.v4,
              Text(r.str('comments')),
            ],
          ],
        );
      }),
    );
  }

  Widget _name(BuildContext context, Map<String, Object?> v) {
    final theme = Theme.of(context);
    final critical = LabFlag.isCritical(v['flag'] as String?);
    if (!critical) return Text('${v['name']}', style: theme.textTheme.bodyMedium);
    final c = ToneColors.of(context, Tone.danger);
    return Row(children: [
      Icon(Icons.warning_amber_rounded, size: 16, color: c.foreground),
      Gap.h4,
      Flexible(
        child: Text('${v['name']}', style: theme.textTheme.bodyMedium?.copyWith(color: c.foreground, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  Widget _prev(BuildContext context, Map<String, Object?> v, TextStyle? muted) {
    final p = previous[v['key']];
    if (p == null) return Text('—', style: muted);
    return Text.rich(TextSpan(children: [
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: FlaggedValue(p.$1, showUnit: false, style: Theme.of(context).textTheme.bodySmall),
      ),
      TextSpan(text: ' · ${formatDateShort(p.$2)}', style: muted),
    ]));
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.item});
  final LabItem item;

  @override
  Widget build(BuildContext context) {
    final o = item.order;
    final r = item.result;
    final steps = <(String, String, bool)>[
      ('Ordered', '${formatDateTime(item.orderedAt)}${item.doctorName.isEmpty ? '' : ' · ${item.doctorName}'}', true),
      ('Sample collected', o.date('collected_at') == null ? 'Waiting' : '${formatDateTime(o.date('collected_at'))} · ${o.str('sample_id')}',
          o.date('collected_at') != null),
      ('Results entered', r == null ? 'Waiting' : '${formatDateTime(r.date('entered_at'))} · ${r.str('entered_by_name')}', r != null),
      ('Verified', r?.date('verified_at') == null ? 'Waiting' : '${formatDateTime(r!.date('verified_at'))} · ${r.str('verified_by_name')}',
          r?.date('verified_at') != null),
      if (r != null && r.flag('critical'))
        ('Doctor acknowledged',
            r.date('acknowledged_at') == null ? 'Not yet' : '${formatDateTime(r.date('acknowledged_at'))} · ${r.str('acknowledged_by_name')}',
            r.date('acknowledged_at') != null),
    ];
    final notes = o.str('clinical_notes');
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Progress',
      subtitle: 'Target ${formatDuration(Duration(minutes: targetMinutes(item.priority, item.tatMinutes)))} from order to report',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (title, sub, done)) in steps.indexed)
            _Step(title: title, subtitle: sub, done: done, last: i == steps.length - 1),
          if (notes.isNotEmpty) ...[
            Gap.v8,
            Text('Clinical notes', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            Gap.v4,
            Text(notes, style: theme.textTheme.bodyMedium),
          ],
          Gap.v12,
          Text('${item.test?.str('sample_type') ?? ''}${item.container.isEmpty ? '' : ' · ${item.container}'}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.title, required this.subtitle, required this.done, required this.last});
  final String title;
  final String subtitle;
  final bool done;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(children: [
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? cs.primary : cs.surface,
                border: Border.all(color: done ? cs.primary : cs.outline, width: 1.5),
              ),
              child: done ? Icon(Icons.check, size: 12, color: cs.onPrimary) : null,
            ),
            if (!last) Expanded(child: Container(width: 1.5, color: done ? cs.primary : cs.outlineVariant)),
          ]),
          Gap.h12,
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: done ? null : cs.onSurfaceVariant)),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.result});
  final Rec result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final history = result.maps('history').reversed.toList();
    return SectionCard(
      title: 'Earlier versions',
      subtitle: 'Kept unchanged for the record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, h) in history.indexed) ...[
            if (i > 0) const Divider(height: Gap.xl),
            Text('Replaced ${_date(h['replaced_at'])} by ${h['replaced_by_name'] ?? ''}',
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text('Reason: ${h['reason'] ?? ''}', style: theme.textTheme.bodyMedium),
            Text('Verified by ${h['verified_by_name'] ?? '—'} · ${_date(h['verified_at'])}', style: muted),
            Gap.v8,
            Wrap(
              spacing: Gap.lg,
              runSpacing: Gap.xs,
              children: [
                for (final v in (h['values'] as List? ?? const []).whereType<Map>())
                  Text.rich(TextSpan(children: [
                    TextSpan(text: '${v['name']} ', style: muted),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: FlaggedValue(v.cast<String, Object?>(), style: theme.textTheme.bodySmall),
                    ),
                  ])),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _date(Object? iso) {
    final d = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
    return d == null ? '—' : formatDateTime(d);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../opd_schema.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';
import 'vitals_dialog.dart';

enum _View { queue, seen, left, all }

class _Row {
  _Row(this.encounter, this.patient, this.consultation, this.doctor);
  final Rec encounter;
  final Rec? patient;
  final Rec? consultation;
  final Rec? doctor;

  String get name => patient?.str('full_name') ?? 'Unknown patient';
  Map<String, Object?> get vitals => consultation?.map('vitals') ?? const {};
  bool get waiting => OpdService.isWaiting(encounter);
  bool get withDoctor => encounter.str('status') == Vals.open && encounter.str('queue_status') == Vals.withDoctor;
  bool get seen => encounter.str('status') == Vals.closed;
  bool get left => encounter.str('status') == Vals.cancelled || encounter.str('queue_status') == Vals.left;
  DateTime get arrived => encounter.date('checked_in_at') ?? encounter.date('started_at')!;
}

class _QueueData {
  _QueueData(this.rows);
  final List<_Row> rows;

  List<_Row> get waiting => rows.where((r) => r.waiting).toList();
  List<_Row> get withDoctor => rows.where((r) => r.withDoctor).toList();
  List<_Row> get seen => rows.where((r) => r.seen).toList();
  List<_Row> get left => rows.where((r) => r.left).toList();
}

/// Today's OPD queue for the signed-in doctor (or any doctor, for nurses
/// and administrators): who is waiting, who is in, who has been seen.
class OpdQueueScreen extends StatefulWidget {
  const OpdQueueScreen({super.key});

  @override
  State<OpdQueueScreen> createState() => _OpdQueueScreenState();
}

class _OpdQueueScreenState extends State<OpdQueueScreen> {
  String? _doctorId;
  bool _init = false;
  List<Rec> _doctors = const [];
  _View _view = _View.queue;
  Timer? _tick;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final s = context.session;
    if (s != null && s.isClinician) _doctorId = s.userId;
    _loadDoctors();
    // Waiting times move on even when no data changes.
    _tick = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadDoctors() async {
    final rows = await context.app.readDb
        .query(const Query(Col.users).eq('is_clinician', true).eq('active', true).sort('display_name').take(200));
    if (mounted) setState(() => _doctors = rows);
  }

  Future<_QueueData> _load(ReadDb db) async {
    final encs = await db.query(OpdService.dayQuery(doctorId: _doctorId));
    final patients = await db.byIds(Col.patients, encs.map((e) => e.strOrNull('patient_id')));
    final consults = encs.isEmpty
        ? const <Rec>[]
        : await db.query(Query(OpdCol.consultations).isIn('encounter_id', encs.map((e) => e.id)).take(1000));
    final byEnc = {for (final c in consults) c.str('encounter_id'): c};
    final doctors = await db.byIds(Col.users, encs.map((e) => e.strOrNull('doctor_id')));
    final rows = [
      for (final e in encs) _Row(e, patients[e.str('patient_id')], byEnc[e.id], doctors[e.str('doctor_id')]),
    ]..sort((a, b) => OpdService.byToken(a.encounter, b.encounter));
    return _QueueData(rows);
  }

  Rec? get _me => context.session?.user;
  bool get _mine => _doctorId != null && _doctorId == context.session?.userId;

  // ------------------------------------------------------------------ actions

  Future<void> _start(_Row r) async {
    final me = _me!;
    final app = context.app;
    final ok = await runGuarded(context, () async {
      await OpdService.start(app.db, r.encounter, doctor: me);
    });
    if (ok) app.nav.open('opd.consult', {'encounterId': r.encounter.id});
  }

  Future<void> _callNext() async {
    final me = _me!;
    final next = await OpdService.nextWaiting(context.app.readDb, me.id);
    if (!mounted) return;
    if (next == null) {
      context.toast('No one is waiting for you right now');
      return;
    }
    final patient = await context.app.readDb.get(Col.patients, next.str('patient_id'));
    if (!mounted) return;
    context.toast('Token ${next.intOrNull('token_no') ?? ''} · ${patient?.str('full_name') ?? 'patient'}, please come in');
    await _start(_Row(next, patient, null, me));
  }

  Future<void> _vitals(_Row r) async {
    if (r.patient == null) return;
    await showVitalsDialog(context, encounter: r.encounter, patient: r.patient!, initial: r.vitals);
  }

  Future<void> _markLeft(_Row r) async {
    final ok = await confirmDialog(context,
        title: 'Mark ${r.name} as left?',
        message: 'Use this when the patient went away without being seen. '
            'You can put them back in the queue if they return.',
        confirmLabel: 'Mark as left');
    if (!ok || !mounted) return;
    await runGuarded(context, () => OpdService.markLeft(context.db, r.encounter), success: '${r.name} marked as left');
  }

  Future<void> _backToQueue(_Row r) =>
      runGuarded(context, () => OpdService.backToQueue(context.db, r.encounter), success: '${r.name} is back in the queue');

  void _openNote(_Row r) {
    final c = r.consultation;
    if (c == null) {
      context.toast('No note was written for this visit');
      return;
    }
    context.app.nav.open('opd.consultation', {'id': c.id});
  }

  Future<void> _walkIn() async {
    final app = context.app;
    final patient = await pickRecord(
      context,
      title: 'Walk-in patient',
      query: (s) => const Query(Col.patients).matching(s).sort('updated_at', desc: true).take(30),
      itemTitle: (p) => p.str('full_name'),
      itemSubtitle: (p) => [p.str('uhid'), patientLine(p, withUhid: false), p.str('phone')]
          .where((s) => s.isNotEmpty && s != '—')
          .join(' · '),
      emptyText: 'No patient matches. Register them first.',
      footer: app.registry.route('patients.register') == null
          ? null
          : Builder(
              builder: (c) => TextButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  app.nav.open('patients.register');
                },
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Register a new patient'),
              ),
            ),
    );
    if (patient == null || !mounted) return;
    Rec? doctor;
    if (_doctorId != null) {
      doctor = _mine ? _me : await app.readDb.get(Col.users, _doctorId);
    } else {
      doctor = await pickDoctor(context);
    }
    if (doctor == null || !mounted) return;
    final d = doctor;
    await runGuarded(context, () async {
      final (enc, created) = await OpdService.addWalkIn(app.db, patientId: patient.id, doctor: d);
      final who = d.id == _me?.id ? 'your' : "${doctorLabel(d.str('display_name'))}'s";
      app.nav.toast(created
          ? 'Token ${enc.intOrNull('token_no')} · ${patient.str('full_name')} added to $who queue'
          : '${patient.str('full_name')} is already in $who queue (token ${enc.intOrNull('token_no')})');
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final s = context.session!;
    final canConsult = context.can(OpdPerms.consult);
    final canVitals = context.can(OpdPerms.vitals);
    final now = DateTime.now();
    final doctorName = _doctorId == null
        ? 'All doctors'
        : doctorLabel(_doctors.where((d) => d.id == _doctorId).firstOrNull?.str('display_name') ??
            (_mine ? s.displayName : ''));
    final compact = context.isCompact;

    return PageScaffold(
      title: s.isClinician && _mine ? 'My OPD' : 'OPD queue',
      subtitle: '${formatWeekday(now)}, ${formatDate(now)} · $doctorName',
      primaryAction: canConsult && _mine && s.isClinician
          ? PageAction('Call next', Icons.campaign_outlined, _callNext, tourAnchor: 'opd.call_next')
          : null,
      actions: [
        if (compact) _doctorMenu(),
        if (canConsult || canVitals)
          compact
              ? IconButton(tooltip: 'Walk-in patient', onPressed: _walkIn, icon: const Icon(Icons.person_add_alt_1_outlined))
              : OutlinedButton.icon(onPressed: _walkIn, icon: const Icon(Icons.person_add_alt_1_outlined), label: const Text('Walk-in')),
      ],
      body: LiveBuilder<_QueueData>(
        watch: const {Col.encounters, OpdCol.consultations, Col.patients},
        deps: [_doctorId],
        load: _load,
        builder: (context, data) => TourAnchor(
          id: 'opd.queue',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Counters(data: data),
              Gap.v16,
              _filters(context, data),
              Gap.v12,
              _list(context, data, canConsult: canConsult, canVitals: canVitals),
            ],
          ),
        ),
      ),
    );
  }

  /// On phones the doctor choice lives in a menu to save space.
  Widget _doctorMenu() => PopupMenuButton<String>(
        tooltip: 'Choose doctor',
        icon: const Icon(Icons.manage_accounts_outlined),
        onSelected: (v) => setState(() => _doctorId = v.isEmpty ? null : v),
        itemBuilder: (c) => [
          CheckedPopupMenuItem(value: '', checked: _doctorId == null, child: const Text('All doctors')),
          for (final d in _doctors)
            CheckedPopupMenuItem(
              value: d.id,
              checked: _doctorId == d.id,
              child: Text([doctorLabel(d.str('display_name')), d.str('department')].where((x) => x.isNotEmpty).join(' · ')),
            ),
        ],
      );

  Widget _filters(BuildContext context, _QueueData data) {
    final chips = FilterChips<_View>(
      options: [
        (_View.queue, 'In queue · ${data.waiting.length + data.withDoctor.length}'),
        (_View.seen, 'Seen · ${data.seen.length}'),
        (_View.left, 'Left · ${data.left.length}'),
        (_View.all, 'All · ${data.rows.length}'),
      ],
      value: _view,
      onChanged: (v) => setState(() => _view = v),
    );
    final doctorPicker = SizedBox(
      width: context.isCompact ? double.infinity : 280,
      child: AppDropdown<String>(
        label: 'Doctor',
        value: _doctorId ?? '',
        items: [
          ('', 'All doctors'),
          for (final d in _doctors)
            (d.id, [doctorLabel(d.str('display_name')), d.str('department')].where((x) => x.isNotEmpty).join(' · ')),
        ],
        onChanged: (v) => setState(() => _doctorId = (v == null || v.isEmpty) ? null : v),
      ),
    );
    if (context.isCompact) return chips;
    return Row(children: [Expanded(child: chips), Gap.h16, doctorPicker]);
  }

  List<_Row> _visible(_QueueData d) => switch (_view) {
        _View.queue => [...d.withDoctor, ...d.waiting],
        _View.seen => d.seen
          ..sort((a, b) => (b.encounter.date('ended_at') ?? b.arrived).compareTo(a.encounter.date('ended_at') ?? a.arrived)),
        _View.left => d.left,
        _View.all => d.rows,
      };

  String _timing(_Row r) {
    final now = DateTime.now();
    if (r.seen) {
      final called = r.encounter.date('called_at');
      final ended = r.encounter.date('ended_at');
      final took = called != null && ended != null ? ' · ${formatDuration(ended.difference(called))}' : '';
      return 'Seen ${formatTime(ended)}$took';
    }
    if (r.left) return 'Left ${formatTime(r.encounter.date('ended_at'))}';
    if (r.withDoctor) return 'In since ${formatTime(r.encounter.date('called_at'))}';
    final wait = now.difference(r.arrived);
    return 'Waiting ${formatDuration(wait.isNegative ? Duration.zero : wait)}';
  }

  Widget _vitalsCell(_Row r) {
    final v = r.vitals;
    if (v.isEmpty) return const Caption('Not recorded');
    final critical = Vitals.critical(v);
    if (critical.isNotEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: StatusChip(critical.join(' · '), icon: Icons.priority_high, tone: Tone.danger),
      );
    }
    return KeyVitals(v);
  }

  Widget _primaryButton(_Row r, {required bool canConsult, required bool canVitals}) {
    final mineOrUnassigned = r.encounter.strOrNull('doctor_id') == null || r.encounter.str('doctor_id') == _me?.id;
    if (r.seen) {
      return OutlinedButton(onPressed: () => _openNote(r), child: const Text('View note'));
    }
    if (r.left) {
      return OutlinedButton(onPressed: () => _backToQueue(r), child: const Text('Back in queue'));
    }
    if (canConsult && context.session!.isClinician && mineOrUnassigned) {
      return FilledButton(
        onPressed: () => _start(r),
        child: Text(r.withDoctor ? 'Continue' : 'Start'),
      );
    }
    if (canVitals) {
      return FilledButton.tonal(onPressed: () => _vitals(r), child: const Text('Vitals'));
    }
    return const SizedBox.shrink();
  }

  Widget _menu(_Row r, {required bool canConsult, required bool canVitals}) {
    final app = context.app;
    final open = !r.seen && !r.left;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'vitals':
            _vitals(r);
          case 'left':
            _markLeft(r);
          case 'note':
            _openNote(r);
          case 'profile':
            app.nav.open('patients.profile', {'id': r.encounter.str('patient_id')});
        }
      },
      itemBuilder: (c) => [
        if (open && canVitals)
          const PopupMenuItem(value: 'vitals', child: ListTile(leading: Icon(Icons.monitor_heart_outlined), title: Text('Record vitals'))),
        if (open && (canConsult || canVitals))
          const PopupMenuItem(value: 'left', child: ListTile(leading: Icon(Icons.directions_walk), title: Text('Mark as left'))),
        if (r.seen) const PopupMenuItem(value: 'note', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('View note'))),
        if (app.registry.route('patients.profile') != null)
          const PopupMenuItem(value: 'profile', child: ListTile(leading: Icon(Icons.person_outline), title: Text('Patient profile'))),
      ],
    );
  }

  Widget _list(BuildContext context, _QueueData data, {required bool canConsult, required bool canVitals}) {
    final rows = _visible(data);
    final theme = Theme.of(context);
    final showDoctor = _doctorId == null;
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    Widget patientCell(_Row r) => Row(children: [
          Expanded(
            child: TwoLine(
              r.name,
              wide
                  ? [r.patient?.str('uhid') ?? '', if (showDoctor) doctorLabel(r.doctor?.str('display_name') ?? '')]
                      .where((s) => s.isNotEmpty)
                      .join(' · ')
                  : [if (r.patient != null) patientLine(r.patient!, withUhid: false), if (showDoctor) doctorLabel(r.doctor?.str('display_name') ?? '')]
                      .join(' · '),
            ),
          ),
          if (r.patient != null && !Allergy.isNone(r.patient!.str('allergies')))
            Tooltip(
              message: 'Allergies: ${r.patient!.str('allergies')}',
              child: Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
            ),
        ]);

    return DataList<_Row>(
      items: rows,
      empty: EmptyState(
        icon: _view == _View.queue ? Icons.event_seat_outlined : Icons.inbox_outlined,
        title: switch (_view) {
          _View.queue => 'No one is waiting',
          _View.seen => 'No one seen yet today',
          _View.left => 'Nobody left without being seen',
          _View.all => 'No OPD visits today',
        },
        message: _view == _View.queue ? 'Patients checked in at the front desk appear here with their token.' : null,
        action: _view == _View.queue && (canConsult || canVitals)
            ? OutlinedButton.icon(onPressed: _walkIn, icon: const Icon(Icons.person_add_alt_1_outlined), label: const Text('Add a walk-in'))
            : null,
      ),
      onTap: (r) {
        if (r.seen) {
          _openNote(r);
        } else if (r.left) {
          _backToQueue(r);
        } else if (canConsult && context.session!.isClinician) {
          _start(r);
        } else if (canVitals) {
          _vitals(r);
        }
      },
      leading: (r) => TokenBadge(r.encounter.intOrNull('token_no'), tone: queueState(r.encounter).$2),
      title: (r) => r.name,
      subtitle: (r) => [
        [if (r.patient != null) patientLine(r.patient!, withUhid: false), _timing(r)].join(' · '),
        if (r.vitals.isNotEmpty) Vitals.summary(keyVitals(r.vitals)),
        if (showDoctor) doctorLabel(r.doctor?.str('display_name') ?? ''),
      ].join('\n'),
      trailing: (r) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusChip(queueState(r.encounter).$1, tone: queueState(r.encounter).$2),
              if (Vitals.critical(r.vitals).isNotEmpty) ...[
                Gap.v4,
                const StatusChip('Critical', icon: Icons.priority_high, tone: Tone.danger),
              ],
            ],
          ),
          _menu(r, canConsult: canConsult, canVitals: canVitals),
        ],
      ),
      columns: [
        ListColumn('Token', (r) => TokenBadge(r.encounter.intOrNull('token_no'), tone: queueState(r.encounter).$2), width: 64),
        ListColumn('Patient', patientCell, flex: 4),
        if (wide)
          ListColumn('Age / sex', (r) => Text(r.patient == null ? '—' : patientLine(r.patient!, withUhid: false))),
        ListColumn('Arrived', (r) => TwoLine(formatTime(r.arrived), _timing(r)), flex: 2),
        ListColumn('Vitals', _vitalsCell, flex: wide ? 3 : 2),
        ListColumn('Status', (r) => StatusChip(queueState(r.encounter).$1, tone: queueState(r.encounter).$2), width: 112),
        ListColumn(
          '',
          (r) => Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _primaryButton(r, canConsult: canConsult, canVitals: canVitals),
              _menu(r, canConsult: canConsult, canVitals: canVitals),
            ],
          ),
          width: 176,
          numeric: true,
        ),
      ],
    );
  }
}

class _Counters extends StatelessWidget {
  const _Counters({required this.data});
  final _QueueData data;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final waiting = data.waiting;
    final longest = waiting.isEmpty
        ? null
        : waiting.map((r) => now.difference(r.arrived)).reduce((a, b) => a > b ? a : b);
    final consultTimes = [
      for (final r in data.seen)
        if (r.encounter.date('called_at') != null && r.encounter.date('ended_at') != null)
          r.encounter.date('ended_at')!.difference(r.encounter.date('called_at')!).inMinutes,
    ];
    final avg = consultTimes.isEmpty ? null : (consultTimes.reduce((a, b) => a + b) / consultTimes.length).round();
    final inRoom = data.withDoctor;
    final stats = [
      _Stat(
        label: 'Waiting',
        value: '${waiting.length}',
        caption: longest == null ? 'Queue is clear' : 'Longest ${formatDuration(longest.isNegative ? Duration.zero : longest)}',
        icon: Icons.event_seat_outlined,
        tone: waiting.length > 8 ? Tone.warning : Tone.info,
      ),
      _Stat(
        label: 'With doctor',
        value: '${inRoom.length}',
        caption: inRoom.isEmpty ? 'Nobody in the room' : inRoom.map((r) => r.name).join(', '),
        icon: Icons.medical_services_outlined,
        tone: Tone.info,
      ),
      _Stat(
        label: 'Seen today',
        value: '${data.seen.length}',
        caption: avg == null ? 'No one yet' : 'Average $avg min each',
        icon: Icons.task_alt,
        tone: Tone.success,
      ),
      _Stat(
        label: 'Left unseen',
        value: '${data.left.length}',
        caption: data.left.isEmpty ? 'None today' : 'Call back if they return',
        icon: Icons.directions_walk,
        tone: data.left.isEmpty ? Tone.neutral : Tone.warning,
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 640) {
            return IntrinsicHeight(
              child: Row(children: [
                for (final (i, s) in stats.indexed) ...[
                  if (i > 0) const VerticalDivider(width: Gap.xl),
                  Expanded(child: s),
                ],
              ]),
            );
          }
          return Column(children: [
            Row(children: [Expanded(child: stats[0]), Gap.h16, Expanded(child: stats[1])]),
            const Divider(height: Gap.xl),
            Row(children: [Expanded(child: stats[2]), Gap.h16, Expanded(child: stats[3])]),
          ]);
        }),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.caption, required this.icon, required this.tone});
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, tone);
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.md)),
        child: Icon(icon, size: 20, color: c.foreground),
      ),
      Gap.h12,
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            Gap.h8,
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
          Caption(caption, maxLines: 1),
        ]),
      ),
    ]);
  }
}

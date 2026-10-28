import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';

/// Weekly OPD sessions per doctor. Appointment slots are made from these.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, this.doctorId});
  final String? doctorId;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  late String? _doctorId = widget.doctorId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(List<Rec>, List<Rec>)>(
      watch: const {ApptCol.schedules, Col.users},
      loading: const Scaffold(body: LoadingView()),
      load: (db) async => (await AppointmentService.doctors(db), await AppointmentService.allSchedules(db)),
      builder: (context, data) {
        final (doctors, schedules) = data;
        final doctor = doctors.where((d) => d.id == _doctorId).firstOrNull ?? doctors.firstOrNull;
        final mine = doctor == null ? const <Rec>[] : schedules.where((s) => s.str('doctor_id') == doctor.id).toList();
        return PageScaffold(
          title: 'Doctor schedules',
          subtitle: 'Weekly OPD sessions. Appointment slots are made from these.',
          headerBottom: doctors.isEmpty
              ? null
              : FilterChips<String>(
                  options: [
                    for (final d in doctors)
                      (d.id, '${d.str('display_name')} · ${_hoursLabel(schedules.where((s) => s.str('doctor_id') == d.id))}'),
                  ],
                  value: doctor!.id,
                  onChanged: (id) => setState(() => _doctorId = id),
                ),
          body: doctor == null
              ? const Card(
                  child: EmptyState(
                    icon: Icons.person_search_outlined,
                    title: 'No doctors yet',
                    message: 'Add staff marked as clinicians in Administration, then set their OPD days here.',
                  ),
                )
              : _WeekCard(doctor: doctor, sessions: mine),
        );
      },
    );
  }

  static String _hoursLabel(Iterable<Rec> sessions) {
    final minutes = sessions.fold<int>(0, (n, s) => n + (s.integer('end_minute') - s.integer('start_minute')));
    if (minutes == 0) return 'no sessions';
    final h = minutes / 60;
    return '${h == h.roundToDouble() ? h.round() : h.toStringAsFixed(1)} h a week';
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.doctor, required this.sessions});
  final Rec doctor;
  final List<Rec> sessions;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    final slots = sessions.fold<int>(0, (n, s) {
      final len = s.integer('slot_minutes', AppointmentService.defaultSlotMinutes);
      return n + ((s.integer('end_minute') - s.integer('start_minute')) ~/ (len <= 0 ? 15 : len));
    });
    final copy = compact
        ? IconButton(
            tooltip: 'Copy Monday to other days',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => _copyMonday(context, doctor, sessions),
          )
        : OutlinedButton.icon(
            onPressed: () => _copyMonday(context, doctor, sessions),
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            label: const Text('Copy Monday to other days'),
          );
    return SectionCard(
      title: doctor.str('display_name'),
      subtitle: [doctor.str('department'), '${plural(slots, 'slot')} a week'].where((s) => s.isNotEmpty).join(' · '),
      trailing: TourAnchor(id: 'appointments.copy_monday', child: copy),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var wd = DateTime.monday; wd <= DateTime.sunday; wd++) ...[
            const Divider(height: 1),
            _DayRow(
              doctor: doctor,
              weekday: wd,
              sessions: sessions.where((s) => s.integer('weekday') == wd).toList()
                ..sort((a, b) => a.integer('start_minute').compareTo(b.integer('start_minute'))),
              all: sessions,
            ),
          ],
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.doctor, required this.weekday, required this.sessions, required this.all});
  final Rec doctor;
  final int weekday;
  final List<Rec> sessions;
  final List<Rec> all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = context.isCompact;
    final add = TextButton.icon(
      onPressed: () => _editSession(context, doctor, all, weekday: weekday),
      icon: const Icon(Icons.add, size: 20),
      label: Text(sessions.isEmpty ? 'Add session' : 'Add'),
    );
    final chips = Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('No OPD', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
          ),
        for (final s in sessions)
          InputChip(
            avatar: const Icon(Icons.schedule, size: 18),
            label: Text([
              AppointmentService.sessionLabel(s),
              '${s.integer('slot_minutes', 15)} min',
              if (s.str('room').isNotEmpty) s.str('room'),
            ].join(' · ')),
            tooltip: 'Tap to change',
            onPressed: () => _editSession(context, doctor, all, existing: s),
            deleteIcon: const Icon(Icons.close, size: 18),
            deleteButtonTooltipMessage: 'Remove session',
            onDeleted: () => _remove(context, s),
          ),
      ],
    );
    final day = Text(weekdayName(weekday), style: theme.textTheme.titleSmall);
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: day), add]),
          chips,
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Row(children: [
        SizedBox(width: 130, child: day),
        Expanded(child: chips),
        add,
      ]),
    );
  }

  Future<void> _remove(BuildContext context, Rec s) async {
    final ok = await confirmDialog(
      context,
      title: 'Remove this session?',
      message: '${weekdayName(s.integer('weekday'))} ${AppointmentService.sessionLabel(s)}. '
          'Appointments already booked stay as they are.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await runGuarded(context, () => context.db.archive(ApptCol.schedules, s.id, reason: 'Session removed'),
        success: 'Session removed');
  }
}

Future<void> _editSession(BuildContext context, Rec doctor, List<Rec> all, {Rec? existing, int? weekday}) =>
    showFormSheet<bool>(
      context,
      title: existing == null ? 'Add OPD session' : 'Change OPD session',
      width: 560,
      builder: (c) => _SessionForm(doctor: doctor, all: all, existing: existing, weekday: weekday ?? DateTime.monday),
    );

class _SessionForm extends StatefulWidget {
  const _SessionForm({required this.doctor, required this.all, required this.existing, required this.weekday});
  final Rec doctor;
  final List<Rec> all;
  final Rec? existing;
  final int weekday;

  @override
  State<_SessionForm> createState() => _SessionFormState();
}

class _SessionFormState extends State<_SessionForm> {
  late int _weekday = widget.existing?.integer('weekday') ?? widget.weekday;
  late int _start = widget.existing?.integer('start_minute') ?? _defaultStart();
  late int _end = widget.existing?.integer('end_minute') ?? (_start + 4 * 60).clamp(0, 23 * 60 + 45);
  late int _slot = widget.existing?.integer('slot_minutes', 15) ?? 15;
  late final _room = TextEditingController(text: widget.existing?.str('room') ?? _guessRoom());
  bool _saving = false;

  int _defaultStart() {
    // After the doctor's last session that day, else 9:00 AM.
    final same = widget.all.where((s) => s.integer('weekday') == widget.weekday).map((s) => s.integer('end_minute'));
    if (same.isEmpty) return 9 * 60;
    final last = same.reduce((a, b) => a > b ? a : b);
    return (last + 4 * 60 <= 23 * 60) ? ((last ~/ 60) + 4) * 60 : 9 * 60;
  }

  String _guessRoom() => widget.all.map((s) => s.str('room')).firstWhere((r) => r.isNotEmpty, orElse: () => '');

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  String? _problem() {
    if (_end <= _start) return 'The session must end after it starts.';
    if (_end - _start < _slot) return 'The session is shorter than one slot.';
    for (final s in widget.all) {
      if (s.id == widget.existing?.id || s.integer('weekday') != _weekday) continue;
      if (_start < s.integer('end_minute') && _end > s.integer('start_minute')) {
        return 'Overlaps the ${AppointmentService.sessionLabel(s)} session on ${weekdayName(_weekday)}.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (_problem() != null) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final values = {
      'doctor_id': widget.doctor.id,
      'weekday': _weekday,
      'start_minute': _start,
      'end_minute': _end,
      'slot_minutes': _slot,
      'room': _room.text.trim(),
      'active': true,
    };
    final ex = widget.existing;
    final ok = await runGuarded(
      context,
      () => ex == null
          ? context.db.insert(ApptCol.schedules, values)
          : context.db.update(ApptCol.schedules, ex.id, values, expectedVersion: ex.version),
      success: '${weekdayName(_weekday)} ${AppointmentService.minuteLabel(_start)} – '
          '${AppointmentService.minuteLabel(_end)} saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final times = [for (var m = 6 * 60; m <= 23 * 60 + 45; m += 15) (m, AppointmentService.minuteLabel(m))];
    final problem = _problem();
    final count = _end > _start ? (_end - _start) ~/ _slot : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.doctor.str('display_name'), style: theme.textTheme.titleMedium),
        Gap.v16,
        const SubHeading('Day'),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (var wd = DateTime.monday; wd <= DateTime.sunday; wd++)
            ChoiceChip(
              label: Text(weekdayName(wd).substring(0, 3)),
              selected: _weekday == wd,
              showCheckmark: false,
              onSelected: (_) => setState(() => _weekday = wd),
            ),
        ]),
        Gap.v16,
        FormGrid(minFieldWidth: 200, children: [
          AppDropdown<int>(
            label: 'Starts',
            value: _start,
            items: times,
            onChanged: (v) => setState(() {
              if (v == null) return;
              final len = _end - _start;
              _start = v;
              if (_end <= _start) _end = (_start + (len > 0 ? len : 4 * 60)).clamp(0, 23 * 60 + 45);
            }),
          ),
          AppDropdown<int>(
            key: ValueKey('end$_end'),
            label: 'Ends',
            value: _end,
            items: times,
            onChanged: (v) => setState(() => _end = v ?? _end),
          ),
        ]),
        Gap.v16,
        const SubHeading('Minutes per patient'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 10, label: Text('10')),
            ButtonSegment(value: 15, label: Text('15')),
            ButtonSegment(value: 20, label: Text('20')),
            ButtonSegment(value: 30, label: Text('30')),
          ],
          selected: {_slot},
          onSelectionChanged: (s) => setState(() => _slot = s.first),
        ),
        Gap.v16,
        AppTextField(label: 'Room', hint: 'e.g. Room 3', controller: _room),
        Gap.v16,
        Text(
          problem ?? '${plural(count, 'slot')} of $_slot minutes.',
          style: theme.textTheme.bodyMedium?.copyWith(
              color: problem == null ? theme.colorScheme.onSurfaceVariant : ToneColors.of(context, Tone.danger).foreground),
        ),
        Gap.v24,
        FilledButton.icon(
          onPressed: _saving || problem != null ? null : _save,
          icon: const Icon(Icons.check),
          label: const Text('Save session'),
        ),
      ],
    );
  }
}

Future<void> _copyMonday(BuildContext context, Rec doctor, List<Rec> sessions) async {
  final monday = sessions.where((s) => s.integer('weekday') == DateTime.monday).toList();
  if (monday.isEmpty) {
    context.app.nav.toast('Add Monday\'s sessions first, then copy them', error: true);
    return;
  }
  final days = await showDialog<Set<int>>(context: context, builder: (c) => _CopyDialog(monday: monday));
  if (days == null || days.isEmpty || !context.mounted) return;
  final ops = <WriteOp>[
    for (final s in sessions)
      if (days.contains(s.integer('weekday'))) ArchiveOp(ApptCol.schedules, s.id, reason: 'Replaced by Monday copy'),
    for (final wd in days)
      for (final s in monday)
        InsertOp(ApptCol.schedules, {
          'doctor_id': doctor.id,
          'weekday': wd,
          'start_minute': s.integer('start_minute'),
          'end_minute': s.integer('end_minute'),
          'slot_minutes': s.integer('slot_minutes', 15),
          'room': s.str('room'),
          'active': true,
        }),
  ];
  await runGuarded(context, () => context.db.batch(ops),
      success: 'Monday copied to ${plural(days.length, 'day')}');
}

class _CopyDialog extends StatefulWidget {
  const _CopyDialog({required this.monday});
  final List<Rec> monday;

  @override
  State<_CopyDialog> createState() => _CopyDialogState();
}

class _CopyDialogState extends State<_CopyDialog> {
  final _days = {DateTime.tuesday, DateTime.wednesday, DateTime.thursday, DateTime.friday, DateTime.saturday};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Copy Monday to other days'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Monday: ${widget.monday.map(AppointmentService.sessionLabel).join(', ')}. '
                'Sessions already on the chosen days are replaced.'),
            Gap.v16,
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (var wd = DateTime.tuesday; wd <= DateTime.sunday; wd++)
                FilterChip(
                  label: Text(weekdayName(wd)),
                  selected: _days.contains(wd),
                  onSelected: (v) => setState(() => v ? _days.add(wd) : _days.remove(wd)),
                ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _days.isEmpty ? null : () => Navigator.pop(context, {..._days}),
          child: Text('Copy to ${plural(_days.length, 'day')}'),
        ),
      ],
    );
  }
}

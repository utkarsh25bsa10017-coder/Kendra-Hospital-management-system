import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';
import 'common.dart';

/// The front desk's day: every doctor's slots, every appointment with a
/// one-tap next step, and the walk-in button.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, this.initialDate, this.initialDoctorId});
  final DateTime? initialDate;
  final String? initialDoctorId;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late DateTime _day = dayOf(widget.initialDate ?? DateTime.now());
  late String? _doctorId = widget.initialDoctorId;
  bool _doctorDefaulted = false;
  String? _status;
  bool _showSlots = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Wait times, "late" labels and past slots move with the clock.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _setDay(DateTime d) => setState(() {
        _day = dayOf(d);
        _status = null;
      });

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<DayData>(
      watch: const {ApptCol.appointments, ApptCol.schedules, Col.encounters},
      deps: [_day],
      loading: const Scaffold(body: LoadingView()),
      load: (db) => DayData.load(db, _day),
      builder: (context, data) {
        // A doctor sees their own day first.
        if (!_doctorDefaulted) {
          _doctorDefaulted = true;
          final me = context.session?.userId;
          if (_doctorId == null && me != null && data.doctorById.containsKey(me) && !context.can(AppointmentPerms.manage)) {
            _doctorId = me;
          }
        }
        return _page(context, data);
      },
    );
  }

  Widget _page(BuildContext context, DayData data) {
    final app = context.app;
    final canManage = context.can(AppointmentPerms.manage);
    final compact = context.isCompact;
    final now = DateTime.now();
    final mine = data.appointments.where((a) => _doctorId == null || a.str('doctor_id') == _doctorId).toList();
    final counts = <String, int>{};
    for (final a in mine) {
      counts.update(data.status(a), (v) => v + 1, ifAbsent: () => 1);
    }
    final shown = _status == null ? mine : mine.where((a) => data.status(a) == _status).toList();
    final missed = mine
        .where((a) =>
            data.status(a) == ApptStatus.booked &&
            a.date('start_at')!.isBefore(now.subtract(const Duration(hours: 2))))
        .toList();
    final isToday = sameDay(_day, now);

    return PageScaffold(
      title: 'Appointments',
      subtitle: '${isToday ? 'Today' : dayLabel(_day)} · ${weekdayName(_day.weekday)}, ${formatDate(_day)} · '
          '${plural(mine.length, 'appointment')}',
      primaryAction: canManage
          ? PageAction('Walk-in', Icons.directions_walk, () => startWalkIn(context), tourAnchor: 'appointments.walk_in')
          : null,
      actions: [
        if (canManage)
          compact
              ? IconButton(
                  tooltip: 'Book appointment',
                  icon: const Icon(Icons.edit_calendar_outlined),
                  onPressed: () => app.nav.open('appointments.book', {'date': _day, 'doctorId': ?_doctorId}),
                )
              : OutlinedButton.icon(
                  onPressed: () => app.nav.open('appointments.book', {'date': _day, 'doctorId': ?_doctorId}),
                  icon: const Icon(Icons.edit_calendar_outlined, size: 20),
                  label: const Text('Book appointment'),
                ),
      ],
      headerBottom: TourAnchor(
        id: 'appointments.day',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Filters(
              compact: compact,
              day: _day,
              onDay: _setDay,
              doctors: data.doctors,
              doctorId: _doctorId,
              countFor: (id) => data.appointments.where((a) => a.str('doctor_id') == id).length,
              onDoctor: (id) => setState(() {
                _doctorId = id;
                _status = null;
              }),
            ),
            Gap.v12,
            _SummaryChips(
              counts: counts,
              selected: _status,
              onSelected: (s) => setState(() => _status = s == _status ? null : s),
            ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (missed.isNotEmpty && canManage) ...[_MissedBanner(missed: missed, data: data), Gap.v16],
          if (context.isExpanded)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _AppointmentList(data: data, items: shown, doctorId: _doctorId, grouped: _status == null)),
                Gap.h16,
                SizedBox(width: 372, child: _SlotsPanel(data: data, doctorId: _doctorId)),
              ],
            )
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('List'), icon: Icon(Icons.view_list_outlined)),
                  ButtonSegment(value: true, label: Text('Slots'), icon: Icon(Icons.grid_view_outlined)),
                ],
                selected: {_showSlots},
                onSelectionChanged: (s) => setState(() => _showSlots = s.first),
              ),
            ),
            Gap.v12,
            if (_showSlots)
              _SlotsPanel(data: data, doctorId: _doctorId)
            else
              _AppointmentList(data: data, items: shown, doctorId: _doctorId, grouped: _status == null),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- header

class _Filters extends StatelessWidget {
  const _Filters({
    required this.compact,
    required this.day,
    required this.onDay,
    required this.doctors,
    required this.doctorId,
    required this.countFor,
    required this.onDoctor,
  });
  final bool compact;
  final DateTime day;
  final ValueChanged<DateTime> onDay;
  final List<Rec> doctors;
  final String? doctorId;
  final int Function(String id) countFor;
  final ValueChanged<String?> onDoctor;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final presets = [
      DateTime(now.year, now.month, now.day - 1),
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day + 1),
    ];
    final custom = !presets.any((d) => sameDay(d, day));
    final dateChips = <Widget>[
      for (final d in presets)
        ChoiceChip(
          label: Text(dayLabel(d, now: now)),
          selected: sameDay(d, day),
          showCheckmark: false,
          onSelected: (_) => onDay(d),
        ),
      ChoiceChip(
        avatar: const Icon(Icons.calendar_today_outlined, size: 16),
        label: Text(custom ? '${formatWeekday(day)} ${formatDate(day)}' : 'Pick date'),
        selected: custom,
        showCheckmark: false,
        onSelected: (_) async {
          final d = await showDatePicker(
            context: context,
            initialDate: day,
            firstDate: DateTime(now.year - 2),
            lastDate: DateTime(now.year + 1, now.month, now.day),
          );
          if (d != null) onDay(d);
        },
      ),
    ];
    final doctorChips = <Widget>[
      ChoiceChip(
        label: const Text('All doctors'),
        selected: doctorId == null,
        showCheckmark: false,
        onSelected: (_) => onDoctor(null),
      ),
      for (final d in doctors)
        ChoiceChip(
          label: Text('${d.str('display_name')}  ${countFor(d.id)}'),
          selected: doctorId == d.id,
          showCheckmark: false,
          onSelected: (_) => onDoctor(d.id),
        ),
    ];
    Widget row(List<Widget> chips) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, c) in chips.indexed) Padding(padding: EdgeInsets.only(left: i == 0 ? 0 : Gap.sm), child: c),
          ],
        );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: row(dateChips)),
          Gap.v8,
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: row(doctorChips)),
        ],
      );
    }
    return Wrap(
      spacing: Gap.xl,
      runSpacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        row(dateChips),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: row(doctorChips)),
      ],
    );
  }
}

class _SummaryChips extends StatelessWidget {
  const _SummaryChips({required this.counts, required this.selected, required this.onSelected});
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String> onSelected;

  static const _order = [
    ApptStatus.booked,
    ApptStatus.checkedIn,
    ApptStatus.inConsultation,
    ApptStatus.completed,
    ApptStatus.noShow,
    ApptStatus.cancelled,
  ];

  @override
  Widget build(BuildContext context) {
    final chips = [
      for (final s in _order)
        if (s != ApptStatus.cancelled || (counts[s] ?? 0) > 0)
          _CountChip(
            label: ApptStatus.label(s),
            count: counts[s] ?? 0,
            tone: ApptStatus.tone(s),
            selected: selected == s,
            onTap: () => onSelected(s),
          ),
    ];
    if (context.isCompact) {
      // One swipeable row keeps the list in view on phones.
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (i, c) in chips.indexed) Padding(padding: EdgeInsets.only(left: i == 0 ? 0 : Gap.sm), child: c),
        ]),
      );
    }
    return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: chips);
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label, required this.count, required this.tone, required this.selected, required this.onTap});
  final String label;
  final int count;
  final Tone tone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, tone);
    return Tooltip(
      message: selected ? 'Show all' : 'Show only "$label"',
      child: Material(
        color: c.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: selected ? theme.colorScheme.primary : c.border, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$count',
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: c.foreground,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  Gap.h8,
                  Text(label, style: theme.textTheme.labelLarge?.copyWith(color: c.foreground)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MissedBanner extends StatelessWidget {
  const _MissedBanner({required this.missed, required this.data});
  final List<Rec> missed;
  final DayData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, Tone.warning);
    final n = missed.length;
    final names = missed.take(3).map((a) => '${firstName(data.patientName(a))} (${formatTime(a.date('start_at'))})').join(', ');
    final button = FilledButton(
      onPressed: () async {
        final ok = await confirmDialog(
          context,
          title: 'Mark ${plural(n, 'appointment')} as no-show?',
          message: '$names${n > 3 ? ' and ${n - 3} more' : ''}. Anyone who arrives later can still come as a walk-in.',
          confirmLabel: 'Mark no-show',
        );
        if (!ok || !context.mounted) return;
        await runGuarded(context, () async {
          final (marked, _) = await AppointmentService.markNoShowMany(context.db, missed.map((a) => a.id));
          context.app.nav.toast('Marked ${plural(marked, 'appointment')} as no-show');
        });
      },
      child: const Text('Mark as no-show'),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${plural(n, 'patient')} did not come', style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
        Text('$names${n > 3 ? ' and ${n - 3} more' : ''} · more than 2 hours late',
            style: theme.textTheme.bodySmall?.copyWith(color: c.foreground)),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.lg)),
      child: context.isCompact
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(Icons.event_busy_outlined, color: c.foreground), Gap.h12, Expanded(child: text)]),
              Gap.v8,
              Align(alignment: Alignment.centerRight, child: button),
            ])
          : Row(children: [
              Icon(Icons.event_busy_outlined, color: c.foreground),
              Gap.h12,
              Expanded(child: text),
              Gap.h12,
              button,
            ]),
    );
  }
}

// ---------------------------------------------------------------- list

class _AppointmentList extends StatelessWidget {
  const _AppointmentList({required this.data, required this.items, required this.doctorId, required this.grouped});
  final DayData data;
  final List<Rec> items;
  final String? doctorId;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      final canManage = context.can(AppointmentPerms.manage);
      final noSessions = (doctorId == null ? data.doctors : data.doctors.where((d) => d.id == doctorId))
          .every((d) => AppointmentService.slotsForDay(data.schedulesOf(d.id), data.day).isEmpty);
      return Card(
        child: EmptyState(
          icon: Icons.event_available_outlined,
          title: grouped ? 'No appointments on this day' : 'Nothing with this status',
          message: noSessions
              ? 'There is no OPD session on ${weekdayName(data.day.weekday)}.'
              : (canManage ? 'Tap a free slot to book, or use Walk-in when a patient arrives.' : null),
          action: canManage && !noSessions && grouped
              ? FilledButton.icon(
                  onPressed: () => context.app.nav.open('appointments.book', {'date': data.day, 'doctorId': ?doctorId}),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Book appointment'),
                )
              : null,
        ),
      );
    }
    final now = DateTime.now();
    if (!grouped || !sameDay(data.day, now)) return _ListBlock(data: data, items: items, doctorId: doctorId);

    // Today: what needs doing first.
    final toCome = items.where((a) => data.status(a) == ApptStatus.booked).toList();
    final inClinic = items
        .where((a) => {ApptStatus.checkedIn, ApptStatus.inConsultation}.contains(data.status(a)))
        .toList()
      ..sort((a, b) => a.integer('token_no').compareTo(b.integer('token_no')));
    final finished = items
        .where((a) => {ApptStatus.completed, ApptStatus.noShow, ApptStatus.cancelled}.contains(data.status(a)))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (title, list) in [
          ('Still to arrive', toCome),
          ('In the clinic', inClinic),
          ('Finished', finished),
        ])
          if (list.isNotEmpty) ...[
            SubHeading('$title · ${list.length}'),
            _ListBlock(data: data, items: list, doctorId: doctorId),
            Gap.v12,
          ],
      ],
    );
  }
}

class _ListBlock extends StatelessWidget {
  const _ListBlock({required this.data, required this.items, required this.doctorId});
  final DayData data;
  final List<Rec> items;
  final String? doctorId;

  @override
  Widget build(BuildContext context) {
    if (context.isCompact) {
      return Column(children: [for (final a in items) _ApptCard(data: data, appointment: a)]);
    }
    final app = context.app;
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 980;
      return DataList<Rec>(
        items: items,
        onTap: app.nav.canOpen('patients.profile')
            ? (a) => app.nav.open('patients.profile', {'id': a.str('patient_id')})
            : null,
        title: data.patientName,
        columns: [
          ListColumn('Time', (a) => _TimeCell(a), width: 92),
          ListColumn(
              'Token',
              (a) => a.intOrNull('token_no') == null
                  ? Text('—', style: TextStyle(color: Theme.of(context).colorScheme.outline))
                  : TokenBadge(a.integer('token_no'), size: 32, tone: ApptStatus.tone(data.status(a))),
              width: 60),
          ListColumn('Patient', (a) {
            final p = data.patients[a.str('patient_id')];
            final second = wide
                ? (p == null ? '' : patientSummary(p))
                : [if (doctorId == null) data.doctorName(a), a.str('reason')].where((s) => s.isNotEmpty).join(' · ');
            return TwoLine(data.patientName(a), second);
          }, flex: 4),
          if (wide && doctorId == null)
            ListColumn('Doctor',
                (a) => TwoLine(data.doctorName(a), data.doctorById[a.str('doctor_id')]?.str('department')), flex: 3),
          if (wide)
            ListColumn('Reason', (a) => Text(a.str('reason', '—'), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 3),
          ListColumn('Status', (a) => _StatusCell(data: data, appointment: a), width: 150),
          ListColumn(
              '',
              (a) => ApptActionsBar(appointment: a, status: data.status(a), patientName: data.patientName(a)),
              width: 184),
        ],
      );
    });
  }
}

class _TimeCell extends StatelessWidget {
  const _TimeCell(this.a);
  final Rec a;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = a.str('kind', ApptKind.booked);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(formatTime(a.date('start_at')),
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
        if (kind != ApptKind.booked)
          Text(ApptKind.label(kind), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.data, required this.appointment});
  final DayData data;
  final Rec appointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = data.status(appointment);
    final enc = data.encounter(appointment);
    final caption = statusCaption(appointment, status, enc);
    final at = enc?.date('checked_in_at');
    final waitLong = status == ApptStatus.checkedIn && at != null && waitTone(DateTime.now().difference(at)) != Tone.neutral;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ApptStatusChip(status),
        if (caption != null) ...[
          Gap.v4,
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: waitLong || status == ApptStatus.booked
                  ? ToneColors.of(context, waitLong ? waitTone(DateTime.now().difference(at)) : Tone.warning).foreground
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: waitLong ? FontWeight.w600 : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _ApptCard extends StatelessWidget {
  const _ApptCard({required this.data, required this.appointment});
  final DayData data;
  final Rec appointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = appointment;
    final app = context.app;
    final status = data.status(a);
    final name = data.patientName(a);
    final kind = a.str('kind', ApptKind.booked);
    final actions = ApptActions.available(context, a, status);
    final primary = ApptActions.primary(actions, a);
    final second = [data.doctorName(a), a.str('reason')].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: app.nav.canOpen('patients.profile')
              ? () => app.nav.open('patients.profile', {'id': a.str('patient_id')})
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.xs, Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 68,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(formatTime(a.date('start_at')),
                              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                          if (kind != ApptKind.booked)
                            Text(ApptKind.label(kind),
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          if (a.intOrNull('token_no') != null) ...[
                            Gap.v4,
                            TokenBadge(a.integer('token_no'), size: 30, tone: ApptStatus.tone(status)),
                          ],
                        ],
                      ),
                    ),
                    Gap.h8,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (second.isNotEmpty)
                            Text(second,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                          Gap.v8,
                          _StatusCell(data: data, appointment: a),
                        ],
                      ),
                    ),
                    if (actions.where((x) => x != primary).isNotEmpty)
                      ApptMenu(
                          actions: actions.where((x) => x != primary).toList(), appointment: a, patientName: name),
                  ],
                ),
                if (primary != null) ...[
                  Gap.v8,
                  Padding(
                    padding: const EdgeInsets.only(left: 76, right: Gap.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: primary == ApptAction.checkIn
                        ? FilledButton.tonalIcon(
                            onPressed: () => ApptActions.run(context, primary, a, patientName: name),
                            icon: Icon(primary.icon, size: 18),
                            label: Text(primary.label),
                          )
                        : OutlinedButton(
                            onPressed: () => ApptActions.run(context, primary, a, patientName: name),
                            child: Text(primary.label),
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- slots

class _SlotsPanel extends StatelessWidget {
  const _SlotsPanel({required this.data, required this.doctorId});
  final DayData data;
  final String? doctorId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doctors = doctorId == null ? data.doctors : data.doctors.where((d) => d.id == doctorId).toList();
    final withSessions = doctors.where((d) => AppointmentService.slotsForDay(data.schedulesOf(d.id), data.day).isNotEmpty);
    final without = doctors.where((d) => AppointmentService.slotsForDay(data.schedulesOf(d.id), data.day).isEmpty).toList();
    final canSchedule = context.app.nav.canOpen('appointments.schedules');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in withSessions) ...[_DoctorSlots(data: data, doctor: d), Gap.v12],
        if (without.isNotEmpty)
          SectionCard(
            title: withSessions.isEmpty ? 'No OPD sessions' : 'Not in OPD on ${weekdayName(data.day.weekday)}',
            trailing: canSchedule
                ? TextButton(
                    onPressed: () => context.app.nav.open('appointments.schedules'), child: const Text('Schedules'))
                : null,
            child: Text(without.map((d) => d.str('display_name')).join(', '),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        if (withSessions.isNotEmpty) const _Legend(),
      ],
    );
  }
}

class _DoctorSlots extends StatelessWidget {
  const _DoctorSlots({required this.data, required this.doctor});
  final DayData data;
  final Rec doctor;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final schedules = data.schedulesOf(doctor.id);
    final slots = AppointmentService.slotsForDay(schedules, data.day);
    final appts = data.appointments
        .where((a) => a.str('doctor_id') == doctor.id && a.str('kind') != ApptKind.walkIn)
        .where((a) => data.status(a) != ApptStatus.cancelled)
        .toList();
    final free = AppointmentService.freeSlots(slots, appts, now: now).length;
    final over = slots.every((s) => !s.start.isAfter(now));
    final sessions = schedules
        .where((s) => s.integer('weekday') == data.day.weekday && s['active'] != false)
        .toList()
      ..sort((a, b) => a.integer('start_minute').compareTo(b.integer('start_minute')));
    final canBook = context.can(AppointmentPerms.manage);
    return SectionCard(
      title: doctor.str('display_name'),
      subtitle: [
        for (final s in sessions) AppointmentService.sessionLabel(s),
        if (sessions.isNotEmpty && sessions.first.str('room').isNotEmpty) sessions.first.str('room'),
      ].join(' · '),
      trailing: over
          ? const StatusChip('Session over')
          : StatusChip(free == 0 ? 'Fully booked' : '$free free', tone: free == 0 ? Tone.warning : Tone.success),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final s in slots)
            Builder(builder: (context) {
              final appt = appts.where((a) {
                final t = a.date('start_at')!;
                return !t.isBefore(s.start) && t.isBefore(s.end);
              }).firstOrNull;
              final past = !s.start.isAfter(now);
              return _SlotTile(
                slot: s,
                status: appt == null ? null : data.status(appt),
                patientName: appt == null ? null : data.patientName(appt),
                past: past,
                onTap: appt != null
                    ? () => _showAppointment(context, data, appt)
                    : (!past && canBook ? () => quickBookFlow(context, doctor: doctor, slot: s) : null),
              );
            }),
        ],
      ),
    );
  }
}

Future<void> _showAppointment(BuildContext context, DayData data, Rec a) async {
  final status = data.status(a);
  final name = data.patientName(a);
  final actions = ApptActions.available(context, a, status);
  final picked = await showDialog<ApptAction>(
    context: context,
    builder: (c) {
      final theme = Theme.of(c);
      return AlertDialog(
        title: Text(name),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${dayLabel(a.date('start_at')!)}, ${formatTime(a.date('start_at'))} · ${data.doctorName(a)}',
                  style: theme.textTheme.bodyLarge),
              if (a.str('reason').isNotEmpty) ...[Gap.v4, Text(a.str('reason'), style: theme.textTheme.bodyMedium)],
              Gap.v12,
              Row(children: [
                ApptStatusChip(status),
                if (a.intOrNull('token_no') != null) ...[Gap.h8, StatusChip('Token ${a.integer('token_no')}')],
              ]),
              if (actions.isNotEmpty) ...[
                Gap.v16,
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  for (final x in actions)
                    x == ApptAction.checkIn
                        ? FilledButton.icon(
                            onPressed: () => Navigator.pop(c, x), icon: Icon(x.icon, size: 18), label: Text(x.label))
                        : OutlinedButton.icon(
                            onPressed: () => Navigator.pop(c, x), icon: Icon(x.icon, size: 18), label: Text(x.label)),
                ]),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      );
    },
  );
  if (picked != null && context.mounted) await ApptActions.run(context, picked, a, patientName: name);
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.status, required this.patientName, required this.past, this.onTap});
  final Slot slot;
  final String? status;
  final String? patientName;
  final bool past;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Color bg, fg, border;
    if (status != null) {
      final c = ToneColors.of(context, ApptStatus.tone(status!));
      (bg, fg, border) = (c.background, c.foreground, c.border);
    } else if (past) {
      (bg, fg, border) = (Colors.transparent, cs.outline.withValues(alpha: 0.75), cs.outlineVariant.withValues(alpha: 0.6));
    } else {
      (bg, fg, border) = (cs.surface, cs.primary, cs.primary);
    }
    final tip = status != null
        ? '${formatTime(slot.start)} · $patientName · ${ApptStatus.label(status!)}'
        : (past ? '${formatTime(slot.start)} · past' : '${formatTime(slot.start)} · free, tap to book');
    return Tooltip(
      message: tip,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: BorderSide(color: border, width: status == null && !past ? 1.4 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 74,
            height: 46,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(formatTime(slot.start),
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    status != null ? firstName(patientName ?? '') : (past ? '—' : 'Free'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget item(Color bg, Color border, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(3)),
          ),
          Gap.h4,
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
        ]);
    ToneColors t(String s) => ToneColors.of(context, ApptStatus.tone(s));
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
        item(cs.surface, cs.primary, 'Free'),
        item(t(ApptStatus.booked).background, t(ApptStatus.booked).border, 'Booked'),
        item(t(ApptStatus.checkedIn).background, t(ApptStatus.checkedIn).border, 'Waiting'),
        item(t(ApptStatus.inConsultation).background, t(ApptStatus.inConsultation).border, 'With doctor'),
        item(t(ApptStatus.completed).background, t(ApptStatus.completed).border, 'Done'),
        item(t(ApptStatus.noShow).background, t(ApptStatus.noShow).border, 'No-show'),
        item(Colors.transparent, cs.outlineVariant, 'Past'),
      ]),
    );
  }
}

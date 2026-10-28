import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';
import 'board_screen.dart';
import 'common.dart';

/// One doctor's queue today.
class DoctorQueue {
  DoctorQueue(this.doctor, this.room, this.inSession);
  final Rec doctor;
  final String room;
  final bool inSession;
  final waiting = <Rec>[];
  final withDoctor = <Rec>[];
  int seen = 0;

  bool get active => inSession || waiting.isNotEmpty || withDoctor.isNotEmpty;
}

/// Today's OPD queue for every doctor, from the core `encounters` table, so
/// walk-ins registered by OPD itself show up too.
class QueueData {
  QueueData(this.queues, this.patients, this.appointmentsByVisit);
  final List<DoctorQueue> queues;
  final Map<String, Rec> patients;
  final Map<String, Rec> appointmentsByVisit;

  int get waiting => queues.fold(0, (n, q) => n + q.waiting.length);
  int get withDoctor => queues.fold(0, (n, q) => n + q.withDoctor.length);
  int get seen => queues.fold(0, (n, q) => n + q.seen);

  Duration longestWait(DateTime now) {
    var best = Duration.zero;
    for (final q in queues) {
      for (final e in q.waiting) {
        final at = e.date('checked_in_at');
        if (at != null && now.difference(at) > best) best = now.difference(at);
      }
    }
    return best;
  }

  static Future<QueueData> load(ReadDb db) async {
    final now = DateTime.now();
    final doctors = await AppointmentService.doctors(db);
    final schedules = await DayData.schedulesByDoctor(db);
    final visits = await AppointmentService.opdVisitsOn(db, now);
    final known = {for (final d in doctors) d.id};
    final extra = (await db.byIds(Col.users, visits.map((e) => e.strOrNull('doctor_id')).where((id) => !known.contains(id))))
        .values;
    final queues = {
      for (final d in [...doctors, ...extra])
        d.id: DoctorQueue(
          d,
          AppointmentService.roomAt(schedules[d.id] ?? const [], now),
          AppointmentService.slotsForDay(schedules[d.id] ?? const [], now).isNotEmpty,
        ),
    };
    for (final e in visits) {
      final q = queues[e.str('doctor_id')];
      if (q == null) continue;
      if (AppointmentService.isWaiting(e)) {
        q.waiting.add(e);
      } else if (AppointmentService.isWithDoctor(e)) {
        q.withDoctor.add(e);
      } else if (e.str('queue_status') == Vals.done || e.str('status') == Vals.closed) {
        q.seen++;
      }
    }
    for (final q in queues.values) {
      q.waiting.sort((a, b) {
        final t = a.integer('token_no').compareTo(b.integer('token_no'));
        return t != 0 ? t : a.date('checked_in_at')!.compareTo(b.date('checked_in_at')!);
      });
    }
    final ids = [for (final q in queues.values) ...q.waiting, for (final q in queues.values) ...q.withDoctor];
    final appts = ids.isEmpty
        ? const <Rec>[]
        : await db.query(Query(ApptCol.appointments).isIn('encounter_id', ids.map((e) => e.id)).take(1000));
    return QueueData(
      queues.values.where((q) => q.active).toList(),
      await db.byIds(Col.patients, ids.map((e) => e.str('patient_id'))),
      {for (final a in appts) a.str('encounter_id'): a},
    );
  }
}

Future<void> openTvBoard(BuildContext context) async {
  if (!context.app.nav.canOpen('appointments.board')) {
    context.app.nav.toast('The waiting-room display is not available');
    return;
  }
  await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const QueueBoardScreen(fullScreen: true),
  ));
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Wait times tick along.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<QueueData>(
      watch: const {Col.encounters, ApptCol.schedules, ApptCol.appointments},
      loading: const Scaffold(body: LoadingView()),
      load: QueueData.load,
      builder: (context, data) => _page(context, data),
    );
  }

  Widget _page(BuildContext context, QueueData data) {
    final now = DateTime.now();
    final canManage = context.can(AppointmentPerms.manage);
    final compact = context.isCompact;
    final longest = data.longestWait(now);
    final tv = compact
        ? IconButton(tooltip: 'Show on TV', icon: const Icon(Icons.tv_outlined), onPressed: () => openTvBoard(context))
        : OutlinedButton.icon(
            onPressed: () => openTvBoard(context),
            icon: const Icon(Icons.tv_outlined, size: 20),
            label: const Text('Show on TV'),
          );
    return PageScaffold(
      title: 'Waiting room',
      subtitle: [
        '${data.waiting} waiting',
        '${data.withDoctor} with doctor',
        '${data.seen} seen today',
        if (data.waiting > 0) 'longest wait ${formatDuration(longest)}',
      ].join(' · '),
      actions: [TourAnchor(id: 'appointments.tv', child: tv)],
      primaryAction: canManage ? PageAction('Walk-in', Icons.directions_walk, () => startWalkIn(context)) : null,
      body: data.queues.isEmpty
          ? Card(
              child: EmptyState(
                icon: Icons.weekend_outlined,
                title: 'Nobody is waiting',
                message: 'Patients appear here with their token as soon as they are checked in.',
                action: canManage
                    ? FilledButton.icon(
                        onPressed: () => startWalkIn(context),
                        icon: const Icon(Icons.directions_walk),
                        label: const Text('Walk-in'),
                      )
                    : null,
              ),
            )
          : ResponsiveGrid(
              minWidth: 340,
              maxColumns: 3,
              children: [for (final q in data.queues) _QueueCard(queue: q, data: data, now: now)],
            ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.queue, required this.data, required this.now});
  final DoctorQueue queue;
  final QueueData data;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final q = queue;
    return SectionCard(
      title: q.doctor.str('display_name'),
      subtitle: [q.doctor.str('department'), q.room, if (!q.inSession) 'no OPD today'].where((s) => s.isNotEmpty).join(' · '),
      trailing: StatusChip('${q.seen} seen', tone: Tone.success, icon: Icons.check_rounded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (q.withDoctor.isEmpty)
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(Radii.md)),
              child: Row(children: [
                Icon(Icons.meeting_room_outlined, color: cs.onSurfaceVariant),
                Gap.h12,
                Expanded(
                  child: Text(q.waiting.isEmpty ? 'Doctor is free' : 'Doctor is free · call the next patient',
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                ),
              ]),
            )
          else
            for (final e in q.withDoctor) _WithDoctor(visit: e, patient: data.patients[e.str('patient_id')], now: now),
          Gap.v12,
          SubHeading(q.waiting.isEmpty ? 'Waiting' : 'Waiting · ${q.waiting.length}'),
          if (q.waiting.isEmpty)
            Text('Nobody waiting', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
          else
            for (final (i, e) in q.waiting.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _WaitingRow(
                visit: e,
                patient: data.patients[e.str('patient_id')],
                appointment: data.appointmentsByVisit[e.id],
                now: now,
              ),
            ],
        ],
      ),
    );
  }
}

class _WithDoctor extends StatelessWidget {
  const _WithDoctor({required this.visit, required this.patient, required this.now});
  final Rec visit;
  final Rec? patient;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, Tone.info);
    final since = visit.date('called_at');
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.xs),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(children: [
        TokenBadge(visit.integer('token_no'), size: 44),
        Gap.h12,
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('WITH THE DOCTOR',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: c.foreground, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
            Text(patient?.str('full_name') ?? 'Patient',
                style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (since != null)
          Text(formatDuration(now.difference(since)),
              style: theme.textTheme.labelLarge?.copyWith(color: c.foreground)),
      ]),
    );
  }
}

class _WaitingRow extends StatelessWidget {
  const _WaitingRow({required this.visit, required this.patient, required this.appointment, required this.now});
  final Rec visit;
  final Rec? patient;
  final Rec? appointment;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.app;
    final at = visit.date('checked_in_at') ?? now;
    final wait = now.difference(at);
    final tone = waitTone(wait);
    final a = appointment;
    final how = a == null || a.str('kind') == ApptKind.walkIn
        ? 'Walk-in at ${formatTime(at)}'
        : '${ApptKind.label(a.str('kind'))} at ${formatTime(a.date('start_at'))}';
    return InkWell(
      onTap: patient != null && app.nav.canOpen('patients.profile')
          ? () => app.nav.open('patients.profile', {'id': patient!.id})
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(children: [
          TokenBadge(visit.integer('token_no'), size: 36, tone: Tone.warning),
          Gap.h12,
          Expanded(
            child: TwoLine(patient?.str('full_name') ?? 'Patient', how),
          ),
          Gap.h8,
          tone == Tone.neutral
              ? Text(formatDuration(wait),
                  style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))
              : StatusChip(formatDuration(wait), tone: tone, icon: Icons.schedule),
        ]),
      ),
    );
  }
}

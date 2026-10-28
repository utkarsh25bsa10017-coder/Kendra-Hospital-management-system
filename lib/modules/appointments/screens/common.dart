import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';

const reasonPresets = ['New problem', 'Follow-up', 'Show reports', 'Fever', 'Pain', 'Check-up'];
const cancelPresets = [
  'Patient asked to cancel',
  'Doctor not available',
  'Booked by mistake',
  'Patient will call to rebook',
];

String patientSummary(Rec p) => [
      p.str('uhid'),
      ageLabel(p.date('dob'), p.intOrNull('age_years')),
      genderLabel(p.strOrNull('gender')),
      p.str('phone'),
    ].where((s) => s.isNotEmpty && s != '—').join(' · ');

String firstName(String full) {
  final parts = full.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? full : parts.first;
}

IconData? statusIcon(String s) => switch (s) {
      ApptStatus.checkedIn => Icons.hourglass_top_rounded,
      ApptStatus.inConsultation => Icons.medical_services_outlined,
      ApptStatus.completed => Icons.check_rounded,
      ApptStatus.noShow => Icons.person_off_outlined,
      ApptStatus.cancelled => Icons.close_rounded,
      _ => Icons.event_outlined,
    };

class ApptStatusChip extends StatelessWidget {
  const ApptStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(ApptStatus.label(status), tone: ApptStatus.tone(status), icon: statusIcon(status));
}

/// A token number in a rounded square.
class TokenBadge extends StatelessWidget {
  const TokenBadge(this.token, {super.key, this.size = 36, this.tone = Tone.info});
  final int token;
  final double size;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        '$token',
        style: TextStyle(
          fontSize: size * (token > 99 ? 0.34 : 0.42),
          fontWeight: FontWeight.w700,
          color: c.foreground,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A selectable card (doctor choice etc.).
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.note,
    this.noteTone = Tone.info,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final String? note;
  final Tone noteTone;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: selected ? cs.primaryContainer : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 1.6 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.md),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: selected ? cs.primary : cs.outline, size: 22),
              Gap.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    if (note != null) ...[Gap.v4, StatusChip(note!, tone: noteTone)],
                  ],
                ),
              ),
              if (trailing != null) ...[Gap.h8, trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything the day view needs for one date.
class DayData {
  DayData({
    required this.day,
    required this.doctors,
    required this.schedules,
    required this.appointments,
    required this.patients,
    required this.encounters,
  }) : doctorById = {for (final d in doctors) d.id: d};

  final DateTime day;
  final List<Rec> doctors;
  final Map<String, Rec> doctorById;
  final Map<String, List<Rec>> schedules;
  final List<Rec> appointments;
  final Map<String, Rec> patients;
  final Map<String, Rec> encounters;

  String status(Rec a) => AppointmentService.effectiveStatus(a, encounters[a.str('encounter_id')]);
  Rec? encounter(Rec a) => encounters[a.str('encounter_id')];
  String patientName(Rec a) => patients[a.str('patient_id')]?.str('full_name') ?? 'Patient';
  String doctorName(Rec a) => doctorById[a.str('doctor_id')]?.str('display_name') ?? 'Doctor';
  List<Rec> schedulesOf(String doctorId) => schedules[doctorId] ?? const [];

  static Future<Map<String, List<Rec>>> schedulesByDoctor(ReadDb db) async {
    final out = <String, List<Rec>>{};
    for (final s in await AppointmentService.allSchedules(db)) {
      out.putIfAbsent(s.str('doctor_id'), () => []).add(s);
    }
    return out;
  }

  static Future<DayData> load(ReadDb db, DateTime day) async {
    final doctors = await AppointmentService.doctors(db);
    final schedules = await schedulesByDoctor(db);
    final appts = await AppointmentService.appointmentsOn(db, day);
    final known = {for (final d in doctors) d.id};
    final missing = appts.map((a) => a.str('doctor_id')).where((id) => !known.contains(id));
    final extra = (await db.byIds(Col.users, missing)).values;
    return DayData(
      day: dayOf(day),
      doctors: [...doctors, ...extra],
      schedules: schedules,
      appointments: appts,
      patients: await db.byIds(Col.patients, appts.map((a) => a.str('patient_id'))),
      encounters: await db.byIds(Col.encounters, appts.map((a) => a.strOrNull('encounter_id'))),
    );
  }
}

/// Patient picker with a way out to register someone new.
Future<Rec?> pickPatientOrRegister(BuildContext context, {String title = 'Choose patient'}) {
  final app = context.app;
  final canRegister = app.nav.canOpen('patients.register');
  return pickRecord(
    context,
    title: title,
    query: (s) => const Query(Col.patients).matching(s).sort('updated_at', desc: true).take(30),
    itemTitle: (p) => p.str('full_name'),
    itemSubtitle: patientSummary,
    emptyText: canRegister ? 'No patient matches. Register them as a new patient.' : 'No patient matches.',
    footer: canRegister
        ? Builder(
            builder: (c) => Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  app.nav.open('patients.register');
                },
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Register a new patient'),
              ),
            ),
          )
        : null,
  );
}

/// The context of the content area: stays mounted while dialogs come and go
/// (the command palette's own context is gone once it closes).
BuildContext stableContext(BuildContext context) => context.app.nav.contentKey.currentContext ?? context;

// ---------------------------------------------------------------- check in

Future<void> checkInFlow(BuildContext context, Rec appointment) async {
  final app = context.app;
  CheckInResult? res;
  final ok = await runGuarded(context, () async => res = await AppointmentService.checkIn(app.db, appointment));
  if (!ok || res == null || !context.mounted) return;
  await showTokenDialog(context, res!);
}

Future<void> showTokenDialog(BuildContext context, CheckInResult r) async {
  final db = context.app.readDb;
  final enc = r.encounter;
  final doctorId = enc.str('doctor_id');
  final patient = await db.get(Col.patients, enc.str('patient_id'));
  final doctor = await db.get(Col.users, doctorId);
  final now = DateTime.now();
  final room = AppointmentService.roomAt(await AppointmentService.schedulesFor(db, doctorId), now);
  final visits = await AppointmentService.opdVisitsOn(db, now);
  final ahead = visits
      .where((e) =>
          e.id != enc.id &&
          e.str('doctor_id') == doctorId &&
          AppointmentService.isWaiting(e) &&
          e.integer('token_no') < r.token)
      .length;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => _TokenDialog(
      token: r.token,
      patientName: patient?.str('full_name') ?? 'Patient',
      doctorLine: [doctor?.str('display_name') ?? 'Doctor', if (room.isNotEmpty) room].join(' · '),
      ahead: ahead,
    ),
  );
}

class _TokenDialog extends StatelessWidget {
  const _TokenDialog({required this.token, required this.patientName, required this.doctorLine, required this.ahead});
  final int token;
  final String patientName;
  final String doctorLine;
  final int ahead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ok = ToneColors.of(context, Tone.success);
    final canQueue = context.app.nav.canOpen('appointments.queue');
    return AlertDialog(
      icon: Icon(Icons.check_circle_rounded, color: ok.foreground, size: 40),
      title: Text('$patientName is checked in', textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('TOKEN',
                style: theme.textTheme.labelLarge
                    ?.copyWith(letterSpacing: 2, color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
            Text(
              '$token',
              style: TextStyle(
                fontSize: 96,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: cs.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(doctorLine, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            Gap.v8,
            Text(
              ahead == 0 ? 'Next in line' : '${plural(ahead, 'patient')} ahead',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        if (canQueue)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.app.nav.open('appointments.queue');
            },
            child: const Text('Open waiting room'),
          ),
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

// ---------------------------------------------------------------- walk-in

/// Walk-in: pick the patient, Kendra suggests the doctor with the shortest
/// queue, one tap gives a token.
Future<void> startWalkIn(BuildContext context, {Rec? patient}) async {
  final ctx = stableContext(context);
  final p = patient ?? await pickPatientOrRegister(ctx, title: 'Walk-in: who has come?');
  if (p == null || !ctx.mounted) return;
  final res = await showFormSheet<CheckInResult>(ctx, title: 'Walk-in', builder: (c) => WalkInForm(patient: p));
  if (res == null || !ctx.mounted) return;
  await showTokenDialog(ctx, res);
}

class WalkInForm extends StatefulWidget {
  const WalkInForm({super.key, required this.patient});
  final Rec patient;

  @override
  State<WalkInForm> createState() => _WalkInFormState();
}

class _WalkInFormState extends State<WalkInForm> {
  List<Rec>? _doctors;
  Map<String, int> _waiting = const {};
  Map<String, List<Rec>> _schedules = const {};
  String? _suggested;
  String? _doctorId;
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doctors == null) _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final now = DateTime.now();
    final doctors = await AppointmentService.doctors(db);
    final visits = await AppointmentService.opdVisitsOn(db, now);
    final schedules = await DayData.schedulesByDoctor(db);
    final suggested = AppointmentService.suggestDoctor(doctors, visits, schedules, now: now);
    if (!mounted) return;
    setState(() {
      _doctors = doctors;
      _waiting = AppointmentService.waitingCounts(visits);
      _schedules = schedules;
      _suggested = suggested;
      _doctorId = suggested;
    });
  }

  Future<void> _save() async {
    final doctorId = _doctorId;
    if (doctorId == null) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    CheckInResult? res;
    final ok = await runGuarded(context, () async {
      res = await AppointmentService.walkIn(context.db,
          patientId: widget.patient.id, doctorId: doctorId, reason: _reason.text);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(res);
  }

  @override
  Widget build(BuildContext context) {
    final doctors = _doctors;
    if (doctors == null) return const LoadingView();
    final theme = Theme.of(context);
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _PatientLine(patient: widget.patient),
        Gap.v16,
        const SubHeading('Doctor'),
        if (doctors.isEmpty)
          Text('No doctors yet. Add staff marked as clinicians in Administration.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        for (final d in doctors) ...[
          ChoiceTile(
            title: d.str('display_name'),
            subtitle: [
              d.str('department'),
              AppointmentService.roomAt(_schedules[d.id] ?? const [], now),
            ].where((s) => s.isNotEmpty).join(' · '),
            note: d.id == _suggested
                ? 'Shortest queue'
                : (AppointmentService.inSession(_schedules[d.id] ?? const [], now) ? null : 'Not in OPD now'),
            noteTone: d.id == _suggested ? Tone.success : Tone.neutral,
            trailing: _WaitingCount(_waiting[d.id] ?? 0),
            selected: d.id == _doctorId,
            onTap: () => setState(() => _doctorId = d.id),
          ),
          Gap.v8,
        ],
        Gap.v8,
        AppTextField(label: 'Reason for visit (optional)', controller: _reason, textCapitalization: TextCapitalization.sentences),
        Gap.v8,
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            for (final p in reasonPresets) ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
          ],
        ),
        Gap.v24,
        FilledButton.icon(
          onPressed: _saving || _doctorId == null ? null : _save,
          icon: const Icon(Icons.confirmation_number_outlined),
          label: const Text('Check in and give token'),
        ),
      ],
    );
  }
}

class _WaitingCount extends StatelessWidget {
  const _WaitingCount(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$n', style: theme.textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        Text('waiting', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _PatientLine extends StatelessWidget {
  const _PatientLine({required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        children: [
          Avatar(patient.str('full_name'), size: 40),
          Gap.h12,
          Expanded(child: TwoLine(patient.str('full_name'), patientSummary(patient))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- quick book from a slot

Future<void> quickBookFlow(BuildContext context, {required Rec doctor, required Slot slot}) async {
  final ctx = stableContext(context);
  final p = await pickPatientOrRegister(ctx,
      title: 'Book ${formatTime(slot.start)} with ${doctor.str('display_name')}');
  if (p == null || !ctx.mounted) return;
  await showFormSheet<bool>(ctx,
      title: 'Book appointment', width: 560, builder: (c) => QuickBookForm(patient: p, doctor: doctor, slot: slot));
}

class QuickBookForm extends StatefulWidget {
  const QuickBookForm({super.key, required this.patient, required this.doctor, required this.slot});
  final Rec patient;
  final Rec doctor;
  final Slot slot;

  @override
  State<QuickBookForm> createState() => _QuickBookFormState();
}

class _QuickBookFormState extends State<QuickBookForm> {
  final _reason = TextEditingController();
  late String _via = sameDay(widget.slot.start, DateTime.now()) ? BookedVia.frontDesk : BookedVia.phone;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final s = widget.slot;
    final ok = await runGuarded(
      context,
      () => AppointmentService.book(context.db,
          patientId: widget.patient.id,
          doctorId: widget.doctor.id,
          start: s.start,
          end: s.end,
          bookedVia: _via,
          reason: _reason.text),
      success: 'Booked ${widget.patient.str('full_name')} · ${dayLabel(s.start)}, ${formatTime(s.start)}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.slot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _WhenLine(
          when: '${dayLabel(s.start)}, ${formatDate(s.start)} · ${formatTime(s.start)}',
          who: [widget.doctor.str('display_name'), if (s.room.isNotEmpty) s.room].join(' · '),
        ),
        Gap.v12,
        _PatientLine(patient: widget.patient),
        Gap.v16,
        AppTextField(label: 'Reason for visit (optional)', controller: _reason, textCapitalization: TextCapitalization.sentences),
        Gap.v8,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final p in reasonPresets) ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
        ]),
        Gap.v16,
        const SubHeading('Booked by'),
        BookedViaPicker(value: _via, onChanged: (v) => setState(() => _via = v)),
        Gap.v24,
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check),
          label: const Text('Book appointment'),
        ),
      ],
    );
  }
}

class BookedViaPicker extends StatelessWidget {
  const BookedViaPicker({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          for (final (v, label) in BookedVia.options)
            ChoiceChip(
              label: Text(label),
              avatar: Icon(
                switch (v) {
                  BookedVia.phone => Icons.call_outlined,
                  BookedVia.followUp => Icons.replay_outlined,
                  _ => Icons.storefront_outlined,
                },
                size: 18,
              ),
              selected: value == v,
              showCheckmark: false,
              onSelected: (_) => onChanged(v),
            ),
        ],
      );
}

class _WhenLine extends StatelessWidget {
  const _WhenLine({required this.when, required this.who});
  final String when;
  final String who;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, Tone.info);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(children: [
        Icon(Icons.event_available_outlined, color: c.foreground),
        Gap.h12,
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(when, style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
            Text(who, style: theme.textTheme.bodySmall?.copyWith(color: c.foreground)),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- free slot picker

/// Date chips for the coming week plus the free slots on the chosen day.
class SlotPicker extends StatelessWidget {
  const SlotPicker({
    super.key,
    required this.doctorId,
    required this.date,
    required this.selected,
    required this.onChanged,
    this.ignoreAppointmentId,
  });
  final String doctorId;
  final DateTime date;
  final Slot? selected;
  final void Function(DateTime date, Slot? slot) onChanged;
  final String? ignoreAppointmentId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(List<Rec>, List<Slot>, Slot?)>(
      watch: const {ApptCol.appointments, ApptCol.schedules},
      deps: [doctorId, dayKey(date), ignoreAppointmentId],
      load: (db) async {
        final schedules = await AppointmentService.schedulesFor(db, doctorId);
        final free =
            await AppointmentService.freeSlotsOn(db, doctorId, date, ignoreId: ignoreAppointmentId);
        final next = free.isEmpty
            ? await AppointmentService.nextFreeSlot(db, doctorId,
                from: date.isAfter(DateTime.now()) ? date : DateTime.now(), ignoreId: ignoreAppointmentId)
            : null;
        return (schedules, free, next);
      },
      builder: (context, data) {
        final (schedules, free, next) = data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DateChips(
              selected: date,
              hasSession: (d) => AppointmentService.slotsForDay(schedules, d).isNotEmpty,
              onChanged: (d) => onChanged(d, null),
            ),
            Gap.v16,
            if (schedules.isEmpty)
              const _Hint(icon: Icons.event_busy_outlined, text: 'This doctor has no OPD sessions set up yet. Add them in Doctor schedules.')
            else if (free.isEmpty) ...[
              _Hint(
                icon: Icons.event_busy_outlined,
                text: AppointmentService.slotsForDay(schedules, date).isEmpty
                    ? 'No OPD on ${weekdayName(date.weekday)}s.'
                    : (sameDay(date, DateTime.now())
                        ? 'No free times left today.'
                        : 'No free times left on ${formatDate(date)}.'),
              ),
              if (next != null) ...[
                Gap.v8,
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => onChanged(dayOf(next.start), next),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Next free: ${dayLabel(next.start)}, ${formatTime(next.start)}'),
                  ),
                ),
              ],
            ] else
              _FreeSlots(free: free, schedules: schedules, selected: selected, onSelected: (s) => onChanged(date, s)),
          ],
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      Gap.h8,
      Expanded(child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
    ]);
  }
}

class _DateChips extends StatelessWidget {
  const _DateChips({required this.selected, required this.hasSession, required this.onChanged});
  final DateTime selected;
  final bool Function(DateTime) hasSession;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = [for (var i = 0; i < 7; i++) DateTime(now.year, now.month, now.day + i)];
    final custom = !days.any((d) => sameDay(d, selected));
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        for (final d in days)
          ChoiceChip(
            label: Text(dayLabel(d, now: now)),
            selected: sameDay(d, selected),
            showCheckmark: false,
            onSelected: hasSession(d) ? (_) => onChanged(d) : null,
            tooltip: hasSession(d) ? formatDate(d) : 'No OPD on ${weekdayName(d.weekday)}',
          ),
        if (custom)
          ChoiceChip(
            avatar: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(formatDate(selected)),
            selected: true,
            showCheckmark: false,
            onSelected: (_) => _pick(context),
          )
        else
          ActionChip(
            avatar: const Icon(Icons.calendar_today_outlined, size: 16),
            label: const Text('Other date'),
            onPressed: () => _pick(context),
          ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: selected.isBefore(dayOf(now)) ? now : selected,
      firstDate: dayOf(now),
      lastDate: DateTime(now.year + 1, now.month, now.day),
    );
    if (d != null) onChanged(d);
  }
}

class _FreeSlots extends StatelessWidget {
  const _FreeSlots({required this.free, required this.schedules, required this.selected, required this.onSelected});
  final List<Slot> free;
  final List<Rec> schedules;
  final Slot? selected;
  final ValueChanged<Slot> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = <String?, List<Slot>>{};
    for (final s in free) {
      groups.putIfAbsent(s.scheduleId, () => []).add(s);
    }
    final byId = {for (final s in schedules) s.id: s};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, e) in groups.entries.indexed) ...[
          if (i > 0) Gap.v12,
          Text(
            _groupLabel(byId[e.key], e.value),
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Gap.v8,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final s in e.value)
                ChoiceChip(
                  label: Text(formatTime(s.start)),
                  selected: s == selected,
                  showCheckmark: false,
                  onSelected: (_) => onSelected(s),
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _groupLabel(Rec? schedule, List<Slot> slots) {
    final first = slots.first.start;
    final part = first.hour < 12 ? 'Morning' : (first.hour < 16 ? 'Afternoon' : 'Evening');
    return [
      part,
      if (schedule != null) AppointmentService.sessionLabel(schedule),
      if (slots.first.room.isNotEmpty) slots.first.room,
      plural(slots.length, 'free slot'),
    ].join(' · ');
  }
}

// ---------------------------------------------------------------- reschedule / cancel / no-show

Future<void> rescheduleFlow(BuildContext context, Rec appointment, {required String patientName}) async {
  await showFormSheet<bool>(context,
      title: 'Reschedule $patientName', builder: (c) => RescheduleForm(appointment: appointment));
}

class RescheduleForm extends StatefulWidget {
  const RescheduleForm({super.key, required this.appointment});
  final Rec appointment;

  @override
  State<RescheduleForm> createState() => _RescheduleFormState();
}

class _RescheduleFormState extends State<RescheduleForm> {
  List<Rec>? _doctors;
  late String _doctorId = widget.appointment.str('doctor_id');
  late DateTime _date = () {
    final d = dayOf(widget.appointment.date('start_at')!);
    final today = dayOf(DateTime.now());
    return d.isBefore(today) ? today : d;
  }();
  Slot? _slot;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doctors == null) {
      AppointmentService.doctors(context.app.readDb).then((d) {
        if (mounted) setState(() => _doctors = d);
      });
    }
  }

  Future<void> _save() async {
    final slot = _slot;
    if (slot == null) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final ok = await runGuarded(
      context,
      () => AppointmentService.reschedule(context.db, widget.appointment, slot, doctorId: _doctorId),
      success: 'Moved to ${dayLabel(slot.start)}, ${formatTime(slot.start)}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final doctors = _doctors;
    if (doctors == null) return const LoadingView();
    final start = widget.appointment.date('start_at')!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Now: ${dayLabel(start)}, ${formatDate(start)} at ${formatTime(start)}',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Gap.v16,
        AppDropdown<String>(
          label: 'Doctor',
          value: _doctorId,
          items: [for (final d in doctors) (d.id, '${d.str('display_name')} · ${d.str('department')}')],
          onChanged: (v) => setState(() {
            if (v != null) _doctorId = v;
            _slot = null;
          }),
        ),
        Gap.v16,
        SlotPicker(
          doctorId: _doctorId,
          date: _date,
          selected: _slot,
          ignoreAppointmentId: widget.appointment.id,
          onChanged: (d, s) => setState(() {
            _date = dayOf(d);
            _slot = s;
          }),
        ),
        Gap.v24,
        FilledButton.icon(
          onPressed: _saving || _slot == null ? null : _save,
          icon: const Icon(Icons.event_repeat),
          label: Text(_slot == null ? 'Pick a new time' : 'Move to ${dayLabel(_slot!.start)}, ${formatTime(_slot!.start)}'),
        ),
      ],
    );
  }
}

Future<void> cancelFlow(BuildContext context, Rec a, {required String patientName}) async {
  final start = a.date('start_at')!;
  final reason = await reasonDialog(
    context,
    title: 'Cancel this appointment?',
    message: '$patientName · ${dayLabel(start)}, ${formatTime(start)}. The slot becomes free for others.',
    label: 'Why is it cancelled?',
    confirmLabel: 'Yes, cancel it',
    presets: cancelPresets,
    destructive: true,
  );
  if (reason == null || !context.mounted) return;
  await runGuarded(context, () => AppointmentService.cancel(context.db, a, reason), success: 'Appointment cancelled');
}

Future<void> noShowFlow(BuildContext context, Rec a, {required String patientName}) async {
  final start = a.date('start_at')!;
  final ok = await confirmDialog(
    context,
    title: 'Mark as no-show?',
    message: '$patientName did not come for ${sameDay(start, DateTime.now()) ? 'today' : formatDate(start)} '
        'at ${formatTime(start)}.',
    confirmLabel: 'Mark no-show',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  await runGuarded(context, () => AppointmentService.markNoShow(context.db, a), success: 'Marked as no-show');
}

// ---------------------------------------------------------------- actions on one appointment

enum ApptAction {
  checkIn('Check in', Icons.how_to_reg_outlined),
  noShow('Mark no-show', Icons.person_off_outlined),
  reschedule('Reschedule', Icons.event_repeat),
  cancel('Cancel', Icons.event_busy_outlined),
  consult('Open consultation', Icons.medical_services_outlined),
  bookAgain('Book again', Icons.edit_calendar_outlined),
  patient('Open patient', Icons.person_outline);

  const ApptAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

abstract final class ApptActions {
  static List<ApptAction> available(BuildContext context, Rec a, String status) {
    final canManage = context.can(AppointmentPerms.manage);
    final nav = context.app.nav;
    final now = DateTime.now();
    final start = a.date('start_at')!;
    final booked = status == ApptStatus.booked;
    final isToday = sameDay(start, now);
    final pastDay = dayOf(start).isBefore(dayOf(now));
    return [
      if (canManage && booked && isToday) ApptAction.checkIn,
      if (canManage && booked && start.isBefore(now)) ApptAction.noShow,
      if (canManage && booked) ApptAction.reschedule,
      if (canManage && booked && !pastDay) ApptAction.cancel,
      if (a.strOrNull('encounter_id') != null && status != ApptStatus.cancelled && nav.canOpen('opd.consult'))
        ApptAction.consult,
      if (canManage && (status == ApptStatus.cancelled || status == ApptStatus.noShow)) ApptAction.bookAgain,
      if (nav.canOpen('patients.profile')) ApptAction.patient,
    ];
  }

  /// The one action that deserves a button of its own.
  static ApptAction? primary(List<ApptAction> actions, Rec a) {
    if (actions.contains(ApptAction.checkIn)) return ApptAction.checkIn;
    final pastDay = dayOf(a.date('start_at')!).isBefore(dayOf(DateTime.now()));
    if (pastDay && actions.contains(ApptAction.noShow)) return ApptAction.noShow;
    if (!pastDay && actions.contains(ApptAction.reschedule)) return ApptAction.reschedule;
    return null;
  }

  static Future<void> run(BuildContext context, ApptAction action, Rec a, {required String patientName}) async {
    final nav = context.app.nav;
    switch (action) {
      case ApptAction.checkIn:
        await checkInFlow(context, a);
      case ApptAction.noShow:
        await noShowFlow(context, a, patientName: patientName);
      case ApptAction.reschedule:
        await rescheduleFlow(context, a, patientName: patientName);
      case ApptAction.cancel:
        await cancelFlow(context, a, patientName: patientName);
      case ApptAction.consult:
        await nav.open('opd.consult', {'encounterId': a.str('encounter_id')});
      case ApptAction.bookAgain:
        await nav.open('appointments.book', {'patientId': a.str('patient_id'), 'doctorId': a.str('doctor_id')});
      case ApptAction.patient:
        await nav.open('patients.profile', {'id': a.str('patient_id')});
    }
  }
}

/// Main button (if any) plus a "more" menu for one appointment.
class ApptActionsBar extends StatelessWidget {
  const ApptActionsBar({
    super.key,
    required this.appointment,
    required this.status,
    required this.patientName,
    this.expandPrimary = false,
    this.showPrimary = true,
  });
  final Rec appointment;
  final String status;
  final String patientName;
  final bool expandPrimary;
  final bool showPrimary;

  @override
  Widget build(BuildContext context) {
    final actions = ApptActions.available(context, appointment, status);
    final primary = showPrimary ? ApptActions.primary(actions, appointment) : null;
    final rest = actions.where((a) => a != primary).toList();
    Widget? button;
    if (primary != null) {
      void onPressed() => ApptActions.run(context, primary, appointment, patientName: patientName);
      button = primary == ApptAction.checkIn
          ? FilledButton.tonalIcon(onPressed: onPressed, icon: Icon(primary.icon, size: 18), label: Text(primary.label))
          : OutlinedButton(onPressed: onPressed, child: Text(primary.label));
    }
    return Row(
      mainAxisSize: expandPrimary ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (button != null) expandPrimary ? Expanded(child: button) : button,
        if (rest.isNotEmpty) ApptMenu(actions: rest, appointment: appointment, patientName: patientName),
      ],
    );
  }
}

class ApptMenu extends StatelessWidget {
  const ApptMenu({super.key, required this.actions, required this.appointment, required this.patientName});
  final List<ApptAction> actions;
  final Rec appointment;
  final String patientName;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ApptAction>(
        tooltip: 'More actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (a) => ApptActions.run(context, a, appointment, patientName: patientName),
        itemBuilder: (c) => [
          for (final a in actions)
            PopupMenuItem(
              value: a,
              child: Row(children: [Icon(a.icon, size: 20), Gap.h12, Text(a.label)]),
            ),
        ],
      );
}

/// One-line extra information under the status, e.g. "Waiting 23 min".
String? statusCaption(Rec a, String status, Rec? encounter, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final start = a.date('start_at')!;
  switch (status) {
    case ApptStatus.checkedIn:
      final at = encounter?.date('checked_in_at');
      return at == null ? null : 'Waiting ${formatDuration(n.difference(at))}';
    case ApptStatus.inConsultation:
      final at = encounter?.date('called_at');
      return at == null ? null : 'Since ${formatTime(at)}';
    case ApptStatus.completed:
      final at = encounter?.date('ended_at');
      return at == null ? null : 'Seen by ${formatTime(at)}';
    case ApptStatus.cancelled:
      return a.strOrNull('cancel_reason');
    case ApptStatus.booked:
      if (sameDay(start, n) && n.difference(start) > const Duration(minutes: 10)) {
        return 'Late ${formatDuration(n.difference(start))}';
      }
      return null;
  }
  return null;
}

/// Wait time colouring used across the waiting room screens.
Tone waitTone(Duration wait) => wait.inMinutes > 90
    ? Tone.danger
    : wait.inMinutes > 45
        ? Tone.warning
        : Tone.neutral;

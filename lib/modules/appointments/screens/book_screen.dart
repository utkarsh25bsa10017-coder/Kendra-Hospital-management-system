import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../appointment_service.dart';
import 'common.dart';

/// Book an appointment: patient, doctor, the earliest free slot already
/// picked, reason. Everything that can be guessed is filled in.
class BookScreen extends StatefulWidget {
  const BookScreen({super.key, this.patientId, this.doctorId, this.date});
  final String? patientId;
  final String? doctorId;
  final DateTime? date;

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  bool _loading = true;
  bool _saving = false;
  Rec? _patient;
  List<Rec> _doctors = const [];
  Map<String, Slot?> _nextFree = const {};
  String? _doctorId;
  late DateTime _date = _startDate();
  Slot? _slot;
  String _via = BookedVia.phone;
  final _reason = TextEditingController();
  final _notes = TextEditingController();

  DateTime _startDate() {
    final today = dayOf(DateTime.now());
    final d = widget.date == null ? today : dayOf(widget.date!);
    return d.isBefore(today) ? today : d;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final patient = await db.get(Col.patients, widget.patientId);
    final doctors = await AppointmentService.doctors(db);
    final next = <String, Slot?>{for (final d in doctors) d.id: await AppointmentService.nextFreeSlot(db, d.id)};
    var doctorId = widget.doctorId;
    if (doctorId == null && patient != null) {
      // Most patients go back to the doctor they saw last.
      final last = await db.first(Query(ApptCol.appointments).eq('patient_id', patient.id).sort('start_at', desc: true));
      final lastDoctor = last?.str('doctor_id');
      if (doctors.any((d) => d.id == lastDoctor)) doctorId = lastDoctor;
    }
    if (doctorId == null && doctors.length == 1) doctorId = doctors.first.id;
    if (!mounted) return;
    setState(() {
      _patient = patient;
      _doctors = doctors;
      _nextFree = next;
      _doctorId = doctorId;
      _loading = false;
    });
    if (doctorId != null) await _suggest();
  }

  /// Pre-selects the earliest free slot from the chosen date onwards.
  Future<void> _suggest() async {
    final id = _doctorId;
    if (id == null) return;
    final now = DateTime.now();
    final from = _date.isAfter(now) ? _date : now;
    final slot = await AppointmentService.nextFreeSlot(context.app.readDb, id, from: from);
    if (!mounted || id != _doctorId) return;
    setState(() {
      _slot = slot;
      if (slot != null) _date = dayOf(slot.start);
    });
  }

  Future<void> _choosePatient() async {
    final p = await pickPatientOrRegister(context);
    if (p != null && mounted) setState(() => _patient = p);
  }

  void _chooseDoctor(String id) {
    if (id == _doctorId) return;
    setState(() {
      _doctorId = id;
      _slot = null;
    });
    _suggest();
  }

  Rec? get _doctor => _doctors.where((d) => d.id == _doctorId).firstOrNull;
  bool get _ready => _patient != null && _doctorId != null && _slot != null && !_saving;

  Future<void> _save() async {
    final patient = _patient, doctor = _doctor, slot = _slot;
    if (patient == null || doctor == null || slot == null) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final ok = await runGuarded(
      context,
      () => AppointmentService.book(context.db,
          patientId: patient.id,
          doctorId: doctor.id,
          start: slot.start,
          end: slot.end,
          bookedVia: _via,
          reason: _reason.text,
          notes: _notes.text),
      success: 'Booked ${patient.str('full_name')} with ${doctor.str('display_name')} · '
          '${dayLabel(slot.start)}, ${formatTime(slot.start)}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.maybePop();
  }

  String _summary() {
    final p = _patient, d = _doctor, s = _slot;
    if (p == null) return 'Choose the patient first.';
    if (d == null) return 'Choose a doctor for ${p.str('full_name')}.';
    if (s == null) return 'Pick a time with ${d.str('display_name')}.';
    return '${p.str('full_name')} with ${d.str('display_name')} on ${dayLabel(s.start)}, '
        '${formatDate(s.start)} at ${formatTime(s.start)}${s.room.isEmpty ? '' : ' · ${s.room}'}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    final theme = Theme.of(context);
    final patient = _patient;
    final canRegister = context.app.nav.canOpen('patients.register');
    return PageScaffold(
      title: 'Book appointment',
      subtitle: patient == null ? 'Patient, doctor and time. The earliest free time is picked for you.' : 'For ${patient.str('full_name')}',
      maxWidth: 980,
      primaryAction: PageAction('Book', Icons.check, _ready ? _save : null),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: 'Patient',
            child: patient == null
                ? Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                    FilledButton.icon(
                        onPressed: _choosePatient, icon: const Icon(Icons.person_search_outlined), label: const Text('Choose patient')),
                    if (canRegister)
                      OutlinedButton.icon(
                        onPressed: () => context.app.nav.open('patients.register'),
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Register new patient'),
                      ),
                  ])
                : Row(children: [
                    Avatar(patient.str('full_name'), size: 40),
                    Gap.h12,
                    Expanded(child: TwoLine(patient.str('full_name'), patientSummary(patient))),
                    TextButton(onPressed: _choosePatient, child: const Text('Change')),
                  ]),
          ),
          Gap.v16,
          SectionCard(
            title: 'Doctor',
            child: _doctors.isEmpty
                ? Text('No doctors yet. Add staff marked as clinicians in Administration.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                : ResponsiveGrid(
                    minWidth: 260,
                    maxColumns: 3,
                    spacing: Gap.sm,
                    children: [
                      for (final d in _doctors)
                        ChoiceTile(
                          title: d.str('display_name'),
                          subtitle: [
                            d.str('department'),
                            if (d.intOrNull('consultation_fee_paise') != null)
                              formatMoney(d.integer('consultation_fee_paise'), alwaysDecimals: false),
                          ].where((s) => s.isNotEmpty).join(' · '),
                          note: switch (_nextFree[d.id]) {
                            null => 'No free time soon',
                            final Slot s => 'Next free · ${dayLabel(s.start)}, ${formatTime(s.start)}',
                          },
                          noteTone: _nextFree[d.id] == null ? Tone.neutral : Tone.success,
                          selected: d.id == _doctorId,
                          onTap: () => _chooseDoctor(d.id),
                        ),
                    ],
                  ),
          ),
          Gap.v16,
          SectionCard(
            title: 'Date and time',
            child: _doctorId == null
                ? Text('Choose a doctor to see free times.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                : SlotPicker(
                    doctorId: _doctorId!,
                    date: _date,
                    selected: _slot,
                    onChanged: (d, s) => setState(() {
                      _date = dayOf(d);
                      _slot = s;
                    }),
                  ),
          ),
          Gap.v16,
          SectionCard(
            title: 'Details',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  label: 'Reason for visit',
                  hint: 'e.g. Fever for three days',
                  controller: _reason,
                  textCapitalization: TextCapitalization.sentences,
                ),
                Gap.v8,
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  for (final p in reasonPresets)
                    ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
                ]),
                Gap.v16,
                const SubHeading('Booked by'),
                BookedViaPicker(value: _via, onChanged: (v) => setState(() => _via = v)),
                Gap.v16,
                AppTextField(label: 'Note for the front desk (optional)', controller: _notes, maxLines: 2),
              ],
            ),
          ),
          Gap.v24,
          if (context.isCompact)
            Text(_summary(), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          else
            Row(children: [
              Expanded(
                child: Text(_summary(),
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: _ready ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant)),
              ),
              Gap.h16,
              FilledButton.icon(
                onPressed: _ready ? _save : null,
                icon: const Icon(Icons.check),
                label: const Text('Book appointment'),
              ),
            ]),
        ],
      ),
    );
  }
}

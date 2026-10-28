import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../ipd_schema.dart';
import '../ipd_service.dart';
import '../widgets/ipd_widgets.dart';

/// Admit a patient into a free bed. Opened from the bed board (with a bed),
/// the patient profile (with a patient) or the command palette.
class AdmitScreen extends StatefulWidget {
  const AdmitScreen({super.key, this.patientId, this.bedId});
  final String? patientId;
  final String? bedId;

  @override
  State<AdmitScreen> createState() => _AdmitScreenState();
}

class _AdmitScreenState extends State<AdmitScreen> {
  final _form = GlobalKey<FormState>();
  final _diagnosis = TextEditingController();
  final _reason = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  Rec? _patient;
  Rec? _current; // the patient's open admission, if any
  Rec? _bed;
  String? _doctorId;
  int? _stay = 3;
  List<Rec> _doctors = const [];

  static const _stays = [1, 2, 3, 5, 7, 10];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  @override
  void dispose() {
    _diagnosis.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = context.app;
    final db = app.readDb;
    _doctors = await db.query(const Query(Col.users).eq('is_clinician', true).eq('active', true).sort('display_name').take(200));
    final me = app.auth.session;
    if (me != null && _doctors.any((d) => d.id == me.userId)) _doctorId = me.userId;
    if (widget.bedId != null) {
      final b = await db.get(IpdCol.beds, widget.bedId);
      if (b != null && IpdService.isFree(b)) _bed = b;
    }
    if (widget.patientId != null) await _setPatient(await db.get(Col.patients, widget.patientId));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setPatient(Rec? p) async {
    final current = p == null ? null : await IpdService.currentAdmission(context.app.readDb, p.id);
    if (!mounted) return;
    setState(() {
      _patient = p;
      _current = current;
    });
  }

  Future<void> _choosePatient() async {
    final p = await pickPatient(context, title: 'Who is being admitted?');
    if (p != null) await _setPatient(p);
  }

  Future<void> _save() async {
    final app = context.app;
    if (_patient == null) {
      app.nav.toast('Choose the patient first', error: true);
      return;
    }
    if (_bed == null) {
      app.nav.toast('Choose a free bed', error: true);
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    Rec? adm;
    final ok = await runGuarded(context, () async {
      adm = await IpdService.admit(
        app.db,
        patientId: _patient!.id,
        bedId: _bed!.id,
        attendingDoctorId: _doctorId!,
        admittingDoctorId: (app.auth.session?.isClinician ?? false) ? app.auth.session!.userId : _doctorId,
        diagnosis: _diagnosis.text,
        reason: _reason.text,
        expectedStayDays: _stay,
      );
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok || adm == null) return;
    app.nav.toast('${_patient!.str('full_name')} admitted to ${_bed!.str('label')} · ${adm!.str('number')}');
    Navigator.of(context).pop();
    app.nav.open('ipd.admission', {'id': adm!.id});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    final theme = Theme.of(context);
    final blocked = _current != null;
    return PageScaffold(
      title: 'Admit patient',
      subtitle: 'Creates the inpatient visit, marks the bed occupied and starts daily bed charges',
      maxWidth: 980,
      primaryAction: PageAction('Admit', Icons.check, _saving || blocked ? null : _save),
      body: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Patient',
              trailing: _patient == null ? null : TextButton(onPressed: _choosePatient, child: const Text('Change')),
              child: _patient == null
                  ? Wrap(
                      spacing: Gap.sm,
                      runSpacing: Gap.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                            onPressed: _choosePatient, icon: const Icon(Icons.person_search_outlined), label: const Text('Find patient')),
                        if (context.can('patients.edit'))
                          OutlinedButton.icon(
                            onPressed: () => context.app.nav.open('patients.register'),
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('Register new patient'),
                          ),
                        Text('New patients: register first, then tap Admit on their profile.',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    )
                  : _PatientSummary(patient: _patient!, current: _current),
            ),
            Gap.v16,
            SectionCard(
              title: 'Bed',
              trailing: _bed == null ? null : StatusChip('Bed ${_bed!.str('label')}', icon: Icons.king_bed_outlined, tone: Tone.success),
              child: FreeBedPicker(selected: _bed, onChanged: (b) => setState(() => _bed = b)),
            ),
            Gap.v16,
            SectionCard(
              title: 'Clinical',
              child: FormGrid(maxColumns: 2, children: [
                AppDropdown<String>(
                  label: 'Attending doctor',
                  value: _doctorId,
                  items: [
                    for (final d in _doctors)
                      (d.id, [d.str('display_name'), if (d.str('department').isNotEmpty) d.str('department')].join(' · ')),
                  ],
                  validator: (v) => v == null ? 'Choose the attending doctor' : null,
                  onChanged: (v) => setState(() => _doctorId = v),
                ),
                AppTextField(
                  label: 'Provisional diagnosis',
                  controller: _diagnosis,
                  textCapitalization: TextCapitalization.sentences,
                  validator: Validators.required('Diagnosis'),
                ),
                FullWidth(
                  child: AppTextField(
                    label: 'Reason for admission',
                    controller: _reason,
                    hint: 'e.g. Platelets 48,000, vomiting, unable to take orally',
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
                FullWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SubHeading('Expected stay'),
                      Wrap(
                        spacing: Gap.sm,
                        runSpacing: Gap.sm,
                        children: [
                          for (final d in _stays)
                            ChoiceChip(
                              showCheckmark: false,
                              selected: _stay == d,
                              label: Text(plural(d, 'day')),
                              onSelected: (_) => setState(() => _stay = d),
                            ),
                          ChoiceChip(
                            showCheckmark: false,
                            selected: _stay == null,
                            label: const Text('Not sure'),
                            onSelected: (_) => setState(() => _stay = null),
                          ),
                        ],
                      ),
                      if (_stay != null) ...[
                        Gap.v8,
                        Text('Expected discharge ${formatDate(DateTime.now().add(Duration(days: _stay!)))}',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
              ]),
            ),
            Gap.v24,
            if (!context.isCompact)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving || blocked ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(_bed == null ? 'Admit' : 'Admit to ${_bed!.str('label')}'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PatientSummary extends StatelessWidget {
  const _PatientSummary({required this.patient, this.current});
  final Rec patient;
  final Rec? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = patient;
    final allergies = p.str('allergies');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Avatar(p.str('full_name'), size: 44),
          Gap.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.str('full_name'), style: theme.textTheme.titleMedium),
                Text(
                  [p.str('uhid'), ageLabel(p.date('dob'), p.intOrNull('age_years')), genderLabel(p.strOrNull('gender')), p.str('phone')]
                      .where((s) => s.isNotEmpty && s != '—')
                      .join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ]),
        Gap.v12,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          if (allergies.isNotEmpty)
            StatusChip('Allergies: $allergies', icon: Icons.warning_amber_rounded, tone: Tone.danger)
          else
            const StatusChip('No known allergies', tone: Tone.success),
          if (p.strOrNull('blood_group') != null) StatusChip('Blood ${p.str('blood_group')}', icon: Icons.bloodtype_outlined),
          switch (p.str('payer_type', 'self')) {
            'insurance' => StatusChip('Insurance · ${p.str('insurer')}', tone: Tone.info),
            'corporate' => StatusChip('Corporate · ${p.str('insurer')}', tone: Tone.board),
            _ => const StatusChip('Self pay'),
          },
        ]),
        if (current != null) ...[
          Gap.v12,
          ToneBanner(
            tone: Tone.warning,
            icon: Icons.info_outline,
            title: 'Already admitted (${current!.str('number')})',
            message: 'Discharge the current stay first, or transfer the patient to another bed from the admission.',
            action: TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                context.app.nav.open('ipd.admission', {'id': current!.id});
              },
              child: const Text('Open'),
            ),
          ),
        ],
      ],
    );
  }
}

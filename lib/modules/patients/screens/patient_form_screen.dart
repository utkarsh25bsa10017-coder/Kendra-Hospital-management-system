import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../patient_service.dart';

/// Register a new patient, or edit one when [patientId] is given.
class PatientFormScreen extends StatefulWidget {
  const PatientFormScreen({super.key, this.patientId});
  final String? patientId;

  @override
  State<PatientFormScreen> createState() => _PatientFormScreenState();
}

class _PatientFormScreenState extends State<PatientFormScreen> {
  final _form = GlobalKey<FormState>();
  Rec? _existing;
  bool _loading = true;
  bool _saving = false;

  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  final _altPhone = TextEditingController();
  final _email = TextEditingController();
  final _age = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();
  final _allergies = TextEditingController();
  final _emName = TextEditingController();
  final _emPhone = TextEditingController();
  final _insurer = TextEditingController();
  final _policy = TextEditingController();
  final _abha = TextEditingController();
  final _notes = TextEditingController();
  String _gender = 'female';
  DateTime? _dob;
  bool _knowsDob = true;
  String? _blood;
  String? _referral;
  String _payer = 'self';

  List<Rec> _duplicates = const [];
  Timer? _dupTimer;

  bool get _editing => widget.patientId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    if (widget.patientId != null) {
      final p = await context.app.readDb.get(Col.patients, widget.patientId);
      if (p != null) {
        _existing = p;
        _first.text = p.str('first_name');
        _last.text = p.str('last_name');
        _phone.text = p.str('phone');
        _altPhone.text = p.str('alt_phone');
        _email.text = p.str('email');
        _address.text = p.str('address');
        _city.text = p.str('city');
        _state.text = p.str('state');
        _pincode.text = p.str('pincode');
        _allergies.text = p.str('allergies');
        _emName.text = p.str('emergency_name');
        _emPhone.text = p.str('emergency_phone');
        _insurer.text = p.str('insurer');
        _policy.text = p.str('policy_no');
        _abha.text = p.str('abha_number');
        _notes.text = p.str('notes');
        _gender = p.str('gender', 'female');
        _dob = p.date('dob');
        _knowsDob = _dob != null || p.intOrNull('age_years') == null;
        _age.text = p.intOrNull('age_years')?.toString() ?? '';
        _blood = p.strOrNull('blood_group');
        _referral = p.strOrNull('referral_source');
        _payer = p.str('payer_type', 'self');
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _dupTimer?.cancel();
    for (final c in [_first, _last, _phone, _altPhone, _email, _age, _address, _city, _state, _pincode, _allergies, _emName, _emPhone, _insurer, _policy, _abha, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Looks for an existing record while the receptionist types, so the same
  /// person doesn't get two UHIDs.
  void _checkDuplicates() {
    _dupTimer?.cancel();
    _dupTimer = Timer(const Duration(milliseconds: 400), () async {
      if (_first.text.trim().isEmpty && _phone.text.trim().length < 10) return;
      final d = await PatientService.possibleDuplicates(
        context.app.readDb,
        phone: _phone.text,
        first: _first.text,
        last: _last.text,
        dob: _knowsDob ? _dob : null,
        excludeId: widget.patientId,
      );
      if (mounted) setState(() => _duplicates = d);
    });
  }

  Map<String, Object?> _values() => {
        'first_name': _first.text,
        'last_name': _last.text,
        'gender': _gender,
        'dob': _knowsDob ? _dob : null,
        'age_years': _knowsDob ? null : int.tryParse(_age.text.trim()),
        'phone': _phone.text,
        'alt_phone': _altPhone.text.trim(),
        'email': _email.text.trim(),
        'address': _address.text.trim(),
        'city': _city.text.trim(),
        'state': _state.text.trim(),
        'pincode': _pincode.text.trim(),
        'blood_group': _blood,
        'allergies': _allergies.text.trim(),
        'emergency_name': _emName.text.trim(),
        'emergency_phone': _emPhone.text.trim(),
        'referral_source': _referral,
        'payer_type': _payer,
        'insurer': _payer == 'self' ? '' : _insurer.text.trim(),
        'policy_no': _payer == 'self' ? '' : _policy.text.trim(),
        'abha_number': _abha.text.trim(),
        'notes': _notes.text.trim(),
      };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.app;
    setState(() => _saving = true);
    Rec? saved;
    final ok = await runGuarded(context, () async {
      saved = _editing
          ? await PatientService.updatePatient(app.db, _existing!, _values())
          : await PatientService.register(app.db, app.settings, _values());
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok || saved == null) return;
    final nav = Navigator.of(context);
    if (_editing) {
      app.nav.toast('Saved');
      nav.pop();
    } else {
      app.nav.toast('Registered ${saved!.str('full_name')} · ${saved!.str('uhid')}');
      nav.pop();
      app.nav.open('patients.profile', {'id': saved!.id});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    final theme = Theme.of(context);
    return PageScaffold(
      title: _editing ? 'Edit ${_existing?.str('full_name') ?? 'patient'}' : 'Register a patient',
      subtitle: _editing ? _existing?.str('uhid') : 'A UHID is created automatically when you save',
      maxWidth: 980,
      primaryAction: PageAction(_editing ? 'Save changes' : 'Register', Icons.check, _saving ? null : _save),
      body: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_duplicates.isNotEmpty) ...[_DuplicateBanner(patients: _duplicates), Gap.v16],
            SectionCard(
              title: 'Identity',
              child: FormGrid(children: [
                AppTextField(
                  label: 'First name',
                  controller: _first,
                  autofocus: !_editing,
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.required('First name'),
                  onChanged: (_) => _checkDuplicates(),
                ),
                AppTextField(
                  label: 'Last name',
                  controller: _last,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => _checkDuplicates(),
                ),
                AppTextField(
                  label: 'Mobile number',
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  prefixIcon: Icons.phone_outlined,
                  validator: Validators.requiredPhone,
                  onChanged: (_) => _checkDuplicates(),
                ),
                FullWidth(
                  child: Wrap(
                    spacing: Gap.lg,
                    runSpacing: Gap.md,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'female', label: Text('Female')),
                          ButtonSegment(value: 'male', label: Text('Male')),
                          ButtonSegment(value: 'other', label: Text('Other')),
                        ],
                        selected: {_gender},
                        onSelectionChanged: (s) => setState(() => _gender = s.first),
                      ),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('Date of birth')),
                          ButtonSegment(value: false, label: Text('Age only')),
                        ],
                        selected: {_knowsDob},
                        onSelectionChanged: (s) => setState(() => _knowsDob = s.first),
                      ),
                    ],
                  ),
                ),
                if (_knowsDob)
                  DateField(
                    label: 'Date of birth',
                    value: _dob,
                    lastDate: DateTime.now(),
                    helper: _dob == null ? null : 'Age ${ageLabel(_dob, null)}',
                    onChanged: (d) {
                      setState(() => _dob = d);
                      _checkDuplicates();
                    },
                  )
                else
                  AppTextField(
                    label: 'Age in years',
                    controller: _age,
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return (n == null || n < 0 || n > 130) ? 'Enter the age in years' : null;
                    },
                  ),
                AppTextField(label: 'Alternate phone', controller: _altPhone, keyboardType: TextInputType.phone, validator: Validators.phone),
                AppTextField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress, validator: Validators.email),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Address',
              child: FormGrid(children: [
                FullWidth(child: AppTextField(label: 'Address', controller: _address, maxLines: 2)),
                AppTextField(label: 'City / town', controller: _city, textCapitalization: TextCapitalization.words),
                AppTextField(label: 'State', controller: _state, textCapitalization: TextCapitalization.words),
                AppTextField(label: 'PIN code', controller: _pincode, keyboardType: TextInputType.number),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Medical',
              child: FormGrid(children: [
                AppDropdown<String>(
                  label: 'Blood group',
                  value: _blood,
                  items: [for (final b in bloodGroups) (b, b)],
                  onChanged: (v) => setState(() => _blood = v),
                ),
                FullWidth(
                  child: AppTextField(
                    label: 'Allergies',
                    controller: _allergies,
                    hint: 'e.g. Penicillin, peanuts. Leave empty if none known.',
                    maxLines: 2,
                  ),
                ),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Payment',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'self', label: Text('Self pay')),
                      ButtonSegment(value: 'insurance', label: Text('Insurance')),
                      ButtonSegment(value: 'corporate', label: Text('Corporate')),
                    ],
                    selected: {_payer},
                    onSelectionChanged: (s) => setState(() => _payer = s.first),
                  ),
                  if (_payer != 'self') ...[
                    Gap.v16,
                    FormGrid(children: [
                      AppTextField(
                        label: _payer == 'insurance' ? 'Insurer / TPA' : 'Company',
                        controller: _insurer,
                        validator: Validators.required(_payer == 'insurance' ? 'Insurer' : 'Company'),
                      ),
                      AppTextField(label: _payer == 'insurance' ? 'Policy number' : 'Employee ID', controller: _policy),
                    ]),
                  ],
                ],
              ),
            ),
            Gap.v16,
            SectionCard(
              title: 'Emergency contact and other details',
              child: FormGrid(children: [
                AppTextField(label: 'Emergency contact name', controller: _emName, textCapitalization: TextCapitalization.words),
                AppTextField(label: 'Emergency contact phone', controller: _emPhone, keyboardType: TextInputType.phone, validator: Validators.phone),
                AppDropdown<String>(
                  label: 'How did they hear of us?',
                  value: _referral,
                  items: [for (final r in referralSources) (r, r)],
                  onChanged: (v) => setState(() => _referral = v),
                ),
                AppTextField(label: 'ABHA number (optional)', controller: _abha),
                FullWidth(child: AppTextField(label: 'Notes', controller: _notes, maxLines: 3)),
              ]),
            ),
            Gap.v24,
            if (!context.isCompact)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(_editing ? 'Save changes' : 'Register patient'),
                ),
              ),
            Text(
              'Required: first name, mobile number, and date of birth or age.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DuplicateBanner extends StatelessWidget {
  const _DuplicateBanner({required this.patients});
  final List<Rec> patients;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, Tone.warning);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.lg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.person_search_outlined, color: c.foreground),
            Gap.h8,
            Expanded(
              child: Text('This may be a patient we already have',
                  style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
            ),
          ]),
          Gap.v8,
          for (final p in patients)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(p.str('full_name')),
              title: Text(p.str('full_name')),
              subtitle: Text(PatientService.summary(p)),
              trailing: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  context.app.nav.open('patients.profile', {'id': p.id});
                },
                child: const Text('Open'),
              ),
            ),
        ],
      ),
    );
  }
}

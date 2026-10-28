import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../patient_service.dart';

/// One patient: details, actions from every module, and a tab per module
/// (consultations, bills, medicines, reports...).
class PatientProfileScreen extends StatefulWidget {
  const PatientProfileScreen({super.key, required this.patientId});
  final String patientId;

  @override
  State<PatientProfileScreen> createState() => _PatientProfileScreenState();
}

class _PatientProfileScreenState extends State<PatientProfileScreen> {
  bool _logged = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_logged) {
      _logged = true;
      // Access to patient records is itself audited.
      context.db.audit('view', collection: Col.patients, recordId: widget.patientId).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<Rec?>(
      watch: const {Col.patients},
      deps: [widget.patientId],
      load: (db) => db.get(Col.patients, widget.patientId),
      builder: (context, p) {
        if (p == null) {
          return const PageScaffold(
            title: 'Patient',
            body: EmptyState(icon: Icons.person_off_outlined, title: 'Patient not found'),
          );
        }
        return _Profile(patient: p);
      },
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile({required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final tabs = app.registry.patientTabs.where((t) => t.permission == null || context.can(t.permission!)).toList();
    final actions =
        app.registry.patientActions.where((a) => a.permission == null || context.can(a.permission!)).toList();
    final canEdit = context.can(PatientPerms.edit);

    return DefaultTabController(
      length: tabs.length + 1,
      child: PageScaffold(
        title: patient.str('full_name'),
        subtitle: PatientService.summary(patient),
        scrollable: false,
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Edit details',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => app.nav.open('patients.edit', {'id': patient.id}),
            ),
        ],
        headerBottom: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Badges(patient: patient),
            if (actions.isNotEmpty) ...[
              Gap.v12,
              TourAnchor(
                id: 'patients.actions',
                child: Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    for (final (i, a) in actions.indexed)
                      i == 0
                          ? FilledButton.icon(onPressed: () => a.run(context, patient), icon: Icon(a.icon, size: 18), label: Text(a.label))
                          : OutlinedButton.icon(onPressed: () => a.run(context, patient), icon: Icon(a.icon, size: 18), label: Text(a.label)),
                  ],
                ),
              ),
            ],
            Gap.v12,
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [const Tab(text: 'Details'), for (final t in tabs) Tab(text: t.title)],
            ),
          ],
        ),
        body: TabBarView(
          children: [
            SingleChildScrollView(padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl), child: _Details(patient: patient)),
            for (final t in tabs)
              SingleChildScrollView(
                padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xl),
                child: t.builder(context, patient),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badges extends StatelessWidget {
  const _Badges({required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final allergies = patient.str('allergies');
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        StatusChip(patient.str('uhid'), icon: Icons.badge_outlined, tone: Tone.info),
        if (patient.strOrNull('blood_group') != null) StatusChip('Blood ${patient.str('blood_group')}', icon: Icons.bloodtype_outlined),
        if (allergies.isNotEmpty)
          StatusChip('Allergies: $allergies', icon: Icons.warning_amber_rounded, tone: Tone.danger)
        else
          const StatusChip('No known allergies', tone: Tone.success),
        switch (patient.str('payer_type', 'self')) {
          'insurance' => StatusChip('Insurance · ${patient.str('insurer')}', tone: Tone.info),
          'corporate' => StatusChip('Corporate · ${patient.str('insurer')}', tone: Tone.board),
          _ => const StatusChip('Self pay'),
        },
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final p = patient;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Personal',
          child: InfoGrid([
            ('Full name', p.str('full_name')),
            ('UHID', p.str('uhid')),
            ('Gender', genderLabel(p.strOrNull('gender'))),
            ('Date of birth', p.date('dob') == null ? 'Not recorded' : formatDate(p.date('dob'))),
            ('Age', ageLabel(p.date('dob'), p.intOrNull('age_years'))),
            ('Mobile', p.str('phone')),
            ('Alternate phone', p.str('alt_phone')),
            ('Email', p.str('email')),
            ('ABHA number', p.str('abha_number')),
          ]),
        ),
        Gap.v16,
        SectionCard(
          title: 'Address',
          child: InfoGrid([
            ('Address', p.str('address')),
            ('City', p.str('city')),
            ('State', p.str('state')),
            ('PIN code', p.str('pincode')),
          ]),
        ),
        Gap.v16,
        ResponsiveGrid(minWidth: 320, maxColumns: 2, children: [
          SectionCard(
            title: 'Emergency contact',
            child: InfoGrid([('Name', p.str('emergency_name')), ('Phone', p.str('emergency_phone'))]),
          ),
          SectionCard(
            title: 'Payment',
            child: InfoGrid([
              ('Payer', titleCase(p.str('payer_type', 'self'))),
              ('Insurer / company', p.str('insurer')),
              ('Policy / employee ID', p.str('policy_no')),
            ]),
          ),
        ]),
        Gap.v16,
        SectionCard(
          title: 'Other',
          child: InfoGrid([
            ('Referral source', p.str('referral_source')),
            ('Registered', formatDateTime(p.createdAt)),
            ('Last updated', formatDateTime(p.updatedAt)),
            ('Notes', p.str('notes')),
          ]),
        ),
      ],
    );
  }
}

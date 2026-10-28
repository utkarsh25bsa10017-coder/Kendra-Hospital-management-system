import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../bed_days.dart';
import '../ipd_schema.dart';
import '../ipd_service.dart';
import '../widgets/ipd_widgets.dart';
import 'admission/charges_tab.dart';
import 'admission/discharge_tab.dart';
import 'admission/notes_tab.dart';
import 'admission/transfer_tab.dart';

/// One inpatient stay and the records around it.
class AdmissionView {
  AdmissionView({required this.admission, this.patient, this.bed, this.ward, this.doctor});
  final Rec admission;
  final Rec? patient;
  final Rec? bed;
  final Rec? ward;
  final Rec? doctor;

  String get status => admission.str('status');
  bool get discharged => status == IpdVals.discharged;
  String get patientName => patient?.str('full_name') ?? 'Patient';
  String get bedLabel => bed?.str('label') ?? '—';
  String get wardName => ward?.str('name') ?? '';

  static Future<AdmissionView?> load(ReadDb db, String id) async {
    final a = await db.get(IpdCol.admissions, id);
    if (a == null) return null;
    return AdmissionView(
      admission: a,
      patient: await db.get(Col.patients, a.strOrNull('patient_id')),
      bed: await db.get(IpdCol.beds, a.strOrNull('bed_id')),
      ward: await db.get(IpdCol.wards, a.strOrNull('ward_id')),
      doctor: await db.get(Col.users, a.strOrNull('attending_doctor_id')),
    );
  }
}

class AdmissionScreen extends StatelessWidget {
  const AdmissionScreen({super.key, required this.admissionId, this.initialTab = 0});
  final String admissionId;
  final int initialTab;

  static const tabs = ['notes', 'charges', 'transfer', 'discharge'];
  static int tabIndex(Object? tab) => tabs.contains(tab) ? tabs.indexOf(tab! as String) : 0;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<AdmissionView?>(
      watch: const {IpdCol.admissions, IpdCol.beds, IpdCol.wards, Col.patients},
      deps: [admissionId],
      load: (db) => AdmissionView.load(db, admissionId),
      builder: (context, v) {
        if (v == null) {
          return const PageScaffold(
            title: 'Admission',
            body: EmptyState(icon: Icons.assignment_late_outlined, title: 'Admission not found'),
          );
        }
        return _AdmissionPage(view: v, initialTab: initialTab);
      },
    );
  }
}

class _AdmissionPage extends StatelessWidget {
  const _AdmissionPage({required this.view, required this.initialTab});
  final AdmissionView view;
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    final a = view.admission;
    final p = view.patient;
    final app = context.app;
    final now = DateTime.now();
    final admitted = a.date('admitted_at') ?? a.createdAt;
    final end = a.date('discharged_at');
    final expected = a.date('expected_discharge');
    final overdue = !view.discharged && expected != null && startOfDay(now).isAfter(startOfDay(expected));
    final allergies = p?.str('allergies') ?? '';
    final compact = context.isCompact;

    final stayLabel = view.discharged
        ? plural(BedDays.count(admittedAt: admitted, dischargedAt: end, now: now), 'bed-day')
        : 'Day ${BedDays.dayNumber(admitted, now)}';

    return DefaultTabController(
      length: 4,
      initialIndex: initialTab,
      child: PageScaffold(
        title: view.patientName,
        subtitle: [
          a.str('number'),
          if (p != null) p.str('uhid'),
          if (p != null) ageLabel(p.date('dob'), p.intOrNull('age_years')),
          if (p != null && !compact) genderLabel(p.strOrNull('gender')),
        ].where((s) => s.isNotEmpty && s != '—').join(' · '),
        scrollable: false,
        actions: [
          if (p != null)
            IconButton(
              tooltip: 'Patient profile',
              icon: const Icon(Icons.person_outline),
              onPressed: () => app.nav.open('patients.profile', {'id': p.id}),
            ),
        ],
        headerBottom: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                AdmissionStatusChip(view.status),
                if (!view.discharged)
                  StatusChip([view.bedLabel, if (view.wardName.isNotEmpty) view.wardName].join(' · '),
                      icon: Icons.king_bed_outlined, tone: Tone.info),
                StatusChip(compact ? stayLabel : '$stayLabel · since ${formatDateShort(admitted)}', icon: Icons.calendar_today_outlined),
                if (view.doctor != null)
                  StatusChip(compact ? shortDoctor(view.doctor!.str('display_name')) : view.doctor!.str('display_name'),
                      icon: Icons.medical_services_outlined),
                if (expected != null && !view.discharged)
                  StatusChip('${compact ? 'Out' : 'Expected out'} ${formatDateShort(expected)}',
                      icon: Icons.event_available_outlined, tone: overdue ? Tone.warning : Tone.neutral),
              ],
            ),
            if (a.str('diagnosis').isNotEmpty) ...[
              Gap.v8,
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'Diagnosis  ', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  TextSpan(text: a.str('diagnosis'), style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (allergies.isNotEmpty) ...[
              Gap.v8,
              compact
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: StatusChip('Allergies: $allergies', icon: Icons.warning_amber_rounded, tone: Tone.danger))
                  : ToneBanner(
                      tone: Tone.danger,
                      icon: Icons.warning_amber_rounded,
                      title: 'Allergies: $allergies',
                      message: 'Check every new medicine against this before giving it.',
                    ),
            ],
            Gap.v8,
            TourAnchor(
              id: 'ipd.admission.tabs',
              child: const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [Tab(text: 'Notes'), Tab(text: 'Charges so far'), Tab(text: 'Transfer'), Tab(text: 'Discharge')],
              ),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _TabPage(child: NotesTab(view: view)),
            _TabPage(child: ChargesTab(view: view)),
            _TabPage(child: TransferTab(view: view)),
            _TabPage(child: DischargeTab(view: view)),
          ],
        ),
      ),
    );
  }
}

class _TabPage extends StatelessWidget {
  const _TabPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(padding: const EdgeInsets.only(top: Gap.lg, bottom: 96), child: child);
}

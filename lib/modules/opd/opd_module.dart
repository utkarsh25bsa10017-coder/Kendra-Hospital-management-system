import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/critical_vitals_agent.dart';
import 'agents/unsigned_notes_agent.dart';
import 'demo_data.dart';
import 'opd_schema.dart';
import 'opd_service.dart';
import 'screens/clinical_record_tab.dart';
import 'screens/consult_screen.dart';
import 'screens/consultation_note_screen.dart';
import 'screens/opd_queue_screen.dart';

/// The doctor's OPD: the token queue, the consultation workspace (vitals,
/// notes, prescription, tests) and the signed clinical record.
class OpdModule extends HmsModule {
  @override
  String get id => 'opd';
  @override
  String get name => 'OPD & clinical notes';
  @override
  String get description =>
      'Doctor\'s queue, fast consultation notes, prescriptions and test orders, with the consultation charge sent to billing.';
  @override
  IconData get icon => Icons.medical_services_outlined;

  @override
  List<CollectionSchema> get collections => const [consultationsCollection, amendmentsCollection];

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(OpdPerms.consult, 'See patients in OPD and sign consultation notes', roles: {Roles.doctor}),
        PermissionDef(OpdPerms.vitals, 'Record vitals in OPD', roles: {Roles.nurse, Roles.doctor}),
        PermissionDef(OpdPerms.viewNotes, 'View the OPD queue and clinical notes',
            roles: {Roles.doctor, Roles.nurse, Roles.admin, Roles.board}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'opd.queue',
          title: 'My OPD',
          icon: Icons.medical_services_outlined,
          section: NavSection.clinical,
          order: 10,
          mobilePriority: 3,
          permission: OpdPerms.viewNotes,
          description: 'Today\'s OPD queue by token',
          builder: (c, a) => const OpdQueueScreen(),
        ),
        ModuleRoute(
          id: 'opd.consult',
          title: 'Consultation',
          icon: Icons.edit_note,
          showInNav: false,
          permission: OpdPerms.consult,
          builder: (c, a) => ConsultScreen(encounterId: a['encounterId'] as String),
        ),
        ModuleRoute(
          id: 'opd.consultation',
          title: 'Consultation note',
          icon: Icons.description_outlined,
          showInNav: false,
          permission: OpdPerms.viewNotes,
          builder: (c, a) => ConsultationNoteScreen(consultationId: a['id'] as String),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'opd.clinical',
          title: 'Clinical record',
          order: 10,
          permission: OpdPerms.viewNotes,
          builder: (c, p) => ClinicalRecordTab(patient: p),
        ),
      ];

  @override
  List<PatientAction> get patientActions => [
        PatientAction(
          id: 'opd.start',
          label: 'Start consultation',
          icon: Icons.medical_services_outlined,
          order: 10,
          permission: OpdPerms.consult,
          run: _startForPatient,
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'opd.call_next',
          label: 'Call next patient',
          icon: Icons.campaign_outlined,
          permission: OpdPerms.consult,
          keywords: const ['next patient', 'token', 'opd', 'queue', 'consult'],
          run: _callNext,
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
          id: 'opd.today',
          title: 'OPD today',
          order: 20,
          permission: OpdPerms.viewNotes,
          builder: (c) => const OpdTodayCard(),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'opd.queue',
          order: 30,
          anchorId: 'nav.opd.queue',
          routeId: 'opd.queue',
          permission: OpdPerms.viewNotes,
          title: 'Your OPD queue',
          body: 'Patients checked in for you today, by token, with how long they have waited and their vitals. '
              'Red means a reading needs attention.',
        ),
        TourStep(
          id: 'opd.call_next',
          order: 31,
          anchorId: 'opd.call_next',
          routeId: 'opd.queue',
          permission: OpdPerms.consult,
          title: 'Call the next patient',
          body: 'One tap calls the next token and opens the consultation, with the nurse\'s vitals and the '
              'patient\'s history already there.',
        ),
        TourStep(
          id: 'opd.rx',
          order: 32,
          anchorId: 'opd.rx',
          routeId: 'opd.queue',
          permission: OpdPerms.consult,
          title: 'Prescriptions in seconds',
          body: 'Search a medicine, tap a frequency like 1-0-1 and a duration, press Enter. Quantity is worked out, '
              'allergies are checked, and "Repeat last prescription" copies the previous one. '
              'Finishing sends it to the pharmacy and the charge to billing.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [UnsignedNotesAgent(), CriticalVitalsAgent()];

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoOpd(ctx);

  static Future<void> _startForPatient(BuildContext context, Rec patient) async {
    final s = context.session;
    if (s == null) return;
    if (!s.isClinician) {
      context.toast('Your account is not set up as a doctor. Ask the administrator to mark you as a clinician.', error: true);
      return;
    }
    final app = context.app;
    Rec? enc;
    final ok = await runGuarded(context, () async {
      enc = await OpdService.startForPatient(app.db, patient, s.user);
    });
    if (ok && enc != null) app.nav.open('opd.consult', {'encounterId': enc!.id});
  }

  static Future<void> _callNext(BuildContext context) async {
    final s = context.session;
    if (s == null) return;
    final app = context.app;
    if (!s.isClinician) {
      app.nav.toast('Only doctors have a queue to call from', error: true);
      return;
    }
    final next = await OpdService.nextWaiting(app.readDb, s.userId);
    if (next == null) {
      app.nav.toast('No one is waiting for you right now');
      return;
    }
    try {
      await OpdService.start(app.db, next, doctor: s.user);
      final patient = await app.readDb.get(Col.patients, next.str('patient_id'));
      app.nav.toast('Token ${next.intOrNull('token_no') ?? ''} · ${patient?.str('full_name') ?? 'patient'}, please come in');
      app.nav.open('opd.consult', {'encounterId': next.id});
    } catch (e) {
      app.nav.toast(e.toString(), error: true);
    }
  }
}

/// Dashboard tile: patients seen and waiting today, and the average
/// consultation time.
class OpdTodayCard extends StatelessWidget {
  const OpdTodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<List<Rec>>(
      watch: const {Col.encounters},
      load: (db) => db.query(OpdService.dayQuery()),
      builder: (context, encs) {
        final seen = encs.where((e) => e.str('status') == Vals.closed).toList();
        final waiting = encs.where(OpdService.isWaiting).length;
        final mins = [
          for (final e in seen)
            if (e.date('called_at') != null && e.date('ended_at') != null)
              e.date('ended_at')!.difference(e.date('called_at')!).inMinutes,
        ];
        final avg = mins.isEmpty ? null : (mins.reduce((a, b) => a + b) / mins.length).round();
        return KpiTile(
          label: 'OPD today',
          value: '${seen.length} seen',
          caption: '$waiting waiting${avg == null ? '' : ' · average consultation $avg min'}',
          icon: Icons.medical_services_outlined,
          tone: Tone.info,
          onTap: () => context.app.nav.open('opd.queue'),
        );
      },
    );
  }
}

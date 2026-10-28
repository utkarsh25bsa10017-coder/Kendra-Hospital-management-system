import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/bed_turnaround_agent.dart';
import 'agents/discharge_delay_agent.dart';
import 'agents/long_stay_agent.dart';
import 'agents/unbilled_bed_days_agent.dart';
import 'bed_charging.dart';
import 'demo_data.dart';
import 'ipd_schema.dart';
import 'ipd_service.dart';
import 'screens/admission_screen.dart';
import 'screens/admissions_screen.dart';
import 'screens/admit_screen.dart';
import 'screens/bed_board_screen.dart';
import 'screens/wards_screen.dart';
import 'widgets/ipd_cards.dart';

/// Inpatients: the bed board, admission, transfers, bedside notes and
/// discharge. Bed-day charges are posted to core `charges` automatically
/// (see bed_days.dart for the rule).
class IpdModule extends HmsModule {
  @override
  String get id => 'ipd';
  @override
  String get name => 'Inpatients (IPD)';
  @override
  String get description => 'Bed board, admissions, transfers, nursing notes and discharge, with automatic bed-day charges.';
  @override
  IconData get icon => Icons.king_bed_outlined;

  @override
  List<CollectionSchema> get collections => ipdCollections;

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(IpdPerms.view, 'See the bed board and inpatients', roles: {
          Roles.doctor, Roles.nurse, Roles.admin, Roles.board, Roles.receptionist, Roles.billing,
        }),
        PermissionDef(IpdPerms.admit, 'Admit and transfer patients, mark beds ready',
            roles: {Roles.receptionist, Roles.doctor, Roles.nurse, Roles.admin}),
        PermissionDef(IpdPerms.notes, 'Write nursing and progress notes', roles: {Roles.doctor, Roles.nurse}),
        PermissionDef(IpdPerms.discharge, 'Sign off discharges', roles: {Roles.doctor}),
        PermissionDef(IpdPerms.setup, 'Set up wards and beds', roles: {Roles.admin}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'ipd.beds',
          title: 'Beds',
          icon: Icons.king_bed_outlined,
          section: NavSection.clinical,
          order: 20,
          mobilePriority: 5,
          permission: IpdPerms.view,
          description: 'Who is in which bed, and which beds are free',
          builder: (c, a) => const BedBoardScreen(),
        ),
        ModuleRoute(
          id: 'ipd.admissions',
          title: 'Admissions',
          icon: Icons.assignment_ind_outlined,
          section: NavSection.clinical,
          order: 21,
          permission: IpdPerms.view,
          description: 'Current inpatients and recent discharges',
          builder: (c, a) => const AdmissionsScreen(),
        ),
        ModuleRoute(
          id: 'ipd.admit',
          title: 'Admit patient',
          icon: Icons.login,
          showInNav: false,
          permission: IpdPerms.admit,
          builder: (c, a) => AdmitScreen(patientId: a['patientId'] as String?, bedId: a['bedId'] as String?),
        ),
        ModuleRoute(
          id: 'ipd.admission',
          title: 'Admission',
          icon: Icons.assignment_ind_outlined,
          showInNav: false,
          permission: IpdPerms.view,
          // args: {id, tab?: 'notes' | 'charges' | 'transfer' | 'discharge'}
          builder: (c, a) => AdmissionScreen(admissionId: a['id'] as String, initialTab: AdmissionScreen.tabIndex(a['tab'])),
        ),
        ModuleRoute(
          id: 'ipd.wards',
          title: 'Wards & beds',
          icon: Icons.meeting_room_outlined,
          section: NavSection.admin,
          order: 50,
          permission: IpdPerms.setup,
          description: 'Wards, bed numbers and bed-day prices',
          builder: (c, a) => const WardsScreen(),
        ),
      ];

  @override
  List<PatientAction> get patientActions => [
        PatientAction(
          id: 'ipd.admit',
          label: 'Admit',
          icon: Icons.king_bed_outlined,
          permission: IpdPerms.admit,
          order: 40,
          run: (c, p) => c.app.nav.open('ipd.admit', {'patientId': p.id}),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'ipd.admissions',
          title: 'Admissions',
          permission: IpdPerms.view,
          order: 40,
          builder: (c, p) => PatientAdmissionsTab(patient: p),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'ipd.admit',
          label: 'Admit patient',
          icon: Icons.king_bed_outlined,
          permission: IpdPerms.admit,
          keywords: const ['ipd', 'admission', 'inpatient', 'bed'],
          run: (c) => c.app.nav.open('ipd.admit'),
        ),
        QuickAction(
          id: 'ipd.beds',
          label: 'Bed board',
          icon: Icons.grid_view_outlined,
          permission: IpdPerms.view,
          keywords: const ['beds', 'ward', 'occupancy', 'free bed', 'ipd'],
          run: (c) => c.app.nav.open('ipd.beds'),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
          id: 'ipd.occupancy',
          title: 'Bed occupancy',
          permission: IpdPerms.view,
          size: CardSize.wide,
          order: 30,
          builder: (c) => const OccupancyCard(),
        ),
        DashboardCard(
          id: 'ipd.today',
          title: 'Admissions & discharges today',
          permission: IpdPerms.view,
          order: 31,
          builder: (c) => const AdmissionsTodayCard(),
        ),
        DashboardCard(
          id: 'ipd.average_stay',
          title: 'Average stay (30 days)',
          permission: IpdPerms.view,
          order: 32,
          builder: (c) => const AverageStayCard(),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'ipd.board',
          order: 40,
          anchorId: 'ipd.board',
          routeId: 'ipd.beds',
          permission: IpdPerms.view,
          title: 'The bed board',
          body: 'Every bed in every ward: green is free, blue is occupied, amber is being cleaned. '
              'Tap a free bed to admit, an occupied bed to open the patient, a bed in cleaning to mark it ready.',
        ),
        TourStep(
          id: 'ipd.admit',
          order: 41,
          anchorId: 'ipd.admit',
          routeId: 'ipd.beds',
          permission: IpdPerms.admit,
          title: 'Admit a patient',
          body: 'Pick the patient, a free bed and the doctor. Bed and nursing charges are then posted '
              'automatically for every day of the stay, so none are forgotten.',
        ),
        TourStep(
          id: 'ipd.discharge',
          order: 42,
          anchorId: 'ipd.admissions.list',
          routeId: 'ipd.admissions',
          permission: IpdPerms.view,
          title: 'Discharge in two steps',
          body: 'Open an admission and go to Discharge. The doctor writes the summary and advice; '
              'the desk completes the discharge, which posts the last bed-days and sends the bed for cleaning.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [UnbilledBedDaysAgent(), LongStayAgent(), BedTurnaroundAgent(), DischargeDelayAgent()];

  Timer? _hourly;

  /// Bed-day posting: once at start and then every hour, on the device that
  /// holds the data. It skips its turn while IPD is switched off and stops
  /// when the app shuts down or restarts.
  @override
  Future<void> onStart(ModuleContext ctx) async {
    if (!ctx.isDataHost) return;
    _hourly?.cancel();
    Future<void> post() async {
      if (!ctx.services.registry.isActive(id)) return;
      try {
        await BedCharging.postAll(ctx.systemDb);
      } catch (e) {
        debugPrint('ipd: bed-day posting failed: $e');
      }
    }

    _hourly = Timer.periodic(const Duration(hours: 1), (_) => post());
    await post();
  }

  @override
  Future<void> onStop(ModuleContext ctx) async {
    _hourly?.cancel();
    _hourly = null;
  }

  @override
  Future<void> seedDefaults(ModuleContext ctx) => IpdService.seedDefaults(ctx.systemDb);

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoIpd(ctx);
}

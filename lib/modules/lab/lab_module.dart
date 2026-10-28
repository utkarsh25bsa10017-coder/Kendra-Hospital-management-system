import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/critical_results_agent.dart';
import 'agents/turnaround_agent.dart';
import 'agents/uncollected_agent.dart';
import 'agents/unverified_agent.dart';
import 'demo_data.dart';
import 'lab_catalog.dart';
import 'lab_schema.dart';
import 'screens/dashboard_cards.dart';
import 'screens/new_order_screen.dart';
import 'screens/order_screen.dart';
import 'screens/patient_lab_tab.dart';
import 'screens/tests_screen.dart';
import 'screens/worklist_screen.dart';

/// The laboratory: sample collection (which posts the charge), result entry
/// with live flags, verification by a second person, amendments, critical
/// value alerts and the printable report. Orders are core `service_orders`,
/// so OPD, IPD and the front desk can order tests without importing this.
class LabModule extends HmsModule {
  @override
  String get id => 'lab';
  @override
  String get name => 'Laboratory';
  @override
  String get description =>
      'Lab worklist, sample collection, result entry with flags, verified reports and critical value alerts.';
  @override
  IconData get icon => Icons.biotech_outlined;

  @override
  List<CollectionSchema> get collections => const [labTestsCollection, labResultsCollection];

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(LabPerms.view, 'See the lab worklist and reports',
            roles: {Roles.labTech, Roles.pathologist, Roles.doctor, Roles.nurse, Roles.admin, Roles.board}),
        PermissionDef(LabPerms.collect, 'Collect lab samples', roles: {Roles.labTech, Roles.nurse}),
        PermissionDef(LabPerms.result, 'Enter lab results', roles: {Roles.labTech, Roles.pathologist}),
        PermissionDef(LabPerms.verify, 'Verify and sign lab reports', roles: {Roles.pathologist}),
        PermissionDef(LabPerms.order, 'Order lab tests', roles: {Roles.doctor, Roles.receptionist, Roles.nurse}),
        PermissionDef(LabPerms.catalog, 'Edit the lab test catalogue', roles: {Roles.pathologist, Roles.admin}),
        PermissionDef(LabPerms.acknowledge, 'Acknowledge critical lab results', roles: {Roles.doctor}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'lab.worklist',
          title: 'Lab worklist',
          icon: Icons.biotech_outlined,
          section: NavSection.diagnostics,
          order: 10,
          mobilePriority: 4,
          permission: LabPerms.view,
          description: 'Collect samples, enter results and verify reports',
          builder: (c, a) => LabWorklistScreen(initialTab: a['tab'] as String?),
        ),
        ModuleRoute(
          id: 'lab.order',
          title: 'Lab order',
          icon: Icons.science_outlined,
          showInNav: false,
          permission: LabPerms.view,
          builder: (c, a) => LabOrderScreen(orderId: a['id'] as String, report: a['report'] == true),
        ),
        ModuleRoute(
          id: 'lab.new_order',
          title: 'New lab order',
          icon: Icons.add_task,
          showInNav: false,
          permission: LabPerms.order,
          builder: (c, a) => LabNewOrderScreen(patientId: a['patientId'] as String?),
        ),
        ModuleRoute(
          id: 'lab.tests',
          title: 'Lab tests',
          icon: Icons.science_outlined,
          section: NavSection.diagnostics,
          order: 30,
          permission: LabPerms.catalog,
          description: 'Test catalogue, reference ranges and prices',
          builder: (c, a) => const LabTestsScreen(),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'lab.reports',
          title: 'Lab reports',
          order: 40,
          permission: LabPerms.view,
          builder: (c, p) => PatientLabTab(patient: p),
        ),
      ];

  @override
  List<PatientAction> get patientActions => [
        PatientAction(
          id: 'lab.order',
          label: 'Order lab test',
          icon: Icons.biotech_outlined,
          order: 40,
          permission: LabPerms.order,
          run: (c, p) => c.app.nav.open('lab.new_order', {'patientId': p.id}),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'lab.new_order',
          label: 'Order lab test',
          icon: Icons.biotech_outlined,
          permission: LabPerms.order,
          keywords: const ['lab', 'test', 'investigation', 'blood test', 'cbc', 'pathology'],
          run: (c) => c.app.nav.open('lab.new_order'),
        ),
        QuickAction(
          id: 'lab.worklist',
          label: 'Lab worklist',
          icon: Icons.science_outlined,
          permission: LabPerms.view,
          keywords: const ['lab', 'samples', 'collect', 'results', 'verify', 'reports'],
          run: (c) => c.app.nav.open('lab.worklist'),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(id: 'lab.today', title: 'Lab today', order: 40, permission: LabPerms.view, builder: (c) => const LabTodayCard()),
        DashboardCard(
            id: 'lab.awaiting_verification',
            title: 'Awaiting verification',
            order: 41,
            permission: LabPerms.view,
            builder: (c) => const AwaitingVerificationCard()),
        DashboardCard(
            id: 'lab.critical', title: 'Critical results', order: 42, permission: LabPerms.view, builder: (c) => const CriticalResultsCard()),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'lab.nav',
          order: 40,
          anchorId: 'nav.lab.worklist',
          routeId: 'lab.worklist',
          permission: LabPerms.view,
          title: 'Lab worklist',
          body: 'Every test ordered by doctors or the front desk lands here. STAT orders come first, '
              'and the countdown turns red when a report is overdue.',
        ),
        TourStep(
          id: 'lab.tabs',
          order: 41,
          anchorId: 'lab.worklist.tabs',
          routeId: 'lab.worklist',
          permission: LabPerms.view,
          title: 'From sample to report',
          body: 'Work moves left to right: collect the sample, enter the results, and a pathologist verifies '
              'them. Completed reports for today are in the last tab.',
        ),
        TourStep(
          id: 'lab.collect',
          order: 42,
          anchorId: 'lab.collect',
          routeId: 'lab.worklist',
          permission: LabPerms.collect,
          title: 'Collect samples',
          body: 'One tap collects all of a patient\'s tests, gives each tube a sample number to write on it, '
              'and adds the tests to the patient\'s bill.',
        ),
        TourStep(
          id: 'lab.results',
          order: 43,
          anchorId: 'lab.enter_results',
          routeId: 'lab.worklist',
          permission: LabPerms.result,
          title: 'Enter results',
          body: 'Type the values and press Tab or Enter to move on. High, low and critical values are flagged '
              'as you type, and critical values alert the pathologist and the doctor.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [CriticalResultsAgent(), TurnaroundAgent(), UncollectedAgent(), UnverifiedAgent()];

  @override
  Future<void> seedDefaults(ModuleContext ctx) => seedDefaultLabTests(ctx.systemDb);

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoLab(ctx);
}

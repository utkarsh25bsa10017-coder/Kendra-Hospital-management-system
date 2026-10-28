import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'briefing.dart';
import 'cards.dart';
import 'demo_data.dart';
import 'screens/agents_screen.dart';
import 'screens/approvals_screen.dart';
import 'screens/briefing_screen.dart';
import 'screens/findings_screen.dart';
import 'screens/proposals_screen.dart';
import 'screens/tower_home_screen.dart';
import 'tower_data.dart';

/// Where the board oversees the hospital: findings from every module's
/// agents (confirm, dismiss with a reason, assign, mark fixed), discount and
/// refund approvals, agent suggestions, the agents themselves, and the
/// morning briefing. The decision rules live in core's TowerService and
/// ApprovalService; these screens make the decisions fast.
class TowerModule extends HmsModule {
  BriefingJob? _job;

  /// The running morning-briefing job on the data host (null elsewhere).
  BriefingJob? get briefingJob => _job;

  @override
  String get id => 'tower';
  @override
  String get name => 'Control tower';
  @override
  String get description =>
      'Agent findings with evidence, approvals and suggestions for the board, and a morning briefing.';
  @override
  IconData get icon => Icons.radar;

  @override
  List<CollectionSchema> get collections => const [towerBriefingsCollection];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'tower.home',
          title: 'Control tower',
          icon: Icons.radar,
          section: NavSection.oversight,
          order: 10,
          mobilePriority: 5,
          permission: CorePerms.towerView,
          description: 'Findings, approvals and suggestions waiting for the board',
          builder: (c, a) => const TowerHomeScreen(),
        ),
        ModuleRoute(
          id: 'tower.briefing',
          title: 'Morning briefing',
          icon: Icons.wb_sunny_outlined,
          section: NavSection.oversight,
          order: 15,
          permission: CorePerms.towerView,
          description: 'What the agents found since yesterday',
          builder: (c, a) => const BriefingScreen(),
        ),
        ModuleRoute(
          id: 'tower.findings',
          title: 'Findings',
          icon: Icons.flag_outlined,
          section: NavSection.oversight,
          order: 20,
          permission: CorePerms.towerView,
          description: 'Confirm, dismiss or assign what the agents found',
          builder: (c, a) => FindingsScreen(initialId: a['id'] as String?),
        ),
        ModuleRoute(
          id: 'tower.approvals',
          title: 'Approvals',
          icon: Icons.how_to_reg_outlined,
          section: NavSection.oversight,
          order: 30,
          permission: CorePerms.approvalsDecide,
          description: 'Discounts, refunds and other exceptions',
          builder: (c, a) => ApprovalsScreen(highlightId: a['id'] as String?),
        ),
        ModuleRoute(
          id: 'tower.proposals',
          title: 'Agent suggestions',
          icon: Icons.lightbulb_outline,
          section: NavSection.oversight,
          order: 40,
          permission: CorePerms.approvalsDecide,
          description: 'Actions the agents prepared for approval',
          builder: (c, a) => const ProposalsScreen(),
        ),
        ModuleRoute(
          id: 'tower.agents',
          title: 'Agents',
          icon: Icons.smart_toy_outlined,
          section: NavSection.oversight,
          order: 50,
          permission: CorePerms.towerView,
          description: 'Switch agents on or off and see how they ran',
          builder: (c, a) => const AgentsScreen(),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
          id: 'tower.open_findings',
          title: 'Open findings',
          permission: CorePerms.towerView,
          order: 20,
          builder: (c) => const OpenFindingsCard(),
        ),
        DashboardCard(
          id: 'tower.waiting_approval',
          title: 'Waiting for approval',
          permission: CorePerms.approvalsDecide,
          order: 21,
          builder: (c) => const WaitingApprovalCard(),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'tower.review',
          label: 'Review findings',
          icon: Icons.flag_outlined,
          permission: CorePerms.towerView,
          keywords: const ['findings', 'agents', 'audit', 'control tower', 'problems', 'leakage'],
          run: (c) => c.app.nav.open('tower.findings'),
        ),
        QuickAction(
          id: 'tower.approve',
          label: 'Approvals',
          icon: Icons.how_to_reg_outlined,
          permission: CorePerms.approvalsDecide,
          keywords: const ['approve', 'discount', 'refund', 'requests'],
          run: (c) => c.app.nav.open('tower.approvals'),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'tower.nav',
          order: 60,
          anchorId: 'nav.tower.home',
          routeId: 'tower.home',
          permission: CorePerms.towerView,
          title: 'Control tower',
          body: 'Agents check every bill, stock movement and log entry. Problems they find, requests '
              'above staff limits and their suggestions all wait for you here.',
        ),
        TourStep(
          id: 'tower.decide',
          order: 61,
          anchorId: 'tower.decision_bar',
          routeId: 'tower.findings',
          permission: CorePerms.towerDecide,
          title: 'Decide in one tap',
          body: 'Confirm a finding, dismiss it with a reason (the agents learn from it) or assign it to '
              'someone to fix. On a computer: J and K move, C confirms, D dismisses, A assigns, F marks fixed.',
        ),
        TourStep(
          id: 'tower.approvals',
          order: 62,
          anchorId: 'tower.approvals_list',
          routeId: 'tower.approvals',
          permission: CorePerms.approvalsDecide,
          title: 'Approvals',
          body: 'Discounts and refunds above a staff member\'s limit come here. Nobody can approve their '
              'own request, and large amounts need two board members.',
        ),
        TourStep(
          id: 'tower.agents',
          order: 63,
          anchorId: 'tower.agents_list',
          routeId: 'tower.agents',
          permission: CorePerms.towerView,
          title: 'The agents',
          body: 'See what each agent checks and how its last run went. Agents only read; they never change anything.',
        ),
      ];

  @override
  Future<void> onStart(ModuleContext ctx) async {
    if (!ctx.isDataHost) return;
    _job?.stop();
    _job = BriefingJob(ctx)..start();
  }

  @override
  Future<void> onStop(ModuleContext ctx) async {
    _job?.stop();
    _job = null;
  }

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoTower(ctx);
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'dashboard_metrics.dart';
import 'screens/drilldown_screen.dart';
import 'screens/home_screen.dart';

/// The home screen everyone lands on. Shows each person what they can start
/// and what needs them; the owner and the board also see today's numbers
/// (computed from the core contract tables) and every module's cards, and
/// can tap any number to see the records behind it.
class DashboardModule extends HmsModule {
  @override
  String get id => 'dashboard';
  @override
  String get name => 'Dashboard';
  @override
  String get description => 'Home screen with quick actions, alerts and today\'s numbers you can drill into.';
  @override
  IconData get icon => Icons.space_dashboard_outlined;

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(DashboardPerms.view, 'See hospital-wide numbers on the home screen',
            description: 'Patients, visits, inpatients and the value of services delivered, with the records behind them.',
            roles: {Roles.admin, Roles.board, Roles.accountant}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'dashboard.home',
          title: 'Home',
          icon: Icons.space_dashboard_outlined,
          section: NavSection.home,
          order: 0,
          mobilePriority: 1,
          description: 'Quick actions, what needs you and today\'s numbers',
          builder: (c, a) => const DashboardHomeScreen(),
        ),
        ModuleRoute(
          id: 'dashboard.drilldown',
          title: 'Details',
          icon: Icons.table_rows_outlined,
          showInNav: false,
          builder: (c, a) => DrilldownScreen(args: a),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'dashboard.quick_actions',
          order: 5,
          anchorId: 'dashboard.quick_actions',
          routeId: 'dashboard.home',
          title: 'Start here',
          body: 'The things you do most are one tap away. What you see depends on your role.',
        ),
        TourStep(
          id: 'dashboard.kpis',
          order: 6,
          anchorId: 'dashboard.kpis',
          routeId: 'dashboard.home',
          permission: DashboardPerms.view,
          title: 'Every number opens',
          body: 'Tap a number to see the patients, visits or charges behind it, with a total at the bottom.',
        ),
      ];
}

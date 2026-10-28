import 'package:flutter/widgets.dart';

import '../agents/agent.dart';
import '../contracts/permissions.dart';
import '../data/db.dart';
import '../data/record.dart';
import '../data/schema.dart';
import '../services/app_services.dart';

/// Where a screen appears in the navigation.
enum NavSection {
  home('Home'),
  frontDesk('Front desk'),
  clinical('Clinical'),
  diagnostics('Diagnostics'),
  finance('Finance'),
  operations('Operations'),
  oversight('Oversight'),
  admin('Administration');

  const NavSection(this.label);
  final String label;
}

typedef RouteBuilder = Widget Function(BuildContext context, Map<String, Object?> args);

/// A screen contributed by a module.
class ModuleRoute {
  const ModuleRoute({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.permission,
    this.section = NavSection.home,
    this.order = 100,
    this.showInNav = true,
    this.mobilePriority,
    this.description = '',
  });

  /// Globally unique, `<module>.<screen>` e.g. `billing.invoices`.
  final String id;
  final String title;
  final IconData icon;
  final RouteBuilder builder;

  /// Only users with this permission see the screen.
  final String? permission;
  final NavSection section;
  final int order;

  /// False for detail screens opened with `services.nav.open(...)`.
  final bool showInNav;

  /// Lower numbers go in the phone's bottom bar (max 4); null = "More" menu.
  final int? mobilePriority;
  final String description;
}

enum CardSize { small, wide }

/// A tile on the owner dashboard.
class DashboardCard {
  const DashboardCard({
    required this.id,
    required this.title,
    required this.builder,
    this.permission,
    this.size = CardSize.small,
    this.order = 100,
  });
  final String id;
  final String title;
  final WidgetBuilder builder;
  final String? permission;
  final CardSize size;
  final int order;
}

/// One step of the first-login walkthrough.
class TourStep {
  const TourStep({
    required this.id,
    required this.title,
    required this.body,
    this.anchorId,
    this.routeId,
    this.permission,
    this.order = 100,
  });

  /// Stable id; users who have seen a step are not shown it again.
  final String id;
  final String title;
  final String body;

  /// The [TourAnchor] to highlight. Null shows a centred card.
  final String? anchorId;

  /// Screen to open before showing the step.
  final String? routeId;
  final String? permission;
  final int order;
}

/// A tab on the patient profile, contributed by any module.
class PatientTab {
  const PatientTab({required this.id, required this.title, required this.builder, this.permission, this.order = 100});
  final String id;
  final String title;
  final Widget Function(BuildContext context, Rec patient) builder;
  final String? permission;
  final int order;
}

/// A button on the patient profile, contributed by any module
/// (e.g. "Book appointment", "New bill", "Admit").
class PatientAction {
  const PatientAction({required this.id, required this.label, required this.icon, required this.run, this.permission, this.order = 100});
  final String id;
  final String label;
  final IconData icon;
  final void Function(BuildContext context, Rec patient) run;
  final String? permission;
  final int order;
}

/// An entry in the command palette (Ctrl/Cmd + K).
class QuickAction {
  const QuickAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
    this.permission,
    this.keywords = const [],
  });
  final String id;
  final String label;
  final IconData icon;
  final void Function(BuildContext context) run;
  final String? permission;
  final List<String> keywords;
}

/// Carries out an agent proposal after a person approves it.
/// Returns a short description of what was done.
typedef ProposalHandler = Future<String> Function(ModuleContext ctx, Rec proposal, Db db);

/// Applies an approved request (discount, refund...). Returns a short result.
typedef ApprovalHandler = Future<String> Function(ModuleContext ctx, Rec approval, Db db);

class ModuleContext {
  ModuleContext(this.services, this.module);
  final AppServices services;
  final HmsModule module;

  /// Database access as the app itself (for background jobs and seeding).
  Db get systemDb => services.systemDb;

  /// True on the device that owns the database (standalone or hub).
  bool get isDataHost => services.isDataHost;
}

/// A feature module. Implement this, then add one line to
/// `lib/app/module_list.dart`. Removing that line removes the feature; the
/// module's tables stay in the database so nothing is lost.
abstract class HmsModule {
  String get id;
  String get name;
  String get description;
  IconData get icon;

  /// Other module ids this one needs switched on.
  List<String> get dependsOn => const [];

  /// Core modules (e.g. Administration) cannot be switched off.
  bool get required => false;

  /// On by default in a new installation.
  bool get enabledByDefault => true;

  List<CollectionSchema> get collections => const [];
  List<PermissionDef> get permissions => const [];
  List<ModuleRoute> get routes => const [];
  List<HmsAgent> get agents => const [];
  List<DashboardCard> get dashboardCards => const [];
  List<TourStep> get tourSteps => const [];
  List<PatientTab> get patientTabs => const [];
  List<PatientAction> get patientActions => const [];
  List<QuickAction> get quickActions => const [];

  /// Keyed by `ProposalDraft.handler`, e.g. `pharmacy.create_po`.
  Map<String, ProposalHandler> get proposalHandlers => const {};

  /// Keyed by approval type, e.g. `billing.discount`.
  Map<String, ApprovalHandler> get approvalHandlers => const {};

  /// Called once per app start for enabled modules (after sign-in is
  /// possible). Use it for background jobs; check [ModuleContext.isDataHost].
  Future<void> onStart(ModuleContext ctx) async {}

  /// Called when the app shuts down or restarts (backup restore, leaving the
  /// demo). Cancel timers started in [onStart] here.
  Future<void> onStop(ModuleContext ctx) async {}

  /// Called once, the first time the module is enabled, to create default
  /// records such as a standard price list.
  Future<void> seedDefaults(ModuleContext ctx) async {}

  /// Sample data for the demo hospital.
  Future<void> seedDemo(ModuleContext ctx) async {}
}

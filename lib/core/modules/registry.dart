import 'package:flutter/foundation.dart';

import '../agents/agent.dart';
import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../services/settings_service.dart';
import 'module.dart';

/// Knows every installed module and which ones this hospital has switched on.
class ModuleRegistry extends ChangeNotifier {
  ModuleRegistry(List<HmsModule> modules, this.settings) : all = List.unmodifiable(modules) {
    final ids = <String>{};
    for (final m in all) {
      if (!ids.add(m.id)) throw StateError('Two modules use the id "${m.id}"');
    }
    for (final m in all) {
      for (final d in m.dependsOn) {
        if (!ids.contains(d)) throw StateError('Module "${m.id}" needs "$d", which is not installed');
      }
    }
    _recompute();
    settings.addListener(_onSettings);
  }

  final List<HmsModule> all;
  final SettingsService settings;
  List<HmsModule> _active = const [];
  String _signature = '';

  List<HmsModule> get active => _active;

  HmsModule? module(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool isActive(String id) => _active.any((m) => m.id == id);

  /// Ids switched on in settings, or the defaults for a new installation.
  Set<String> get enabledIds {
    final raw = settings.raw(SettingKeys.modulesEnabled);
    if (raw is List) return raw.whereType<String>().toSet();
    return {for (final m in all) if (m.enabledByDefault || m.required) m.id};
  }

  void _onSettings() => _recompute();

  void _recompute() {
    final enabled = enabledIds;
    final out = <HmsModule>[];
    bool on(HmsModule m) => m.required || enabled.contains(m.id);
    for (final m in all) {
      // A module is only active if everything it depends on is active too.
      if (on(m) && m.dependsOn.every((d) => module(d) != null && on(module(d)!))) out.add(m);
    }
    final sig = out.map((m) => m.id).join(',');
    if (sig == _signature) return;
    _signature = sig;
    _active = List.unmodifiable(out);
    // Module getters may build new lists on every call, so take one snapshot.
    _routes = [for (final m in out) ...m.routes];
    _agents = [for (final m in out) for (final a in m.agents) (m, a)];
    _cards = [for (final m in out) ...m.dashboardCards]..sort((a, b) => a.order.compareTo(b.order));
    _steps = [for (final m in out) ...m.tourSteps];
    _tabs = [for (final m in out) ...m.patientTabs]..sort((a, b) => a.order.compareTo(b.order));
    _actions = [for (final m in out) ...m.quickActions];
    _patientActions = [for (final m in out) ...m.patientActions]..sort((a, b) => a.order.compareTo(b.order));
    notifyListeners();
  }

  List<ModuleRoute> _routes = const [];
  List<(HmsModule, HmsAgent)> _agents = const [];
  List<DashboardCard> _cards = const [];
  List<TourStep> _steps = const [];
  List<PatientTab> _tabs = const [];
  List<QuickAction> _actions = const [];
  List<PatientAction> _patientActions = const [];

  /// Modules that would stop working if [id] were switched off.
  List<HmsModule> dependents(String id) => _active.where((m) => m.dependsOn.contains(id)).toList();

  List<ModuleRoute> get routes => _routes;

  ModuleRoute? route(String id) {
    for (final r in routes) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<(HmsModule, HmsAgent)> get agents => _agents;
  List<DashboardCard> get dashboardCards => _cards;
  List<TourStep> get tourSteps => _steps;
  List<PatientTab> get patientTabs => _tabs;
  List<QuickAction> get quickActions => _actions;
  List<PatientAction> get patientActions => _patientActions;

  ProposalHandler? proposalHandler(String key) {
    for (final m in _active) {
      final h = m.proposalHandlers[key];
      if (h != null) return h;
    }
    return null;
  }

  ApprovalHandler? approvalHandler(String type) {
    for (final m in _active) {
      final h = m.approvalHandlers[type];
      if (h != null) return h;
    }
    return null;
  }

  /// Every permission any installed module declares (installed, not just active,
  /// so roles keep their grants while a module is switched off).
  List<PermissionDef> get allPermissions => [...CorePerms.defs, for (final m in all) ...m.permissions];

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }
}

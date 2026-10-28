import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../modules/registry.dart';

/// Moves between screens. Top-level screens (the ones in the sidebar /
/// bottom bar) are switched; detail screens are pushed inside the content
/// area so the navigation stays visible on desktop.
class AppNavigator extends ChangeNotifier {
  AppNavigator(this.registry, this.auth);
  final ModuleRegistry registry;
  final AuthService auth;

  final contentKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  String? _current;
  Map<String, Object?> _args = const {};

  String? get current => _current;
  Map<String, Object?> get args => _args;

  bool canOpen(String routeId) {
    final r = registry.route(routeId);
    return r != null && (r.permission == null || auth.can(r.permission!));
  }

  /// Switch to a top-level screen.
  void select(String routeId, [Map<String, Object?> args = const {}]) {
    _current = routeId;
    _args = args;
    contentKey.currentState?.popUntil((r) => r.isFirst);
    notifyListeners();
  }

  /// Open any screen by id, e.g. `open('patients.profile', {'id': p.id})`.
  /// Shows a message instead if the module is switched off or the user
  /// lacks access.
  Future<T?> open<T>(String routeId, [Map<String, Object?> args = const {}]) async {
    final r = registry.route(routeId);
    if (r == null) {
      toast('That feature is not switched on for this hospital');
      return null;
    }
    if (r.permission != null && !auth.can(r.permission!)) {
      toast('You do not have access to ${r.title}');
      return null;
    }
    if (r.showInNav) {
      select(routeId, args);
      return null;
    }
    final nav = contentKey.currentState;
    if (nav == null) return null;
    return nav.push<T>(MaterialPageRoute(
      settings: RouteSettings(name: routeId, arguments: args),
      builder: (c) => r.builder(c, args),
    ));
  }

  void toast(String message, {bool error = false}) {
    final m = messengerKey.currentState;
    if (m == null) return;
    final screen = MediaQuery.maybeSizeOf(m.context)?.width ?? 800;
    m
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? Colors.red.shade800 : null,
        width: screen < 520 ? null : 420,
      ));
  }
}

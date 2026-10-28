import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/app.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';

import '../helpers.dart';
import 'shots.dart';

/// A screen to capture: file name, route id, and how to find its arguments.
class ShotSpec {
  const ShotSpec(this.name, this.routeId, {this.args, this.after});
  final String name;
  final String routeId;
  final Future<Map<String, Object?>> Function(AppServices app)? args;

  /// Optional extra interaction before the screenshot (tap a tab, open a dialog).
  final Future<void> Function(WidgetTester tester, AppServices app)? after;
}

/// Boots the demo hospital with [modules], signs in as [username] and saves
/// one PNG per [specs] entry to build/screens/PREFIX_NAME.png.
///
/// ```dart
/// testWidgets('billing desktop', (t) => captureScreens(t,
///     prefix: 'billing_desktop', size: const Size(1440, 900),
///     modules: [PatientsModule(), BillingModule()],
///     specs: [ShotSpec('desk', 'billing.desk')]));
/// ```
Future<void> captureScreens(
  WidgetTester tester, {
  required String prefix,
  required Size size,
  required List<HmsModule> modules,
  required List<ShotSpec> specs,
  String username = 'owner',
  bool includeLoginAndTour = false,
}) async {
  // Real shadows in screenshots; restored before the test ends.
  debugDisableShadows = false;
  try {
    await _capture(tester, prefix, size, modules, specs, username, includeLoginAndTour);
  } finally {
    debugDisableShadows = true;
  }
}

Future<void> _capture(WidgetTester tester, String prefix, Size size, List<HmsModule> modules, List<ShotSpec> specs,
    String username, bool includeLoginAndTour) async {
  setSize(tester, size);
  final app = (await tester.runAsync(() => bootTestHospital(modules, demo: true)))!;
  // Run the agents once (for findings), then stop their timers.
  app.agents?.dispose();
  await tester.runAsync(() => app.agents!.runAll());
  if (!includeLoginAndTour) {
    // Mark every tour step as seen so it does not cover the screens.
    await tester.runAsync(() async {
      await app.auth.login(username, demoPassword);
      await app.savePrefs({'seen_tour_steps': app.tourSteps().map((s) => s.id).toList()});
    });
  }

  await tester.pumpWidget(RepaintBoundary(key: shotKey, child: KendraApp(modules: modules, services: app)));
  await tester.pump(const Duration(milliseconds: 300));
  if (includeLoginAndTour) {
    await shot(tester, '${prefix}_login');
    await tester.runAsync(() => app.auth.login(username, demoPassword));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 3 && app.tour.active; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      await shot(tester, '${prefix}_tour_${i + 1}');
      app.tour.next();
      await tester.pump(const Duration(milliseconds: 500));
    }
    if (app.tour.active) app.tour.finish();
  }
  await tester.pump(const Duration(milliseconds: 500));

  for (final spec in specs) {
    final route = app.registry.route(spec.routeId);
    if (route == null) throw StateError('No route ${spec.routeId}');
    final args = spec.args == null ? const <String, Object?>{} : (await tester.runAsync(() => spec.args!(app)))!;
    final home = app.registry.routes.firstWhere((r) => r.showInNav && (r.permission == null || app.auth.can(r.permission!)));
    app.nav.select(route.showInNav ? route.id : home.id, route.showInNav ? args : const {});
    await tester.pump();
    if (!route.showInNav) app.nav.open(spec.routeId, args);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    if (spec.after != null) {
      await spec.after!(tester, app);
      await tester.pump(const Duration(milliseconds: 600));
    }
    await shot(tester, '${prefix}_${spec.name}');
  }

  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => app.close());
}

const desktopSize = Size(1440, 900);
const tabletSize = Size(900, 1200);
const phoneSize = Size(400, 860);

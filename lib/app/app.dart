import 'package:flutter/material.dart';

import '../core/contracts/collections.dart';
import '../core/modules/module.dart';
import '../core/services/app_services.dart';
import '../core/services/device_config.dart';
import '../core/setup/login_screen.dart';
import '../core/setup/setup_service.dart';
import '../core/setup/setup_wizard.dart';
import '../core/shell/app_shell.dart';
import '../core/ui/theme.dart';
import '../core/ui/widgets.dart';

/// Root widget: first-run setup, then sign-in, then the app shell.
class KendraApp extends StatefulWidget {
  const KendraApp({super.key, required this.modules, this.dataDir, this.services});
  final List<HmsModule> modules;

  /// Already-started services (tests and screenshots).
  final AppServices? services;

  /// Overrides where data is kept (tests).
  final String? dataDir;

  @override
  State<KendraApp> createState() => _KendraAppState();
}

class _KendraAppState extends State<KendraApp> {
  DeviceConfig? _config;
  AppServices? _services;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.services != null) {
      _services = widget.services!..requestRestart = _restart;
      _config = widget.services!.config;
    } else {
      _start();
    }
  }

  Future<void> _start() async {
    try {
      final config = await DeviceConfig.load(dataDir: widget.dataDir);
      AppServices? services;
      if (config.configured) {
        services = await AppServices.boot(config, widget.modules);
        if (services.isDataHost && !services.settings.flag(SettingKeys.setupComplete)) {
          // Setup was interrupted; start it again.
          await services.close();
          await config.reset();
          services = null;
        }
      }
      setState(() {
        _config = config;
        _services = services?..requestRestart = _restart;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _restart() async {
    final s = _services;
    setState(() {
      _services = null;
      _config = null;
    });
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    await _start();
  }

  @override
  void dispose() {
    _services?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    if (services == null) {
      return MaterialApp(
        title: 'Kendra HMS',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: _error != null
            ? Scaffold(body: ErrorView(_error!, onRetry: _start))
            : _config == null
                ? const Scaffold(body: LoadingView())
                : SetupWizard(
                    config: _config!,
                    modules: widget.modules,
                    onDone: (s) => setState(() => _services = s..requestRestart = _restart),
                  ),
      );
    }
    return AppScope(
      services: services,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: services.themeMode,
        builder: (context, mode, _) => MaterialApp(
          title: services.settings.hospitalName,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: mode,
          scaffoldMessengerKey: services.nav.messengerKey,
          home: _AuthGate(onRestart: _restart),
        ),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate({required this.onRestart});
  final Future<void> Function() onRestart;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app.auth,
      builder: (context, _) {
        if (app.auth.signedIn) return const AppShell();
        return LoginScreen(
          onLeaveDemo: app.isDemo
              ? () async {
                  await SetupService.leaveDemo(app);
                  await onRestart();
                }
              : null,
          onDisconnect: app.remote != null
              ? () async {
                  await SetupService.disconnectClient(app);
                  await onRestart();
                }
              : null,
        );
      },
    );
  }
}

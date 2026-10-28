import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/remote/remote_store.dart';
import '../services/app_services.dart';
import '../ui/format.dart';
import '../ui/forms.dart';
import '../ui/tokens.dart';
import 'setup_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.onLeaveDemo, this.onDisconnect});

  /// Demo only: wipe the demo and start real setup.
  final VoidCallback? onLeaveDemo;

  /// Client only: forget this hub and choose again.
  final VoidCallback? onDisconnect;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  bool _show = false;
  bool _busy = false;
  String? _error;
  String? _hubName;
  String? _hubError;

  /// While the hub is unreachable, try again every 2 minutes.
  Timer? _retry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.app;
    final locked = app.auth.lockedUsername;
    if (locked != null && _user.text.isEmpty) {
      _user.text = locked;
      WidgetsBinding.instance.addPostFrameCallback((_) => _passFocus.requestFocus());
    }
    if (app.remote != null && _hubName == null && _hubError == null) _probe();
  }

  Future<void> _probe() async {
    final app = context.app;
    _retry?.cancel();
    setState(() => _hubError = null);
    try {
      final name = await probeHub(app.config.hubUrl!, app.config.networkKey!);
      if (mounted) setState(() => _hubName = name);
    } on HubUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _hubError = '${e.message} Trying again every 2 minutes.');
      _retry = Timer(const Duration(minutes: 2), _probe);
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _login([String? username, String? password]) async {
    final app = context.app;
    final u = username ?? _user.text;
    final p = password ?? _pass.text;
    if (u.trim().isEmpty || p.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.auth.login(u, p);
      await app.afterLogin();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on HubUnavailableException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final hospital = app.remote != null ? (_hubName ?? 'Connecting to your hospital…') : app.settings.hospitalName;
    final locked = app.auth.lockedUsername;

    final form = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[
              _Mark(size: 48),
              Gap.v16,
              Text(hospital, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              Gap.v24,
            ],
            Text(locked != null ? 'Screen locked' : 'Sign in', style: theme.textTheme.headlineSmall),
            Gap.v4,
            Text(
              locked != null ? 'Enter your password to continue.' : 'Use the account your administrator gave you.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gap.v24,
            if (_hubError != null) ...[
              _Banner(
                icon: Icons.cloud_off,
                text: _hubError!,
                action: TextButton(onPressed: _probe, child: const Text('Retry')),
              ),
              Gap.v16,
            ],
            AppTextField(
              label: 'Username',
              controller: _user,
              prefixIcon: Icons.person_outline,
              autofocus: locked == null,
              onSubmitted: (_) => _passFocus.requestFocus(),
            ),
            Gap.v12,
            TextField(
              controller: _pass,
              focusNode: _passFocus,
              obscureText: !_show,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _login(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _show ? 'Hide password' : 'Show password',
                  icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            if (_error != null) ...[
              Gap.v12,
              Text(_error!, style: TextStyle(color: cs.error)),
            ],
            Gap.v24,
            FilledButton(
              onPressed: _busy ? null : () => _login(),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
            if (locked != null)
              TextButton(
                onPressed: () {
                  app.auth.logout();
                  _user.clear();
                  _pass.clear();
                },
                child: const Text('Not you? Sign in as someone else'),
              ),
            if (app.isDemo) ...[Gap.v24, _DemoAccounts(onPick: (u) => _login(u, demoPassword))],
            Gap.v24,
            if (widget.onLeaveDemo != null)
              TextButton.icon(
                onPressed: widget.onLeaveDemo,
                icon: const Icon(Icons.logout),
                label: const Text('Leave the demo and set up my hospital'),
              ),
            if (widget.onDisconnect != null)
              TextButton.icon(
                onPressed: widget.onDisconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Connect to a different hub'),
              ),
          ],
        ),
      ),
    );

    if (!wide) {
      return Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: form))));
    }
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 5,
            child: Container(
              color: cs.primary,
              padding: const EdgeInsets.all(48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Mark(size: 44, inverted: true),
                  const Spacer(),
                  Text(hospital,
                      style: theme.textTheme.headlineMedium?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w700)),
                  Gap.v12,
                  Text(
                    'Registration, consultations, billing, pharmacy and lab in one place. '
                    'Monitoring agents check every bill and stock movement, and your board decides.',
                    style: theme.textTheme.titleMedium?.copyWith(color: cs.onPrimary.withValues(alpha: 0.85), fontWeight: FontWeight.w400),
                  ),
                  const Spacer(),
                  Text(
                    app.isDemo
                        ? 'Demo hospital · sample data only'
                        : app.remote != null
                            ? 'Connected to ${app.config.hubUrl}'
                            : 'Data stays on this device',
                    style: theme.textTheme.labelLarge?.copyWith(color: cs.onPrimary.withValues(alpha: 0.75)),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(48), child: form)),
          ),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.size, this.inverted = false});
  final double size;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: inverted ? Alignment.centerLeft : Alignment.center,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: inverted ? cs.onPrimary : cs.primary,
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: Icon(Icons.local_hospital_outlined, size: size * 0.58, color: inverted ? cs.primary : cs.onPrimary),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, Tone.danger);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: c.border)),
      child: Row(children: [
        Icon(icon, color: c.foreground),
        Gap.h12,
        Expanded(child: Text(text, style: TextStyle(color: c.foreground))),
        ?action,
      ]),
    );
  }
}

class _DemoAccounts extends StatelessWidget {
  const _DemoAccounts({required this.onPick});
  final void Function(String username) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Try a role', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
          Gap.v4,
          Text('Every demo account uses the password $demoPassword.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
          Gap.v12,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (u, name, roles, _) in demoStaff)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text('${titleCase(roles.first)} · ${name.replaceFirst('Dr. ', '').split(' ').first}'),
                  onPressed: () => onPick(u),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/password.dart';
import '../modules/module.dart';
import '../services/app_services.dart';
import '../services/device_config.dart';
import '../ui/forms.dart';
import '../ui/tokens.dart';
import 'setup_service.dart';

enum _Path { none, hospital, join, demo }

/// First launch on a device. Walks the person through one of three paths
/// and hands back a ready [AppServices].
class SetupWizard extends StatefulWidget {
  const SetupWizard({super.key, required this.config, required this.modules, required this.onDone});
  final DeviceConfig config;
  final List<HmsModule> modules;
  final void Function(AppServices services) onDone;

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  _Path _path = _Path.none;
  int _step = 0;
  bool _busy = false;
  String? _error;

  // Hospital
  final _hospitalForm = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _gstin = TextEditingController();
  final _prefix = TextEditingController();
  bool _prefixTouched = false;

  // Owner
  final _ownerForm = GlobalKey<FormState>();
  final _ownerName = TextEditingController();
  final _ownerUser = TextEditingController(text: 'owner');
  final _ownerPass = TextEditingController();
  final _ownerPass2 = TextEditingController();

  // Modules and network
  late final Set<String> _enabled = {for (final m in widget.modules) if (m.enabledByDefault || m.required) m.id};
  bool _hub = false;

  // Join
  final _joinForm = GlobalKey<FormState>();
  final _hubUrl = TextEditingController();
  final _hubKey = TextEditingController();
  final _deviceName = TextEditingController(text: Platform.localHostname);

  @override
  void dispose() {
    for (final c in [_name, _address, _phone, _gstin, _prefix, _ownerName, _ownerUser, _ownerPass, _ownerPass2, _hubUrl, _hubKey, _deviceName]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _titles => switch (_path) {
        _Path.hospital => ['Hospital', 'Your account', 'Modules', 'Other devices'],
        _Path.join => ['Connect'],
        _ => const [],
      };

  Future<void> _run(Future<AppServices> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await action();
      widget.onDone(s);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _next() {
    setState(() => _error = null);
    if (_path == _Path.hospital) {
      if (_step == 0 && !_hospitalForm.currentState!.validate()) return;
      if (_step == 1 && !_ownerForm.currentState!.validate()) return;
      if (_step == 3) {
        _run(() => SetupService.createHospital(
              config: widget.config,
              modules: widget.modules,
              details: HospitalDetails(
                name: _name.text,
                address: _address.text,
                phone: _phone.text,
                gstin: _gstin.text,
                uhidPrefix: _prefix.text,
              ),
              owner: OwnerAccount(displayName: _ownerName.text, username: _ownerUser.text, password: _ownerPass.text),
              enabledModules: _enabled,
              hubEnabled: _hub,
            ));
        return;
      }
      setState(() => _step++);
    } else if (_path == _Path.join) {
      if (!_joinForm.currentState!.validate()) return;
      _run(() => SetupService.joinHub(
            config: widget.config,
            modules: widget.modules,
            hubUrl: _hubUrl.text,
            networkKey: _hubKey.text,
            deviceName: _deviceName.text,
          ));
    }
  }

  void _back() {
    setState(() {
      _error = null;
      if (_step > 0) {
        _step--;
      } else {
        _path = _Path.none;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = context.isCompact;
    final Widget body = switch (_path) {
      _Path.none => _choose(theme),
      _Path.hospital => [_hospitalStep(), _ownerStep(), _modulesStep(theme), _networkStep(theme)][_step],
      _Path.join => _joinStep(theme),
      _Path.demo => const SizedBox.shrink(),
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 16 : 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(compact ? 20 : 36),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(11)),
                          child: Icon(Icons.local_hospital_outlined, color: theme.colorScheme.onPrimary),
                        ),
                        Gap.h12,
                        Text('Kendra HMS', style: theme.textTheme.titleLarge),
                      ]),
                      Gap.v24,
                      if (_titles.length > 1) ...[_Stepper(titles: _titles, index: _step), Gap.v24],
                      body,
                      if (_error != null) ...[
                        Gap.v16,
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      if (_path == _Path.hospital || _path == _Path.join) ...[
                        Gap.v24,
                        Row(children: [
                          TextButton(onPressed: _busy ? null : _back, child: const Text('Back')),
                          const Spacer(),
                          FilledButton(
                            onPressed: _busy ? null : _next,
                            child: _busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_path == _Path.join
                                    ? 'Connect'
                                    : _step == 3
                                        ? 'Create hospital'
                                        : 'Continue'),
                          ),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choose(ThemeData theme) {
    Widget option(IconData icon, String title, String body, VoidCallback onTap, {bool primary = false}) {
      final cs = theme.colorScheme;
      return Card(
        color: primary ? cs.primaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Icon(icon, size: 30, color: primary ? cs.onPrimaryContainer : cs.primary),
              Gap.h16,
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  Gap.v4,
                  Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Welcome. How will this device be used?', style: theme.textTheme.headlineSmall),
        Gap.v8,
        Text('You can change this later.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Gap.v24,
        option(Icons.domain_add_outlined, 'Set up a new hospital',
            'This device will keep the hospital\'s records. Other computers and tablets can connect to it later.',
            () => setState(() {
                  _path = _Path.hospital;
                  _step = 0;
                }),
            primary: true),
        Gap.v12,
        option(Icons.lan_outlined, 'Connect to my hospital',
            'Your hospital already uses Kendra on a main computer. Connect this device to it over the local network.',
            () => setState(() => _path = _Path.join)),
        Gap.v12,
        option(Icons.science_outlined, 'Explore a demo hospital',
            'Sample patients, bills and stock so you can try every screen. Nothing you do affects real data.',
            () => _run(() => SetupService.createDemo(config: widget.config, modules: widget.modules))),
        if (_busy) ...[Gap.v24, const Center(child: CircularProgressIndicator())],
      ],
    );
  }

  Widget _hospitalStep() => Form(
        key: _hospitalForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _StepIntro('About your hospital', 'This appears on bills, prescriptions and reports.'),
            FormGrid(maxColumns: 2, children: [
              FullWidth(
                child: AppTextField(
                  label: 'Hospital name',
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.required('Hospital name'),
                  onChanged: (v) {
                    if (!_prefixTouched) _prefix.text = SetupService.suggestPrefix(v);
                  },
                ),
              ),
              FullWidth(child: AppTextField(label: 'Address', controller: _address, maxLines: 2)),
              AppTextField(label: 'Phone', controller: _phone, keyboardType: TextInputType.phone),
              AppTextField(label: 'GSTIN (optional)', controller: _gstin, textCapitalization: TextCapitalization.characters),
              AppTextField(
                label: 'Patient ID prefix',
                controller: _prefix,
                helper: 'Patient IDs will look like ${_prefix.text.isEmpty ? 'SMH' : _prefix.text.toUpperCase()}-26-000123',
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() => _prefixTouched = true),
                validator: (v) => (v == null || !RegExp(r'^[A-Za-z]{1,5}$').hasMatch(v.trim())) ? 'Use 1–5 letters' : null,
              ),
            ]),
          ],
        ),
      );

  Widget _ownerStep() => Form(
        key: _ownerForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _StepIntro('Your account', 'You will be the owner, with access to everything. Add other staff after setup.'),
            FormGrid(maxColumns: 2, children: [
              FullWidth(
                child: AppTextField(
                  label: 'Your full name',
                  controller: _ownerName,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.required('Name'),
                ),
              ),
              AppTextField(label: 'Username', controller: _ownerUser, validator: (v) => usernameProblem(v ?? '')),
              const SizedBox.shrink(),
              AppTextField(
                label: 'Password',
                controller: _ownerPass,
                obscure: true,
                helper: 'At least 8 characters, with letters and a number',
                validator: (v) => passwordProblem(v ?? ''),
              ),
              AppTextField(
                label: 'Password again',
                controller: _ownerPass2,
                obscure: true,
                validator: (v) => v != _ownerPass.text ? 'The passwords do not match' : null,
              ),
            ]),
          ],
        ),
      );

  Widget _modulesStep(ThemeData theme) {
    final byId = {for (final m in widget.modules) m.id: m};
    void toggle(HmsModule m, bool on) {
      setState(() {
        if (on) {
          _enabled.add(m.id);
          _enabled.addAll(m.dependsOn);
        } else {
          _enabled.remove(m.id);
          // Switch off anything that needed it.
          for (final other in widget.modules) {
            if (other.dependsOn.contains(m.id)) _enabled.remove(other.id);
          }
        }
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepIntro('What do you want to use?',
            'Start with what you need. You can switch modules on or off at any time in Administration.'),
        for (final m in widget.modules)
          CheckboxListTile(
            value: m.required || _enabled.contains(m.id),
            onChanged: m.required ? null : (v) => toggle(m, v ?? false),
            secondary: Icon(m.icon),
            title: Text(m.name),
            subtitle: Text([
              m.description,
              if (m.dependsOn.isNotEmpty) 'Needs ${m.dependsOn.map((d) => byId[d]?.name ?? d).join(', ')}.',
              if (m.required) 'Always on.',
            ].join(' ')),
          ),
      ],
    );
  }

  Widget _networkStep(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _StepIntro('Will other devices use this data?',
              'Reception PCs, doctors\' laptops and Android tablets on the same Wi-Fi or LAN can connect to this device. '
                  'Nothing goes over the internet.'),
          SwitchListTile(
            value: _hub,
            onChanged: (v) => setState(() => _hub = v),
            title: const Text('Share with other devices on the hospital network'),
            subtitle: const Text('Turns this device into the hospital\'s hub. Keep it switched on during working hours. '
                'You will get a network key to enter on the other devices.'),
          ),
          Gap.v12,
          Text('You can change this later in Administration → Network.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _joinStep(ThemeData theme) => Form(
        key: _joinForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _StepIntro('Connect to your hospital',
                'On the main computer, open Administration → Network to see its address and network key.'),
            FormGrid(maxColumns: 2, children: [
              AppTextField(
                label: 'Hub address',
                controller: _hubUrl,
                hint: '192.168.1.20',
                autofocus: true,
                keyboardType: TextInputType.url,
                validator: Validators.required('Hub address'),
              ),
              AppTextField(
                label: 'Network key',
                controller: _hubKey,
                hint: 'ABCD-EFGH-JKLM',
                textCapitalization: TextCapitalization.characters,
                validator: Validators.required('Network key'),
              ),
              AppTextField(label: 'Name for this device', controller: _deviceName, helper: 'e.g. Reception 2'),
            ]),
          ],
        ),
      );
}

class _StepIntro extends StatelessWidget {
  const _StepIntro(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: theme.textTheme.headlineSmall),
        Gap.v8,
        Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.titles, required this.index});
  final List<String> titles;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        for (var i = 0; i < titles.length; i++) ...[
          if (i > 0) Expanded(child: Divider(color: i <= index ? cs.primary : cs.outlineVariant, thickness: 2)),
          CircleAvatar(
            radius: 13,
            backgroundColor: i <= index ? cs.primary : cs.surfaceContainerHigh,
            child: i < index
                ? Icon(Icons.check, size: 16, color: cs.onPrimary)
                : Text('${i + 1}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: i <= index ? cs.onPrimary : cs.onSurfaceVariant)),
          ),
          if (!context.isCompact) ...[
            Gap.h8,
            Text(titles[i], style: theme.textTheme.labelLarge?.copyWith(color: i == index ? cs.onSurface : cs.onSurfaceVariant)),
          ],
        ],
      ],
    );
  }
}

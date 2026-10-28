import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

/// Hospital-wide settings: profile, patient IDs, approvals and security.
class HospitalSettingsScreen extends StatefulWidget {
  const HospitalSettingsScreen({super.key});

  @override
  State<HospitalSettingsScreen> createState() => _HospitalSettingsScreenState();
}

class _HospitalSettingsScreenState extends State<HospitalSettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _gstin = TextEditingController();
  final _prefix = TextEditingController();
  final _highValue = TextEditingController();
  int _idleMinutes = 15;
  int _briefingHour = 8;
  bool _loaded = false;
  bool _saving = false;

  static const _idleChoices = [0, 5, 10, 15, 30, 60];
  static final _gstinPattern = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final s = context.app.settings;
    _name.text = s.hospitalName;
    _address.text = s.str(SettingKeys.hospitalAddress);
    _phone.text = s.str(SettingKeys.hospitalPhone);
    _gstin.text = s.str(SettingKeys.hospitalGstin);
    _prefix.text = s.str(SettingKeys.uhidPrefix, 'H');
    _highValue.text = moneyInput(s.highValueLimitPaise);
    _idleMinutes = s.idleLockMinutes;
    _briefingHour = s.briefingHour;
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _phone, _gstin, _prefix, _highValue]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.app;
    setState(() => _saving = true);
    await runGuarded(
      context,
      () => app.settings.setAll(context.db, {
        SettingKeys.hospitalName: _name.text.trim(),
        SettingKeys.hospitalAddress: _address.text.trim(),
        SettingKeys.hospitalPhone: _phone.text.trim(),
        SettingKeys.hospitalGstin: _gstin.text.trim().toUpperCase(),
        SettingKeys.uhidPrefix: _prefix.text.trim().toUpperCase(),
        SettingKeys.highValueLimitPaise: parseMoney(_highValue.text) ?? app.settings.highValueLimitPaise,
        SettingKeys.idleLockMinutes: _idleMinutes,
        SettingKeys.briefingHour: _briefingHour,
      }),
      success: 'Settings saved',
    );
    if (mounted) setState(() => _saving = false);
  }

  static String _hour(int h) => '${h % 12 == 0 ? 12 : h % 12}:00 ${h < 12 ? 'AM' : 'PM'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final prefix = _prefix.text.trim().isEmpty ? 'H' : _prefix.text.trim().toUpperCase();
    final yy = (DateTime.now().year % 100).toString().padLeft(2, '0');

    return PageScaffold(
      title: 'Hospital settings',
      subtitle: 'How your hospital appears on bills and reports, and a few rules everyone follows',
      maxWidth: 980,
      primaryAction: PageAction('Save settings', Icons.check, _saving ? null : _save),
      body: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              title: 'Hospital profile',
              subtitle: 'Printed on bills, receipts, prescriptions and reports',
              child: FormGrid(maxColumns: 2, children: [
                AppTextField(
                  label: 'Hospital name',
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.required('Hospital name'),
                ),
                AppTextField(label: 'Phone', controller: _phone, keyboardType: TextInputType.phone, prefixIcon: Icons.phone_outlined),
                FullWidth(child: AppTextField(label: 'Address', controller: _address, maxLines: 2)),
                AppTextField(
                  label: 'GSTIN (optional)',
                  controller: _gstin,
                  textCapitalization: TextCapitalization.characters,
                  hint: 'e.g. 27AABCS1429B1Z5',
                  validator: (v) {
                    final s = (v ?? '').trim().toUpperCase();
                    if (s.isEmpty || _gstinPattern.hasMatch(s)) return null;
                    return 'A GSTIN has 15 characters, like 27AABCS1429B1Z5';
                  },
                ),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Patient IDs',
              subtitle: 'Every patient gets a UHID when they are registered',
              child: FormGrid(maxColumns: 2, children: [
                AppTextField(
                  label: 'UHID prefix',
                  controller: _prefix,
                  textCapitalization: TextCapitalization.characters,
                  helper: 'New patients get IDs like $prefix-$yy-000124. Existing IDs do not change.',
                  onChanged: (_) => setState(() {}),
                  validator: (v) => RegExp(r'^[A-Za-z0-9]{1,6}$').hasMatch((v ?? '').trim())
                      ? null
                      : 'Use 1–6 letters or numbers, e.g. SMH',
                ),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Approvals',
              subtitle: 'Discounts, refunds and write-offs above a person\'s own limit go to the board',
              child: FormGrid(maxColumns: 2, children: [
                MoneyField(
                  label: 'High-value limit',
                  controller: _highValue,
                  required: true,
                  helper: 'Above this, two different board members must approve. Below it, one is enough.',
                ),
              ]),
            ),
            Gap.v16,
            SectionCard(
              title: 'Security and daily briefing',
              child: FormGrid(maxColumns: 2, children: [
                AppDropdown<int>(
                  label: 'Lock an unattended computer after',
                  value: _idleMinutes,
                  helper: 'Hides patient data when nobody has touched the screen. The same person signs back in.',
                  items: [
                    for (final m in {..._idleChoices, _idleMinutes}.toList()..sort())
                      (m, m == 0 ? 'Never (not recommended)' : '$m minutes'),
                  ],
                  onChanged: (v) => setState(() => _idleMinutes = v ?? _idleMinutes),
                ),
                AppDropdown<int>(
                  label: 'Morning briefing at',
                  value: _briefingHour,
                  helper: 'When the board gets the daily summary of what the agents found.',
                  items: [for (final h in {for (var h = 5; h <= 12; h++) h, _briefingHour}.toList()..sort()) (h, _hour(h))],
                  onChanged: (v) => setState(() => _briefingHour = v ?? _briefingHour),
                ),
              ]),
            ),
            Gap.v24,
            if (!context.isCompact)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Save settings'),
                ),
              ),
            Gap.v8,
            Text('Changes apply on every device straight away.', style: muted),
          ],
        ),
      ),
    );
  }
}

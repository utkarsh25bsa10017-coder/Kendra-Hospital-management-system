import 'dart:io';

import '../auth/auth_service.dart';
import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../data/remote/remote_store.dart';
import '../modules/module.dart';
import '../services/app_services.dart';
import '../services/device_config.dart';

class HospitalDetails {
  const HospitalDetails({required this.name, this.address = '', this.phone = '', this.gstin = '', required this.uhidPrefix});
  final String name;
  final String address;
  final String phone;
  final String gstin;
  final String uhidPrefix;
}

class OwnerAccount {
  const OwnerAccount({required this.displayName, required this.username, required this.password});
  final String displayName;
  final String username;
  final String password;
}

const demoPassword = 'demo1234';

/// Sample staff for the demo hospital: (username, name, roles, extra fields).
const demoStaff = <(String, String, List<String>, Map<String, Object?>)>[
  ('owner', 'Dr. Anjali Mehta', [Roles.owner], {'is_clinician': false}),
  ('admin', 'Rahul Verma', [Roles.admin], {}),
  ('board', 'Dr. Suresh Iyer', [Roles.board, Roles.doctor],
      {'is_clinician': true, 'department': 'General Medicine', 'specialization': 'Physician', 'consultation_fee_paise': 60000}),
  ('drkhan', 'Dr. Farah Khan', [Roles.doctor],
      {'is_clinician': true, 'department': 'Paediatrics', 'specialization': 'Paediatrician', 'consultation_fee_paise': 50000}),
  ('drnair', 'Dr. Arjun Nair', [Roles.doctor],
      {'is_clinician': true, 'department': 'Orthopaedics', 'specialization': 'Orthopaedic surgeon', 'consultation_fee_paise': 70000}),
  ('reception', 'Priya Sharma', [Roles.receptionist], {}),
  ('billing', 'Vikram Singh', [Roles.billing], {'discount_limit_paise': 50000}),
  ('pharmacy', 'Neha Gupta', [Roles.pharmacist], {}),
  ('lab', 'Imran Sheikh', [Roles.labTech], {}),
  ('pathology', 'Dr. Kavita Rao', [Roles.pathologist], {}),
  ('nurse', 'Mary Thomas', [Roles.nurse], {}),
  ('accounts', 'Sanjay Patil', [Roles.accountant], {}),
];

/// First-run actions. Each returns a ready [AppServices].
abstract final class SetupService {
  static String suggestPrefix(String hospitalName) {
    final words = hospitalName
        .replaceAll(RegExp(r'[^A-Za-z ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !{'hospital', 'and', 'the', 'of', 'pvt', 'ltd'}.contains(w.toLowerCase()))
        .toList();
    final p = words.take(3).map((w) => w[0].toUpperCase()).join();
    return p.isEmpty ? 'H' : p;
  }

  static Future<AppServices> createHospital({
    required DeviceConfig config,
    required List<HmsModule> modules,
    required HospitalDetails details,
    required OwnerAccount owner,
    required Set<String> enabledModules,
    bool hubEnabled = false,
  }) async {
    config.mode = DeviceMode.main;
    config.hubEnabled = false;
    await config.save();
    final app = await AppServices.boot(config, modules);
    await app.settings.setAll(app.systemDb, {
      SettingKeys.hospitalName: details.name.trim(),
      SettingKeys.hospitalAddress: details.address.trim(),
      SettingKeys.hospitalPhone: details.phone.trim(),
      SettingKeys.hospitalGstin: details.gstin.trim(),
      SettingKeys.uhidPrefix: details.uhidPrefix.trim().toUpperCase(),
      SettingKeys.modulesEnabled: enabledModules.toList(),
    });
    try {
      await (app.auth.backend as LocalAuthBackend).createUser(
        null,
        {
          'username': owner.username,
          'display_name': owner.displayName.trim(),
          'role_ids': [Roles.owner],
          'must_change_password': false,
        },
        owner.password,
      );
    } catch (_) {
      await app.close();
      await config.reset();
      rethrow;
    }
    await app.settings.set(app.systemDb, SettingKeys.setupComplete, true);
    await app.seedModules();
    if (hubEnabled) await app.startHub();
    return app;
  }

  static Future<AppServices> createDemo({required DeviceConfig config, required List<HmsModule> modules}) async {
    config.mode = DeviceMode.demo;
    await config.save();
    await _deleteDb(await config.databasePath());
    final app = await AppServices.boot(config, modules);
    await app.settings.setAll(app.systemDb, {
      SettingKeys.hospitalName: 'Sunrise Multispeciality Hospital',
      SettingKeys.hospitalAddress: '14 MG Road, Pune 411001',
      SettingKeys.hospitalPhone: '020 2555 0101',
      SettingKeys.uhidPrefix: 'SMH',
      SettingKeys.idleLockMinutes: 0,
    });
    final auth = app.auth.backend as LocalAuthBackend;
    for (final (username, name, roles, extra) in demoStaff) {
      await auth.createUser(
        null,
        {'username': username, 'display_name': name, 'role_ids': roles, 'must_change_password': false, ...extra},
        demoPassword,
      );
    }
    for (final m in app.registry.active) {
      await m.seedDemo(ModuleContext(app, m));
    }
    await app.settings.set(app.systemDb, SettingKeys.setupComplete, true);
    return app;
  }

  /// Accepts "192.168.1.20", "192.168.1.20:8787" or a full URL.
  static String normalizeHubUrl(String input, {int port = 8787}) {
    var s = input.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    final u = Uri.parse(s);
    return '${u.scheme}://${u.host}:${u.hasPort ? u.port : port}';
  }

  static Future<AppServices> joinHub({
    required DeviceConfig config,
    required List<HmsModule> modules,
    required String hubUrl,
    required String networkKey,
    String? deviceName,
  }) async {
    final url = normalizeHubUrl(hubUrl);
    final key = networkKey.trim().toUpperCase();
    await probeHub(url, key);
    config
      ..mode = DeviceMode.client
      ..hubUrl = url
      ..networkKey = key;
    if (deviceName != null && deviceName.trim().isNotEmpty) config.deviceName = deviceName.trim();
    await config.save();
    return AppServices.boot(config, modules);
  }

  /// Deletes the demo database and returns this device to first-run setup.
  static Future<void> leaveDemo(AppServices app) async {
    final path = await app.config.databasePath();
    await app.close();
    await _deleteDb(path);
    await app.config.reset();
  }

  /// Forgets the hub on a client device.
  static Future<void> disconnectClient(AppServices app) async {
    await app.close();
    await app.config.reset();
  }

  static Future<void> _deleteDb(String path) async {
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.deleteSync();
    }
  }
}

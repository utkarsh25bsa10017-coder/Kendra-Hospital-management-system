import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data/record.dart';

/// What this particular device is for. Stored in a small file next to the
/// database, not in the database itself.
enum DeviceMode {
  /// Holds the hospital's data. Can also serve it to other devices (hub).
  main,

  /// Connects to the hub on another device.
  client,

  /// Sample hospital for trying the app; kept in a separate database file.
  demo,
}

class DeviceConfig {
  DeviceConfig({
    required this.deviceId,
    this.mode,
    this.deviceName = '',
    this.hubUrl,
    this.networkKey,
    this.hubEnabled = false,
    this.hubPort = 8787,
    this.themeMode = 'system',
    this.dataDir,
  });

  final String deviceId;

  /// Null until first-run setup is finished.
  DeviceMode? mode;
  String deviceName;

  /// Client devices: where the hub is, e.g. http://192.168.1.20:8787
  String? hubUrl;

  /// Shared secret every device needs to talk to the hub.
  String? networkKey;

  /// Main devices: whether to serve the database to the network.
  bool hubEnabled;
  int hubPort;
  String themeMode;

  /// Overrides the default data folder (used by tests).
  String? dataDir;

  bool get configured => mode != null;
  String get dbFileName => mode == DeviceMode.demo ? 'kendra_demo.db' : 'kendra.db';

  static Future<Directory> defaultDir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}kendra');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> directory() async {
    if (dataDir != null) {
      final d = Directory(dataDir!);
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    return defaultDir();
  }

  Future<String> databasePath() async => '${(await directory()).path}${Platform.pathSeparator}$dbFileName';

  static Future<File> _file(String? dataDir) async {
    final dir = dataDir != null ? Directory(dataDir) : await defaultDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}device.json');
  }

  static Future<DeviceConfig> load({String? dataDir}) async {
    final f = await _file(dataDir);
    if (f.existsSync()) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        return DeviceConfig(
          deviceId: j['deviceId'] as String,
          mode: j['mode'] == null ? null : DeviceMode.values.byName(j['mode'] as String),
          deviceName: (j['deviceName'] as String?) ?? '',
          hubUrl: j['hubUrl'] as String?,
          networkKey: j['networkKey'] as String?,
          hubEnabled: (j['hubEnabled'] as bool?) ?? false,
          hubPort: (j['hubPort'] as int?) ?? 8787,
          themeMode: (j['themeMode'] as String?) ?? 'system',
          dataDir: dataDir,
        );
      } catch (_) {
        // Corrupt file: fall through and start again.
      }
    }
    final c = DeviceConfig(deviceId: newId(), deviceName: Platform.localHostname, dataDir: dataDir);
    await c.save();
    return c;
  }

  Future<void> save() async {
    final f = await _file(dataDir);
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'deviceId': deviceId,
      'mode': mode?.name,
      'deviceName': deviceName,
      'hubUrl': hubUrl,
      'networkKey': networkKey,
      'hubEnabled': hubEnabled,
      'hubPort': hubPort,
      'themeMode': themeMode,
    }));
  }

  /// Back to first-run setup (used when leaving the demo).
  Future<void> reset() async {
    mode = null;
    hubUrl = null;
    networkKey = null;
    hubEnabled = false;
    await save();
  }
}

/// Short human-friendly network key, e.g. "K7QD-82MX-4PAT".
String newNetworkKey() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final t = randomToken(12);
  final sb = StringBuffer();
  for (var i = 0; i < 12; i++) {
    if (i > 0 && i % 4 == 0) sb.write('-');
    sb.write(chars[int.parse(t.substring(i * 2, i * 2 + 2), radix: 16) % chars.length]);
  }
  return sb.toString();
}

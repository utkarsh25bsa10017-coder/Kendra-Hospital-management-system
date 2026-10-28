import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../backup_service.dart';

/// Facts about this installation, for whoever supports the hospital's IT.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  List<(String, String)>? _device;
  List<(String, String)>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_device == null) _load();
  }

  static String _mode(AppServices app) {
    if (app.isDemo) return 'Demo hospital (sample data)';
    if (app.remote != null) return 'Connected device (uses the hub)';
    return (app.hub?.running ?? false) ? 'Main computer, sharing with other devices (hub)' : 'Main computer, this device only';
  }

  Future<void> _load() async {
    final app = context.app;
    final c = app.config;
    final device = <(String, String)>[
      ('Kendra version', app.appVersion),
      ('Mode', _mode(app)),
      ('Device name', c.deviceName.isEmpty ? Platform.localHostname : c.deviceName),
      ('Device ID', c.deviceId),
      ('Operating system', _osVersion()),
      ('Signed in as', context.session == null ? '—' : '${context.session!.displayName} (@${context.session!.username})'),
    ];
    final data = <(String, String)>[('Hospital', app.settings.hospitalName)];
    if (app.local != null) {
      final path = await c.databasePath();
      var size = 0;
      for (final suffix in ['', '-wal']) {
        final f = File('$path$suffix');
        if (f.existsSync()) size += f.lengthSync();
      }
      data.addAll([
        ('Data folder', (await c.directory()).path),
        ('Database file', c.dbFileName),
        ('Database size', Backups.formatSize(size)),
        ('Database ID', app.local!.databaseId),
        ('Backup folder', await Backups.folder(app)),
      ]);
    } else {
      data.addAll([
        ('Hub address', c.hubUrl ?? '—'),
        ('Data kept on', 'The main computer (hub)'),
      ]);
    }
    if (mounted) {
      setState(() {
        _device = device;
        _data = data;
      });
    }
  }

  static String _osVersion() {
    final v = Platform.operatingSystemVersion;
    final name = _os();
    return v.toLowerCase().contains(name.toLowerCase()) ? v : '$name · $v';
  }

  static String _os() => switch (Platform.operatingSystem) {
        'macos' => 'macOS',
        'windows' => 'Windows',
        'android' => 'Android',
        'linux' => 'Linux',
        final o => titleCase(o),
      };

  void _copy() {
    final lines = [for (final (k, v) in [...?_device, ...?_data]) '$k: $v'];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    context.toast('Details copied. Paste them into a message to your IT support.');
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final data = _data;
    return PageScaffold(
      title: 'About this device',
      subtitle: 'Version and setup details. Useful when you ask someone for help.',
      actions: [
        if (device != null)
          context.isCompact
              ? IconButton(tooltip: 'Copy details', icon: const Icon(Icons.copy_outlined), onPressed: _copy)
              : OutlinedButton.icon(onPressed: _copy, icon: const Icon(Icons.copy_outlined, size: 18), label: const Text('Copy details')),
      ],
      body: device == null || data == null
          ? const LoadingView()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionCard(title: 'This device', child: InfoGrid(device, minItemWidth: 260)),
                Gap.v16,
                SectionCard(title: 'Hospital data', child: InfoGrid(data, minItemWidth: 260)),
              ],
            ),
    );
  }
}

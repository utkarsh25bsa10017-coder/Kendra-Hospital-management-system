import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';

import '../backup_service.dart';
import 'admin_widgets.dart';

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key, this.backUpNow = false});

  /// Start a backup as soon as the screen opens (from the command palette).
  final bool backUpNow;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (app.local == null) {
      return const PageScaffold(
        title: 'Backup & restore',
        subtitle: 'Copies of the hospital data, in case a computer fails',
        body: EmptyState(
          icon: Icons.backup_outlined,
          title: 'Backups are made on the main computer',
          message: 'This device keeps no hospital data of its own. The main computer (the hub) holds everything '
              'and backs it up every afternoon. Open this screen on the main computer to back up or restore.',
        ),
      );
    }
    return _HostBackups(backUpNow: backUpNow);
  }
}

class _HostBackups extends StatefulWidget {
  const _HostBackups({required this.backUpNow});
  final bool backUpNow;

  @override
  State<_HostBackups> createState() => _HostBackupsState();
}

class _HostBackupsState extends State<_HostBackups> {
  final _folderCtrl = TextEditingController();
  String _folder = '';
  String _defaultFolder = '';
  List<BackupFile>? _files;
  AuditEntry? _last;
  bool _busy = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _refresh().then((_) {
      if (widget.backUpNow && mounted) _backUp();
    });
  }

  @override
  void dispose() {
    _folderCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final app = context.app;
    final folder = await Backups.folder(app);
    final def = await Backups.defaultFolder(app.config);
    final last = await Backups.lastBackup(app.store);
    final files = Backups.list(folder);
    if (!mounted) return;
    setState(() {
      _folder = folder;
      _defaultFolder = def;
      _last = last;
      _files = files;
      if (_folderCtrl.text.isEmpty) _folderCtrl.text = app.settings.str(Backups.folderKey);
    });
  }

  Future<void> _backUp() async {
    final app = context.app;
    setState(() => _busy = true);
    BackupFile? made;
    await runGuarded(context, () async => made = await Backups.backupNow(app));
    if (!mounted) return;
    setState(() => _busy = false);
    if (made != null) app.nav.toast('Backup saved: ${made!.name} (${Backups.formatSize(made!.size)})');
    await _refresh();
  }

  Future<void> _chooseFolder() async {
    final path = await pickFolder(context);
    if (path == null || !mounted) return;
    _folderCtrl.text = path;
    await _saveFolder();
  }

  Future<void> _saveFolder({bool useDefault = false}) async {
    final app = context.app;
    final path = useDefault ? '' : _folderCtrl.text.trim();
    if (path.isNotEmpty) {
      final problem = Backups.folderProblem(path);
      if (problem != null) {
        app.nav.toast(problem, error: true);
        return;
      }
    }
    if (useDefault) _folderCtrl.clear();
    await runGuarded(context, () => app.settings.set(context.db, Backups.folderKey, path),
        success: path.isEmpty ? 'Backups go to the default folder' : 'Backups go to $path from now on');
    await _refresh();
  }

  Future<void> _restore(BackupFile b) async {
    final ok = await confirmByTyping(
      context,
      title: 'Restore the backup from ${formatDateTime(b.time)}?',
      message: 'All data on this computer is replaced with this backup. Anything entered after '
          '${formatDateTime(b.time)} is lost. Kendra saves a safety copy of the current data first, '
          'then restarts; people on other devices have to sign in again.',
      word: 'RESTORE',
      confirmLabel: 'Restore',
    );
    if (!ok || !mounted) return;
    final app = context.app;
    setState(() => _busy = true);
    final done = await runGuarded(context, () => Backups.restore(app, b));
    if (!done && mounted) setState(() => _busy = false);
  }

  Future<void> _leaveDemo() async {
    final ok = await confirmDialog(
      context,
      title: 'Leave the demo?',
      message: 'The sample hospital and its demo data are deleted, and Kendra goes back to the first screen so '
          'you can set up your real hospital. Nothing from the demo is carried over.',
      confirmLabel: 'Leave the demo',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final app = context.app;
    await SetupService.leaveDemo(app);
    await app.requestRestart?.call();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final files = _files;
    final last = _last;
    final age = last == null ? null : DateTime.now().difference(last.ts);
    final (Tone tone, IconData icon, String title) = switch (age) {
      null => (Tone.danger, Icons.error_outline, 'No backup has been made yet'),
      Duration a when a < const Duration(hours: 26) =>
        (Tone.success, Icons.verified_outlined, 'Last backup ${formatRelative(last!.ts)}'),
      Duration a when a < const Duration(hours: 48) =>
        (Tone.warning, Icons.schedule, 'Last backup ${formatRelative(last!.ts)}'),
      _ => (Tone.danger, Icons.error_outline, 'Last backup ${formatDate(last!.ts)} — over two days ago'),
    };

    return PageScaffold(
      title: 'Backup & restore',
      subtitle: 'Copies of all hospital data, so nothing is lost if this computer fails',
      primaryAction: PageAction(_busy ? 'Working…' : 'Back up now', Icons.backup_outlined, _busy ? null : _backUp,
          tourAnchor: 'admin.backup_now'),
      body: files == null
          ? const LoadingView()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NoticeBanner(
                  icon: icon,
                  tone: tone,
                  title: title,
                  message: last == null
                      ? 'Press "Back up now". After that Kendra backs up by itself every afternoon.'
                      : 'Saved as ${last.details['path'] ?? 'a backup file'}.',
                ),
                Gap.v16,
                SectionCard(
                  title: 'Backups in the folder',
                  subtitle: _folder,
                  child: files.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                          child: Text('No backups in this folder yet.', style: muted),
                        )
                      : DataList<BackupFile>(
                          items: files,
                          leading: (b) => Icon(_kindIcon(b.kind), color: theme.colorScheme.onSurfaceVariant),
                          title: (b) => formatDateTime(b.time),
                          subtitle: (b) => '${b.kind.label} · ${Backups.formatSize(b.size)}',
                          trailing: (b) => TextButton(onPressed: _busy ? null : () => _restore(b), child: const Text('Restore')),
                          columns: [
                            ListColumn('Made', (b) => TwoLine(formatDateTime(b.time), formatRelative(b.time)), flex: 4),
                            ListColumn('Kind', (b) => TwoLine(b.kind.label, b.name), flex: 5),
                            ListColumn('Size', (b) => Text(Backups.formatSize(b.size), maxLines: 1), width: 90),
                            ListColumn(
                              '',
                              (b) => OutlinedButton(onPressed: _busy ? null : () => _restore(b), child: const Text('Restore')),
                              width: 120,
                            ),
                          ],
                        ),
                ),
                Gap.v16,
                ResponsiveGrid(minWidth: 420, maxColumns: 2, children: [
                  SectionCard(
                    title: 'Where backups are saved',
                    subtitle: 'Keep one copy away from this computer',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppTextField(
                          label: 'Backup folder',
                          controller: _folderCtrl,
                          prefixIcon: Icons.folder_outlined,
                          hint: _defaultFolder,
                          helper: 'Empty = the default folder. ${_example()}',
                        ),
                        Gap.v12,
                        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                          OutlinedButton.icon(
                            onPressed: _chooseFolder,
                            icon: const Icon(Icons.folder_open_outlined, size: 20),
                            label: const Text('Choose folder…'),
                          ),
                          OutlinedButton(onPressed: _saveFolder, child: const Text('Use this folder')),
                          TextButton(onPressed: () => _saveFolder(useDefault: true), child: const Text('Use the default')),
                        ]),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Automatic backups',
                    subtitle: 'Nothing to do; it happens by itself',
                    child: Text(
                      'Every day after 1 PM, while this computer is on, Kendra makes a backup and keeps the newest '
                      '${Backups.keepAutomatic}. Backups you make by hand are never deleted. If the folder is not '
                      'available (USB drive unplugged), the backup goes to the default folder instead.',
                      style: muted,
                    ),
                  ),
                ]),
                if (app.isDemo) ...[
                  Gap.v16,
                  SectionCard(
                    title: 'Demo hospital',
                    child: ActionRow(
                      icon: Icons.exit_to_app,
                      title: 'Leave the demo',
                      message: 'Delete the sample hospital and set up your real one. The demo never shares data '
                          'with a real hospital.',
                      button: OutlinedButton(
                        style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                        onPressed: _busy ? null : _leaveDemo,
                        child: const Text('Leave the demo'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  /// Where a USB drive shows up on this kind of computer.
  static String _example() {
    if (Platform.isWindows) return r'For a USB drive, e.g. E:\Kendra backups';
    if (Platform.isMacOS) return 'For a USB drive, e.g. /Volumes/USB/Kendra backups';
    return 'Use "Choose folder" for an SD card or USB drive';
  }

  static IconData _kindIcon(BackupKind k) => switch (k) {
        BackupKind.automatic => Icons.schedule,
        BackupKind.manual => Icons.backup_outlined,
        BackupKind.beforeRestore => Icons.restore,
      };
}

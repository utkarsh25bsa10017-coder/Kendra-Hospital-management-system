import 'dart:convert';
import 'dart:io';

import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/data/record_store.dart' show RecordStore;
import 'package:kendra_hms/core/services/device_config.dart';

enum BackupKind {
  manual('Made by hand', ''),
  automatic('Automatic', '-auto'),
  beforeRestore('Safety copy before a restore', '-before-restore');

  const BackupKind(this.label, this.suffix);
  final String label;
  final String suffix;
}

/// One backup file in the backup folder.
class BackupFile {
  const BackupFile(this.path, this.time, this.size, this.kind);
  final String path;
  final DateTime time;
  final int size;
  final BackupKind kind;

  String get name => path.split(Platform.pathSeparator).last;
}

/// Backups are complete copies of the database file, made with SQLite's
/// `VACUUM INTO` so they are consistent even while people are working.
abstract final class Backups {
  static const folderKey = 'backup.folder';
  static const keepAutomatic = 14;

  /// Automatic backups run once a day from this hour (13 = 1 PM), when the
  /// main computer is most likely to be on and busy data has been entered.
  static const autoHour = 13;
  static const auditAction = 'backup';
  static const restoreAction = 'restore';

  static String get _sep => Platform.pathSeparator;
  static final _pattern = RegExp(r'^kendra-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(?:-(\d+))?(-auto|-before-restore)?\.db$');

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// kendra-YYYYMMDD-HHmm.db (plus -auto / -before-restore).
  static String fileName(DateTime t, BackupKind kind, [int n = 1]) =>
      'kendra-${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${n > 1 ? '-$n' : ''}${kind.suffix}.db';

  /// The data folder's `backups` folder. The demo hospital keeps its own,
  /// so a sample backup can never be restored over real data by mistake.
  static Future<String> defaultFolder(DeviceConfig config) async =>
      '${(await config.directory()).path}$_sep${config.mode == DeviceMode.demo ? 'demo-backups' : 'backups'}';

  static Future<String> folder(AppServices app) async {
    final custom = app.settings.str(folderKey).trim();
    return custom.isNotEmpty ? custom : defaultFolder(app.config);
  }

  static BackupFile? parse(File f) {
    final m = _pattern.firstMatch(f.uri.pathSegments.last);
    if (m == null) return null;
    final t = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
    final kind = switch (m[7]) {
      '-auto' => BackupKind.automatic,
      '-before-restore' => BackupKind.beforeRestore,
      _ => BackupKind.manual,
    };
    try {
      return BackupFile(f.path, t, f.lengthSync(), kind);
    } on FileSystemException {
      return null;
    }
  }

  /// Backups in [folder], newest first.
  static List<BackupFile> list(String folder, {int limit = 100}) {
    final dir = Directory(folder);
    if (!dir.existsSync()) return const [];
    final out = <BackupFile>[];
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File) {
          final b = parse(e);
          if (b != null) out.add(b);
        }
      }
    } on FileSystemException {
      return const [];
    }
    out.sort((a, b) {
      final c = b.time.compareTo(a.time);
      return c != 0 ? c : b.name.compareTo(a.name);
    });
    return out.take(limit).toList();
  }

  /// Checks that Kendra can create files in [folder] (e.g. a USB drive).
  static String? folderProblem(String folder) {
    try {
      final dir = Directory(folder)..createSync(recursive: true);
      final probe = File('${dir.path}$_sep.kendra-write-test');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return null;
    } on FileSystemException catch (e) {
      return 'Kendra cannot save files in $folder (${e.osError?.message ?? e.message}).';
    }
  }

  /// Writes a backup and records it in the audit log.
  static Future<BackupFile> backupNow(AppServices app,
      {BackupKind kind = BackupKind.manual, Db? db, DateTime? now, String? intoFolder}) async {
    final local = app.local;
    if (local == null) throw ValidationException('Backups are made on the main computer (the hub).');
    final folderPath = intoFolder ?? await folder(app);
    final problem = folderProblem(folderPath);
    if (problem != null) throw ValidationException(problem);
    final t = now ?? DateTime.now();
    var n = 1;
    String path;
    do {
      path = '$folderPath$_sep${fileName(t, kind, n++)}';
    } while (File(path).existsSync());
    local.backupTo(path);
    final size = File(path).lengthSync();
    await (db ?? app.db).audit(auditAction, details: {'path': path, 'size': size, 'kind': kind.name});
    if (kind == BackupKind.automatic) prune(folderPath);
    return BackupFile(path, t, size, kind);
  }

  /// Keeps the newest [keep] automatic backups and deletes older ones.
  /// Backups made by hand and safety copies are never deleted.
  static List<String> prune(String folder, {int keep = keepAutomatic}) {
    final auto = list(folder, limit: 100000).where((b) => b.kind == BackupKind.automatic).toList();
    final removed = <String>[];
    for (final b in auto.skip(keep)) {
      try {
        File(b.path).deleteSync();
        removed.add(b.path);
      } on FileSystemException {
        // Leave it; the next run tries again.
      }
    }
    return removed;
  }

  /// The most recent backup recorded in the audit log.
  static Future<AuditEntry?> lastBackup(RecordStore store) async {
    final r = await store.auditLog(const AuditFilter(action: auditAction, limit: 1));
    return r.isEmpty ? null : r.first;
  }

  static bool isDue(DateTime now, DateTime? last) =>
      now.hour >= autoHour && (last == null || last.isBefore(startOfDay(now)));

  /// The daily automatic backup. If the chosen folder is not available
  /// (USB drive unplugged), it falls back to the default folder.
  static Future<BackupFile?> autoBackupIfDue(AppServices app, {DateTime? now}) async {
    if (!app.isDataHost || app.local == null) return null;
    final t = now ?? DateTime.now();
    if (!isDue(t, (await lastBackup(app.store))?.ts)) return null;
    try {
      return await backupNow(app, kind: BackupKind.automatic, db: app.systemDb, now: t);
    } on ValidationException {
      final fallback = await defaultFolder(app.config);
      if (fallback == await folder(app)) rethrow;
      return backupNow(app, kind: BackupKind.automatic, db: app.systemDb, now: t, intoFolder: fallback);
    }
  }

  /// True if [path] is an SQLite database file.
  static bool looksLikeBackup(String path) {
    try {
      final raf = File(path).openSync();
      try {
        final head = raf.readSync(16);
        return head.length == 16 && utf8.decode(head.sublist(0, 15), allowMalformed: true) == 'SQLite format 3' && head[15] == 0;
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  /// Replaces the database file at [dbPath] with a copy of [backupPath].
  /// The database must be closed first. The copy is written next to the
  /// database and renamed into place, so a failed copy never leaves half a
  /// database behind.
  static void replaceDatabaseFile({required String backupPath, required String dbPath}) {
    if (!looksLikeBackup(backupPath)) throw ValidationException('That file is not a Kendra backup.');
    final tmp = File('$dbPath.restoring');
    if (tmp.existsSync()) tmp.deleteSync();
    File(backupPath).copySync(tmp.path);
    for (final suffix in ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    tmp.renameSync(dbPath);
  }

  static Future<String> _notePath(DeviceConfig config) async =>
      '${(await config.directory()).path}$_sep${config.dbFileName}.restored.json';

  /// Restores [backup] over this hospital's data and restarts the app.
  /// A safety copy of the current data is made first, so this can be undone.
  static Future<void> restore(AppServices app, BackupFile backup) async {
    if (app.local == null) throw ValidationException('Restores are done on the main computer (the hub).');
    if (!looksLikeBackup(backup.path)) throw ValidationException('That file is not a Kendra backup.');
    final me = app.auth.session;
    final safety = await backupNow(app, kind: BackupKind.beforeRestore);
    final dbPath = await app.config.databasePath();
    final note = await _notePath(app.config);
    await app.close();
    try {
      replaceDatabaseFile(backupPath: backup.path, dbPath: dbPath);
      File(note).writeAsStringSync(jsonEncode({
        'path': backup.path,
        'backup_time': backup.time.toIso8601String(),
        'safety_copy': safety.path,
        'by_id': me?.userId,
        'by_name': me?.displayName,
        'at': DateTime.now().toIso8601String(),
      }));
    } finally {
      // Start again either way: on the restored data, or on the old data if
      // the copy failed (it is only swapped in once complete).
      await app.requestRestart?.call();
    }
  }

  /// After a restore, writes who restored what into the restored database's
  /// own audit log. Called when the app starts.
  static Future<void> recordRestore(AppServices app) async {
    if (app.local == null) return;
    final f = File(await _notePath(app.config));
    if (!f.existsSync()) return;
    try {
      final details = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
      await app.systemDb.audit(restoreAction, details: details);
    } catch (_) {
      // A damaged note is not worth failing start-up over.
    } finally {
      if (f.existsSync()) f.deleteSync();
    }
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes bytes';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

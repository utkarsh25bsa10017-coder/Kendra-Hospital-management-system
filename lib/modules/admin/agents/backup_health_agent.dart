import 'package:kendra_hms/core/core.dart';

import '../backup_service.dart';

/// Raises the alarm when the hospital's data has not been backed up for two
/// days. Without a recent backup, a failed hard disk loses every record.
class BackupHealthAgent extends HmsAgent {
  static const maxAge = Duration(hours: 48);

  @override
  String get id => 'admin.backup_health';
  @override
  String get name => 'Backups';
  @override
  String get description => 'Warns when the hospital data has not been backed up for two days.';
  @override
  Duration get interval => const Duration(hours: 1);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final last = await Backups.lastBackup(ctx.db.store);
    // A brand-new hospital gets two days before its first backup is due.
    final since = last?.ts ?? (await ctx.db.get(Col.settings, SettingKeys.setupComplete))?.createdAt;
    if (since == null) return const AgentReport();
    final age = ctx.now.difference(since);
    if (age < maxAge) return const AgentReport();
    final days = age.inDays;
    return AgentReport(findings: [
      FindingDraft(
        key: 'stale',
        subjectKey: 'backup',
        title: last == null ? 'No backup has been made yet' : 'No backup for ${plural(days, 'day')}',
        summary: last == null
            ? 'This hospital has run for ${plural(days, 'day')} without a backup. If this computer fails, '
                'every record is lost. Open Backup & restore and press "Back up now".'
            : 'The last backup was on ${formatDateTime(last.ts)}. Automatic backups run every afternoon '
                'while the main computer is on. Check that it stays on and that the backup folder or USB drive is '
                'available, then press "Back up now".',
        severity: Severity.high,
        category: 'data safety',
        evidence: const [Evidence('Backup & restore', routeId: 'admin.backup')],
        data: {'last_backup': last?.ts.toIso8601String(), 'days': days},
      ),
    ]);
  }
}

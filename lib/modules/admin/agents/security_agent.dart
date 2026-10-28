import 'package:kendra_hms/core/core.dart';

/// Watches staff accounts for signs of trouble: password guessing, locked
/// accounts, temporary passwords nobody used, and too many owners.
class SecurityAgent extends HmsAgent {
  static const failedLimit = 10;
  static const temporaryPasswordDays = 7;
  static const maxOwners = 2;

  @override
  String get id => 'admin.security';
  @override
  String get name => 'Account security';
  @override
  String get description => 'Flags repeated failed sign-ins, locked accounts, unused temporary passwords '
      'and too many owner accounts.';
  @override
  Set<String> get watches => const {Col.users};
  @override
  Duration get interval => const Duration(hours: 1);

  static Evidence _userEvidence(Rec u) => Evidence('${u.str('display_name')} (@${u.str('username')})',
      collection: Col.users, id: u.id, routeId: 'admin.user', routeArgs: {'id': u.id});

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final store = ctx.db.store;
    final users = await ctx.db.query(const Query(Col.users).sort('display_name').take(5000));
    final byId = {for (final u in users) u.id: u};
    final findings = <FindingDraft>[];

    // 1. Many failed sign-ins for one username in the last 24 hours.
    final failed = await store.auditLog(AuditFilter(
        action: 'login_failed', from: ctx.now.subtract(const Duration(hours: 24)), limit: 5000));
    final counts = <String, int>{};
    final userFor = <String, Rec>{};
    for (final e in failed) {
      final u = e.recordId == null ? null : byId[e.recordId];
      final username = u?.str('username') ?? (e.details['username'] as String?) ?? '';
      if (username.isEmpty) continue;
      counts[username] = (counts[username] ?? 0) + 1;
      if (u != null) userFor[username] = u;
    }
    for (final c in counts.entries.where((c) => c.value > failedLimit)) {
      final u = userFor[c.key];
      findings.add(FindingDraft(
        key: 'failed:${c.key}',
        subjectKey: 'username:${c.key}',
        title: '${c.value} failed sign-ins for "${c.key}"',
        summary: u != null
            ? 'Someone typed a wrong password for ${u.str('display_name')} ${c.value} times in the last 24 hours. '
                'If it was not them, reset their password and ask who has been using their computer.'
            : 'Someone tried ${c.value} times in the last 24 hours to sign in as "${c.key}", which is not a staff '
                'account. This can mean someone is guessing usernames and passwords.',
        severity: Severity.medium,
        category: 'security',
        evidence: [
          if (u != null) _userEvidence(u),
          const Evidence('Audit log', routeId: 'admin.audit'),
        ],
        data: {'count': c.value},
      ));
    }

    for (final u in users.where((u) => u.flag('active'))) {
      // 2. Locked right now after too many wrong passwords.
      final until = u.date('locked_until');
      if (until != null && until.isAfter(ctx.now)) {
        findings.add(FindingDraft(
          key: 'locked:${u.id}',
          subjectKey: 'user:${u.id}',
          title: 'Account locked: ${u.str('display_name')}',
          summary: 'After 5 wrong passwords the account is locked until ${formatTime(until)}. '
              'If they need it now, unlock it in Staff accounts or reset their password.',
          severity: Severity.low,
          category: 'security',
          evidence: [_userEvidence(u)],
        ));
      }

      // 3. A temporary password that has not been replaced for a week.
      if (u.flag('must_change_password')) {
        final set = await store.auditLog(AuditFilter(action: 'password_changed', recordId: u.id, limit: 1));
        final since = set.isEmpty ? u.createdAt : set.first.ts;
        final days = ctx.now.difference(since).inDays;
        if (days > temporaryPasswordDays) {
          findings.add(FindingDraft(
            key: 'temporary:${u.id}',
            subjectKey: 'user:${u.id}',
            title: '${u.str('display_name')} still has a temporary password',
            summary: 'It was given ${plural(days, 'day')} ago and has not been changed. If they have left or do not '
                'need Kendra, switch the account off; otherwise ask them to sign in and choose their own password.',
            severity: Severity.low,
            category: 'security',
            evidence: [_userEvidence(u)],
          ));
        }
      }
    }

    // 4. Owner access can see and change everything.
    final owners = users.where((u) => u.flag('active') && u.list<String>('role_ids').contains(Roles.owner)).toList();
    if (owners.length > maxOwners) {
      findings.add(FindingDraft(
        key: 'owners',
        subjectKey: 'owners',
        title: '${owners.length} people have owner access',
        summary: 'Owners can see and change everything, including approvals and the audit log. Keep it to one or '
            'two people and give others a narrower role, such as Hospital administrator.',
        severity: Severity.low,
        category: 'security',
        evidence: [for (final u in owners.take(6)) _userEvidence(u)],
        data: {'count': owners.length},
      ));
    }

    return AgentReport(findings: findings);
  }
}

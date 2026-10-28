import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';
import '../audit_format.dart';
import 'admin_widgets.dart';
import 'staff_form.dart';

class _StaffData {
  const _StaffData(this.user, this.roleNames, this.cannotDeactivate, this.activity);
  final Rec user;
  final Map<String, String> roleNames;
  final String? cannotDeactivate;
  final List<AuditEntry> activity;
}

/// One staff account: details, roles, and the account actions.
class StaffDetailScreen extends StatelessWidget {
  const StaffDetailScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final me = context.session;
    final canAudit = context.can(CorePerms.adminAudit);
    return LiveBuilder<_StaffData?>(
      watch: const {Col.users, Col.roles},
      deps: [userId],
      load: (db) async {
        final u = await db.get(Col.users, userId);
        if (u == null || me == null) return null;
        return _StaffData(
          u,
          await loadRoleNames(db),
          await Staff.whyCannotDeactivate(db, me, u),
          canAudit ? await app.store.auditLog(AuditFilter(actorId: userId, limit: 8)) : const [],
        );
      },
      builder: (context, d) {
        if (d == null) {
          return const PageScaffold(
            title: 'Staff member',
            body: EmptyState(icon: Icons.person_off_outlined, title: 'This account was not found'),
          );
        }
        return _Detail(data: d);
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.data});
  final _StaffData data;

  Rec get u => data.user;
  String get name => u.str('display_name');
  String get first => name.split(' ').firstWhere((w) => w.isNotEmpty && !w.endsWith('.'), orElse: () => name);

  Future<void> _edit(BuildContext context) async {
    final saved = await showEditStaff(context, u);
    if (saved != null && context.mounted) context.toast('Saved');
  }

  Future<void> _reset(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: 'Reset password for $name?',
      message: 'Kendra makes a new temporary password. The old one stops working straight away, '
          'and $first chooses a new password at the next sign-in.',
      confirmLabel: 'Reset password',
    );
    if (!ok || !context.mounted) return;
    final app = context.app;
    String? password;
    final done = await runGuarded(context, () async => password = await Staff.resetPassword(app, u));
    if (!done || password == null || !context.mounted) return;
    await showTemporaryPassword(context, name: name, username: u.str('username'), password: password!, reset: true);
  }

  Future<void> _unlock(BuildContext context) async {
    final app = context.app;
    await runGuarded(context, () => Staff.unlock(app, u), success: '$first can sign in again');
  }

  Future<void> _setActive(BuildContext context, bool active) async {
    final ok = active
        ? await confirmDialog(context,
            title: 'Switch $name\'s account back on?',
            message: '$first can sign in again with their existing password.',
            confirmLabel: 'Switch on')
        : await confirmDialog(context,
            title: 'Switch off $name\'s account?',
            message: '$first will not be able to sign in on any device. Nothing they recorded is deleted, '
                'and you can switch the account back on later.',
            confirmLabel: 'Switch off',
            destructive: true);
    if (!ok || !context.mounted) return;
    final app = context.app;
    await runGuarded(context, () => Staff.setActive(app, u, active),
        success: active ? '$name can sign in again' : '$name\'s account is switched off');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final me = context.session;
    final isMe = me?.userId == u.id;
    final status = Staff.statusOf(u);
    final roles = u.list<String>('role_ids');
    final lockedUntil = u.date('locked_until');
    final ownerOnly = Staff.isOwner(u) && !(me != null && Staff.sessionIsOwner(me));

    return PageScaffold(
      title: name,
      subtitle: '@${u.str('username')} · ${roleSummary(roles, data.roleNames)}',
      actions: [
        IconButton(tooltip: 'Edit details', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context)),
      ],
      headerBottom: Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          StaffStatusChip(u),
          if (isMe) const StatusChip('This is you', icon: Icons.person_outline, tone: Tone.info),
          if (u.flag('is_clinician')) const StatusChip('Sees patients', icon: Icons.medical_services_outlined),
          if (roles.contains(Roles.owner)) const StatusChip('Owner access', icon: Icons.lock_outline, tone: Tone.board),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status == StaffStatus.locked) ...[
            NoticeBanner(
              icon: Icons.lock_outline,
              tone: Tone.danger,
              title: 'Locked after too many wrong passwords',
              message: 'Sign-in is blocked until ${formatTime(lockedUntil)}. Unlock it now if you know it was $first.',
              action: FilledButton(onPressed: () => _unlock(context), child: const Text('Unlock')),
            ),
            Gap.v16,
          ],
          if (status == StaffStatus.off) ...[
            NoticeBanner(
              icon: Icons.block,
              tone: Tone.neutral,
              title: 'This account is switched off',
              message: '$first cannot sign in. Everything they recorded stays in the hospital records.',
            ),
            Gap.v16,
          ],
          if (status == StaffStatus.temporaryPassword) ...[
            NoticeBanner(
              icon: Icons.key_outlined,
              tone: Tone.warning,
              title: 'Waiting for $first to choose a password',
              message: 'They have a temporary password. At their next sign-in Kendra asks them to choose their own.',
            ),
            Gap.v16,
          ],
          SectionCard(
            title: 'Account',
            child: InfoGrid([
              ('Username', u.str('username')),
              ('Roles', roleSummary(roles, data.roleNames)),
              ('Last sign-in', u.date('last_login_at') == null ? 'Never' : formatDateTime(u.date('last_login_at'))),
              ('Account created', formatDate(u.createdAt)),
              ('Wrong passwords in a row', '${u.integer('failed_attempts')}'),
            ], minItemWidth: 150),
          ),
          Gap.v16,
          ResponsiveGrid(minWidth: 360, maxColumns: 2, children: [
            SectionCard(
              title: 'Work',
              child: InfoGrid([
                ('Department', u.str('department')),
                ('Sees patients', u.flag('is_clinician') ? 'Yes' : 'No'),
                if (u.flag('is_clinician')) ...[
                  ('Specialization', u.str('specialization')),
                  ('Registration no.', u.str('registration_no')),
                  ('Consultation fee', u.intOrNull('consultation_fee_paise') == null ? '' : formatMoney(u.integer('consultation_fee_paise'))),
                ],
                (
                  'Discounts without approval',
                  u.integer('discount_limit_paise') <= 0
                      ? 'None'
                      : 'Up to ${formatMoney(u.integer('discount_limit_paise'), alwaysDecimals: false)}',
                ),
              ], minItemWidth: 160),
            ),
            SectionCard(
              title: 'Contact',
              child: InfoGrid([('Mobile', u.str('phone')), ('Email', u.str('email'))], minItemWidth: 160),
            ),
          ]),
          Gap.v16,
          SectionCard(
            title: 'Account actions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ActionRow(
                  icon: Icons.lock_reset,
                  title: 'Reset password',
                  message: isMe
                      ? 'This is your own account. Use "Change password" in your profile menu instead.'
                      : ownerOnly
                          ? 'Only an owner can reset an owner\'s password.'
                          : 'For when $first has forgotten it. You get a new temporary password to give them.',
                  button: OutlinedButton(
                    onPressed: isMe || ownerOnly || status == StaffStatus.off ? null : () => _reset(context),
                    child: const Text('Reset password'),
                  ),
                ),
                if (status == StaffStatus.locked) ...[
                  const Divider(height: 32),
                  ActionRow(
                    icon: Icons.lock_open,
                    title: 'Unlock',
                    message: 'Lets $first try again now instead of waiting.',
                    button: OutlinedButton(onPressed: () => _unlock(context), child: const Text('Unlock')),
                  ),
                ],
                const Divider(height: 32),
                if (status == StaffStatus.off)
                  ActionRow(
                    icon: Icons.person_add_alt,
                    title: 'Switch the account back on',
                    message: ownerOnly ? 'Only an owner can do this for an owner.' : '$first can sign in again.',
                    button: FilledButton(
                        onPressed: ownerOnly ? null : () => _setActive(context, true), child: const Text('Switch on')),
                  )
                else
                  ActionRow(
                    icon: Icons.person_off_outlined,
                    title: 'Switch off',
                    message: data.cannotDeactivate ??
                        'When someone leaves. They can no longer sign in; their records stay.',
                    button: OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: data.cannotDeactivate == null ? () => _setActive(context, false) : null,
                      child: const Text('Switch off'),
                    ),
                  ),
              ],
            ),
          ),
          if (context.can(CorePerms.adminAudit)) ...[
            Gap.v16,
            SectionCard(
              title: 'Recent activity',
              subtitle: 'The last things done under this account',
              trailing: TextButton(
                onPressed: () => app.nav.open('admin.audit', {'actor': u.id}),
                child: const Text('Full history'),
              ),
              child: data.activity.isEmpty
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: Gap.sm), child: Text('Nothing yet'))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final e in data.activity) _ActivityLine(entry: e),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivityLine extends StatelessWidget {
  const _ActivityLine({required this.entry});
  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = [AuditFormat.action(entry.action), if (entry.collection != null) AuditFormat.collection(entry.collection)];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(formatRelative(entry.ts),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(what.join(' · '), style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

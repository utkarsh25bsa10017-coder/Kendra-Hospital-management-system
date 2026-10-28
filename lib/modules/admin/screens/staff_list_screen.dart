import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';
import 'admin_widgets.dart';
import 'staff_form.dart';

enum _Show { all, active, temporary, locked, off }

class StaffListScreen extends StatefulWidget {
  const StaffListScreen({super.key, this.openAdd = false});

  /// Opens the "Add staff" form straight away (from the command palette).
  final bool openAdd;

  @override
  State<StaffListScreen> createState() => _StaffListScreenState();
}

class _StaffListScreenState extends State<StaffListScreen> {
  String _search = '';
  String _role = '';
  _Show _show = _Show.all;

  @override
  void initState() {
    super.initState();
    if (widget.openAdd) WidgetsBinding.instance.addPostFrameCallback((_) => _add());
  }

  Query _query() {
    var q = const Query(Col.users).matching(_search).sort('display_name').take(300);
    if (_role.isNotEmpty) q = q.contains('role_ids', '"$_role"');
    final now = DateTime.now();
    return switch (_show) {
      _Show.all => q,
      _Show.active => q.eq('active', true),
      _Show.temporary => q.eq('active', true).eq('must_change_password', true),
      _Show.locked => q.eq('active', true).gt('locked_until', now),
      _Show.off => q.eq('active', false),
    };
  }

  Future<void> _add() async {
    if (!mounted) return;
    final created = await showAddStaff(context);
    if (created == null || !mounted) return;
    await showTemporaryPassword(
      context,
      name: created.user.str('display_name'),
      username: created.user.str('username'),
      password: created.password,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final compact = context.isCompact;
    final roleFilter = LiveBuilder<Map<String, String>>(
      watch: const {Col.roles},
      load: loadRoleNames,
      loading: const SizedBox(height: 48),
      builder: (context, names) => AppDropdown<String>(
        label: 'Role',
        value: _role,
        items: [('', 'All roles'), for (final e in names.entries) (e.key, e.value)],
        onChanged: (v) => setState(() => _role = v ?? ''),
      ),
    );
    final search = SearchField(hint: 'Name, username or department', onChanged: (v) => setState(() => _search = v));

    return PageScaffold(
      title: 'Staff accounts',
      subtitle: 'Everyone who signs in to Kendra, what they may do, and whether they can sign in',
      primaryAction: PageAction('Add staff', Icons.person_add_alt_1, _add, tourAnchor: 'admin.add_staff'),
      headerBottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact) ...[search, Gap.v12, roleFilter]
          else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: search),
              Gap.h12,
              SizedBox(width: 260, child: roleFilter),
            ]),
          Gap.v12,
          FilterChips<_Show>(
            options: const [
              (_Show.all, 'Everyone'),
              (_Show.active, 'Can sign in'),
              (_Show.temporary, 'Temporary password'),
              (_Show.locked, 'Locked'),
              (_Show.off, 'Switched off'),
            ],
            value: _show,
            onChanged: (v) => setState(() => _show = v),
          ),
        ],
      ),
      body: LiveBuilder<(List<Rec>, Map<String, String>)>(
        watch: const {Col.users, Col.roles},
        deps: [_search, _role, _show],
        load: (db) async => (await db.query(_query()), await loadRoleNames(db)),
        builder: (context, data) {
          final (users, names) = data;
          return DataList<Rec>(
            items: users,
            empty: EmptyState(
              icon: Icons.badge_outlined,
              title: _search.isEmpty ? 'Nobody here' : 'Nobody matches "$_search"',
              message: 'Add each person who uses Kendra with their own username, so everything they do is recorded '
                  'under their name.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.person_add_alt_1), label: const Text('Add staff')),
            ),
            onTap: (u) => app.nav.open('admin.user', {'id': u.id}),
            leading: (u) => Avatar(u.str('display_name'), size: 36),
            title: (u) => u.str('display_name'),
            subtitle: (u) => [
              '@${u.str('username')} · ${roleSummary(u.list<String>('role_ids'), names)}',
              'Last sign-in ${u.date('last_login_at') == null ? 'never' : formatRelative(u.date('last_login_at'))}',
            ].join('\n'),
            trailing: (u) => Staff.statusOf(u) == StaffStatus.active ? const SizedBox.shrink() : StaffStatusChip(u),
            columns: [
              ListColumn(
                'Name',
                (u) => Row(children: [
                  Avatar(u.str('display_name'), size: 32),
                  Gap.h12,
                  Expanded(
                    child: TwoLine(u.str('display_name'),
                        ['@${u.str('username')}', if (u.str('department').isNotEmpty) u.str('department')].join(' · ')),
                  ),
                ]),
                flex: 4,
              ),
              ListColumn('Roles', (u) => RoleChips(roleIds: u.list<String>('role_ids'), roleNames: names), flex: 4),
              ListColumn('Status', StaffStatusChip.new, width: 190),
              ListColumn(
                'Last sign-in',
                (u) => Text(u.date('last_login_at') == null ? 'Never' : formatRelative(u.date('last_login_at')),
                    overflow: TextOverflow.ellipsis),
                flex: 2,
              ),
            ],
          );
        },
      ),
    );
  }
}

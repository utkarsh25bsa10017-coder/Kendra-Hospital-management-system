import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';

class _RoleRow {
  const _RoleRow(this.role, this.people);
  final Rec role;
  final int people;
}

/// Every role, how many people have it, and whether it was changed.
class RolesScreen extends StatelessWidget {
  const RolesScreen({super.key});

  static Future<List<_RoleRow>> _load(ReadDb db) async {
    final roles = await db.query(const Query(Col.roles).sort('name').take(500));
    final users = await db.query(const Query(Col.users).eq('active', true).take(5000));
    final counts = <String, int>{};
    for (final u in users) {
      for (final r in u.list<String>('role_ids')) {
        counts[r] = (counts[r] ?? 0) + 1;
      }
    }
    final order = {for (final (i, t) in Roles.templates.indexed) t.id: i};
    roles.sort((a, b) => (order[a.id] ?? 1000).compareTo(order[b.id] ?? 1000));
    return [for (final r in roles) _RoleRow(r, counts[r.id] ?? 0)];
  }

  Future<void> _add(BuildContext context) async {
    final id = await showFormSheet<String>(context, title: 'Add a role', builder: (c) => const _NewRoleForm());
    if (id != null && context.mounted) context.app.nav.open('admin.role', {'id': id});
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final known = RoleAdmin.knownIds(app.registry).toSet();
    return PageScaffold(
      title: 'Roles & permissions',
      subtitle: 'A role is a set of things people may do. Give each person the roles that match their job.',
      primaryAction: PageAction('Add role', Icons.add_moderator_outlined, () => _add(context)),
      body: LiveBuilder<List<_RoleRow>>(
        watch: const {Col.roles, Col.users},
        load: _load,
        builder: (context, rows) => DataList<_RoleRow>(
          items: rows,
          onTap: (r) => app.nav.open('admin.role', {'id': r.role.id}),
          title: (r) => r.role.str('name'),
          subtitle: (r) => '${_permsLabel(r.role, known)} · ${plural(r.people, 'person', 'people')}\n'
              '${r.role.str('description')}',
          trailing: _kindChip,
          columns: [
            ListColumn('Role', (r) => TwoLine(r.role.str('name'), r.role.str('description')), flex: 6),
            ListColumn('People', (r) => Text(plural(r.people, 'person', 'people')), flex: 2),
            ListColumn('Permissions', (r) => Text(_permsLabel(r.role, known)), flex: 2),
            ListColumn('Type', _kindChip, width: 170),
          ],
        ),
      ),
    );
  }

  static String _permsLabel(Rec role, Set<String> known) {
    final p = role.list<String>('permissions');
    if (p.contains('*')) return 'Everything';
    return '${p.where(known.contains).length} of ${known.length} allowed';
  }

  static Widget _kindChip(_RoleRow r) => _kind(r.role);

  static Widget _kind(Rec role) {
    if (role.id == Roles.owner) return const StatusChip('Full access', icon: Icons.lock_outline, tone: Tone.board);
    if (!role.flag('builtin')) return const StatusChip('Added by you', tone: Tone.info);
    if (role.flag('customized')) return const StatusChip('Built-in, changed', tone: Tone.warning);
    return const StatusChip('Built-in');
  }
}

class _NewRoleForm extends StatefulWidget {
  const _NewRoleForm();

  @override
  State<_NewRoleForm> createState() => _NewRoleFormState();
}

class _NewRoleFormState extends State<_NewRoleForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _desc = TextEditingController();
  bool _idTouched = false;
  String _copyFrom = '';
  List<Rec> _roles = const [];
  String? _error;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_roles.isEmpty) _load();
  }

  Future<void> _load() async {
    final r = await context.app.readDb.query(const Query(Col.roles).sort('name').take(500));
    if (mounted) setState(() => _roles = r.where((x) => x.id != Roles.owner).toList());
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.app;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final from = _roles.where((r) => r.id == _copyFrom).firstOrNull;
      final rec = await RoleAdmin.add(app,
          id: _id.text,
          name: _name.text,
          description: _desc.text,
          permissions: from?.list<String>('permissions') ?? const []);
      if (mounted) Navigator.of(context).pop(rec.id);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('For a job the built-in roles do not fit, such as "Insurance desk". '
              'You choose its permissions on the next screen.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Gap.v16,
          FormGrid(maxColumns: 2, children: [
            AppTextField(
              label: 'Role name',
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              validator: Validators.required('Role name'),
              onChanged: (v) {
                if (!_idTouched) _id.text = RoleAdmin.slug(v);
              },
            ),
            AppTextField(
              label: 'Short id',
              controller: _id,
              helper: 'Used inside Kendra. Cannot be changed later.',
              validator: (v) => RoleAdmin.idProblem((v ?? '').trim()),
              onChanged: (_) => _idTouched = true,
            ),
            FullWidth(child: AppTextField(label: 'What this role is for', controller: _desc, maxLines: 2)),
            FullWidth(
              child: AppDropdown<String>(
                label: 'Start with the permissions of',
                value: _copyFrom,
                helper: 'Optional. Saves ticking boxes when the new role is close to an existing one.',
                items: [('', 'Nothing (I will choose)'), for (final r in _roles) (r.id, r.str('name'))],
                onChanged: (v) => setState(() => _copyFrom = v ?? ''),
              ),
            ),
          ]),
          if (_error != null) ...[
            Gap.v12,
            Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ],
          Gap.v24,
          Wrap(alignment: WrapAlignment.end, spacing: Gap.sm, children: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: _saving ? null : _save, child: const Text('Create and choose permissions')),
          ]),
        ],
      ),
    );
  }
}

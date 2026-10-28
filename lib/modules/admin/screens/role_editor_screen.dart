import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';
import 'admin_widgets.dart';

/// Tick what a role may do, grouped by module.
class RoleEditorScreen extends StatelessWidget {
  const RoleEditorScreen({super.key, required this.roleId});
  final String roleId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<(Rec?, int)>(
      watch: const {Col.roles},
      deps: [roleId],
      load: (db) async => (
        await db.get(Col.roles, roleId),
        await db.count(Query(Col.users).eq('active', true).contains('role_ids', '"$roleId"')),
      ),
      builder: (context, d) {
        final (role, people) = d;
        if (role == null) {
          return const PageScaffold(
            title: 'Role',
            body: EmptyState(icon: Icons.shield_outlined, title: 'This role was not found'),
          );
        }
        // A new key after every save, so the form starts from what is stored.
        return _Editor(key: ValueKey('${role.id}:${role.version}'), role: role, people: people);
      },
    );
  }
}

class _Editor extends StatefulWidget {
  const _Editor({super.key, required this.role, required this.people});
  final Rec role;
  final int people;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _name = TextEditingController(text: widget.role.str('name'));
  late final _desc = TextEditingController(text: widget.role.str('description'));
  late final Set<String> _perms = widget.role.list<String>('permissions').toSet();
  bool _dirty = false;
  bool _saving = false;

  Rec get role => widget.role;
  bool get _isOwner => role.id == Roles.owner;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _set(Iterable<String> ids, bool on) => setState(() {
        on ? _perms.addAll(ids) : _perms.removeAll(ids);
        _dirty = true;
      });

  Future<void> _save() async {
    final app = context.app;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => RoleAdmin.save(app, role, name: _name.text, description: _desc.text, permissions: _perms),
      success: 'Saved "${_name.text.trim()}". People with this role have the new access from now on.',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _dirty = false;
    });
  }

  Future<void> _reset() async {
    final ok = await confirmDialog(
      context,
      title: 'Reset "${role.str('name')}" to the default?',
      message: 'Its name, description and permissions go back to what Kendra gives this role, '
          'and it follows new modules automatically again. Your changes to it are lost.',
      confirmLabel: 'Reset to default',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final app = context.app;
    await runGuarded(context, () => RoleAdmin.resetToDefault(app, role), success: 'Back to the default permissions');
  }

  Future<bool> _confirmLeave() => confirmDialog(
        context,
        title: 'Discard your changes?',
        message: 'You ticked or unticked permissions but did not save them.',
        confirmLabel: 'Discard',
        destructive: true,
      );

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final groups = RoleAdmin.groups(app.registry);
    final known = {for (final g in groups) for (final p in g.permissions) p.id};
    final allowed = _perms.where(known.contains).length;
    final builtin = role.flag('builtin');
    final canSave = !_isOwner && _dirty && !_saving;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmLeave()) {
          setState(() => _dirty = false);
          nav.pop();
        }
      },
      child: PageScaffold(
        title: role.str('name'),
        subtitle: _isOwner
            ? 'Can do everything in Kendra'
            : 'Tick what people with this role may do. ${plural(allowed, 'permission')} of ${known.length} allowed.',
        maxWidth: 1180,
        // On phones the main button floats, and a floating button cannot look
        // disabled, so it only appears once there is something to save.
        primaryAction: _isOwner || (context.isCompact && !_dirty)
            ? null
            : PageAction('Save changes', Icons.check, canSave ? _save : null),
        headerBottom: Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            StatusChip(builtin ? 'Built-in role' : 'Added by you', tone: builtin ? Tone.neutral : Tone.info),
            if (builtin && role.flag('customized')) const StatusChip('Changed from the default', tone: Tone.warning),
            StatusChip(plural(widget.people, 'person', 'people'), icon: Icons.people_outline),
            if (_dirty) const StatusChip('Not saved yet', icon: Icons.edit_outlined, tone: Tone.warning),
          ],
        ),
        body: _isOwner
            ? const NoticeBanner(
                icon: Icons.lock_outline,
                tone: Tone.board,
                title: 'The owner role always has every permission',
                message: 'This includes permissions from modules you add later. It cannot be changed, so the '
                    'hospital always has someone with full access. Give owner access to as few people as possible.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (builtin && role.flag('customized')) ...[
                    NoticeBanner(
                      icon: Icons.tune,
                      title: 'You have changed this role',
                      message: 'Permissions from newly added modules are still added to it. '
                          'Reset it to go back to what Kendra gives a ${Roles.template(role.id)?.name ?? role.str('name')}.',
                      action: OutlinedButton(onPressed: _reset, child: const Text('Reset to default')),
                    ),
                    Gap.v16,
                  ],
                  SectionCard(
                    title: 'Name and purpose',
                    child: FormGrid(maxColumns: 2, children: [
                      AppTextField(
                        label: 'Role name',
                        controller: _name,
                        validator: Validators.required('Role name'),
                        onChanged: (_) => setState(() => _dirty = true),
                      ),
                      AppTextField(
                        label: 'What this role is for',
                        controller: _desc,
                        onChanged: (_) => setState(() => _dirty = true),
                      ),
                    ]),
                  ),
                  for (final g in groups) ...[
                    Gap.v16,
                    _GroupCard(group: g, selected: _perms, onChanged: _set),
                  ],
                  if (!context.isCompact) ...[
                    Gap.v24,
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: canSave ? _save : null,
                        icon: const Icon(Icons.check),
                        label: const Text('Save changes'),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.selected, required this.onChanged});
  final PermissionGroup group;
  final Set<String> selected;
  final void Function(Iterable<String> ids, bool on) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ids = group.permissions.map((p) => p.id).toList();
    final n = ids.where(selected.contains).length;
    final all = n == ids.length;
    return SectionCard(
      title: group.name,
      subtitle: '$n of ${ids.length} allowed',
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
      trailing: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => onChanged(ids, !all),
        child: Padding(
          padding: const EdgeInsets.only(left: Gap.sm, right: Gap.xs),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(all ? 'Clear all' : 'Select all', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
            Checkbox(
              tristate: true,
              value: all ? true : (n == 0 ? false : null),
              onChanged: (_) => onChanged(ids, !all),
            ),
          ]),
        ),
      ),
      child: ResponsiveGrid(
        minWidth: 340,
        maxColumns: 2,
        spacing: 0,
        children: [
          for (final p in group.permissions)
            CheckboxListTile(
              value: selected.contains(p.id),
              onChanged: (v) => onChanged([p.id], v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.only(right: Gap.sm),
              dense: true,
              title: Text(p.label, style: theme.textTheme.bodyMedium),
              subtitle: p.description.isEmpty ? null : Text(p.description),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';
import 'admin_widgets.dart';

/// Switch features on or off for the whole hospital.
class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key});

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  String? _busy;

  Future<void> _toggle(HmsModule m, bool on) async {
    final app = context.app;
    final all = app.registry.all;
    final enabled = app.registry.enabledIds;
    late final Set<String> next;
    String message;
    if (on) {
      final also = ModuleSwitches.alsoSwitchedOn(all, enabled, m.id);
      next = ModuleSwitches.switchOn(all, enabled, m.id);
      message = also.isEmpty
          ? '${m.name} is on'
          : '${m.name} is on, together with ${also.map((d) => d.name).join(', ')}, which it needs';
    } else {
      final dependents = ModuleSwitches.dependents(all, enabled, m.id);
      final ok = await confirmDialog(
        context,
        title: 'Switch off ${m.name}?',
        message: [
          'Its screens, buttons and agents disappear on every device. Its data is kept, and everything comes '
              'back when you switch it on again.',
          if (dependents.isNotEmpty)
            'These need ${m.name}, so they will be switched off too: ${dependents.map((d) => d.name).join(', ')}.',
        ].join('\n\n'),
        confirmLabel: dependents.isEmpty ? 'Switch off' : 'Switch off ${dependents.length + 1} modules',
        destructive: true,
      );
      if (!ok || !mounted) return;
      try {
        next = ModuleSwitches.switchOff(all, enabled, m.id);
      } on ValidationException catch (e) {
        app.nav.toast(e.message, error: true);
        return;
      }
      message = dependents.isEmpty
          ? '${m.name} is off. Its data is kept.'
          : '${m.name} and ${dependents.map((d) => d.name).join(', ')} are off. Their data is kept.';
    }
    setState(() => _busy = m.id);
    await runGuarded(context, () => ModuleSwitches.save(app, next), success: message);
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app.registry,
      builder: (context, _) {
        final all = app.registry.all;
        final byId = {for (final m in all) m.id: m};
        final on = all.where((m) => app.registry.isActive(m.id)).length;
        return PageScaffold(
          title: 'Modules',
          subtitle: 'Switch features on or off for the whole hospital. Start with what you need.',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NoticeBanner(
                icon: Icons.info_outline,
                title: 'Switching a module off never deletes anything',
                message: 'Its screens and agents are hidden for everyone. Its records stay in the database, and '
                    'everything comes back as it was when you switch it on again.',
              ),
              Gap.v16,
              TourAnchor(
                id: 'admin.modules_list',
                child: SectionCard(
                  title: 'Installed modules',
                  subtitle: '$on of ${all.length} switched on',
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, m) in all.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        _ModuleRow(
                          module: m,
                          active: app.registry.isActive(m.id),
                          needs: [for (final d in m.dependsOn) byId[d]?.name ?? d],
                          neededBy: [
                            for (final o in all)
                              if (o.dependsOn.contains(m.id)) o.name,
                          ],
                          busy: _busy == m.id,
                          onChanged: m.required || _busy != null ? null : (v) => _toggle(m, v),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.module,
    required this.active,
    required this.needs,
    required this.neededBy,
    required this.busy,
    required this.onChanged,
  });
  final HmsModule module;
  final bool active;
  final List<String> needs;
  final List<String> neededBy;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m = module;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: active ? cs.primaryContainer : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(m.icon, color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant),
          ),
          Gap.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name, style: theme.textTheme.titleSmall),
                Gap.v4,
                Text(m.description, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                if (m.required || needs.isNotEmpty || neededBy.isNotEmpty) ...[
                  Gap.v8,
                  Wrap(
                    spacing: Gap.xs,
                    runSpacing: Gap.xs,
                    children: [
                      if (m.required) const StatusChip('Always on', icon: Icons.lock_outline, tone: Tone.info),
                      for (final n in needs) StatusChip('Needs $n', icon: Icons.link),
                      if (neededBy.isNotEmpty) StatusChip('Used by ${neededBy.join(', ')}'),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Gap.h12,
          SizedBox(
            width: 60,
            height: 40,
            child: busy
                ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : m.required
                    ? Tooltip(
                        message: 'Always on',
                        child: Icon(Icons.lock_outline, color: cs.onSurfaceVariant),
                      )
                    : Switch(value: active, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

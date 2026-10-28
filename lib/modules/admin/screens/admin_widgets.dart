import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';
import '../audit_format.dart';

/// A coloured box with an icon, a short title and an explanation.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.icon, required this.title, this.message, this.tone = Tone.info, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Tone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    final theme = Theme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
        if (message != null) ...[
          Gap.v4,
          Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: c.foreground)),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 520;
        final head = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, color: c.foreground, size: 22)),
            Gap.h12,
            Expanded(child: text),
            if (action != null && !narrow) ...[Gap.h12, action!],
          ],
        );
        if (action == null || !narrow) return head;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [head, Gap.v12, Padding(padding: const EdgeInsets.only(left: 34), child: action!)],
        );
      }),
    );
  }
}

class StaffStatusChip extends StatelessWidget {
  const StaffStatusChip(this.user, {super.key});
  final Rec user;

  @override
  Widget build(BuildContext context) {
    final s = Staff.statusOf(user);
    return StatusChip(s.label, tone: s.tone, icon: switch (s) {
      StaffStatus.locked => Icons.lock_outline,
      StaffStatus.off => Icons.block,
      StaffStatus.temporaryPassword => Icons.key_outlined,
      StaffStatus.active => null,
    });
  }
}

/// Role names as small chips.
class RoleChips extends StatelessWidget {
  const RoleChips({super.key, required this.roleIds, required this.roleNames});
  final List<String> roleIds;
  final Map<String, String> roleNames;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Gap.xs,
        runSpacing: Gap.xs,
        children: [
          for (final r in roleIds)
            StatusChip(roleNames[r] ?? titleCase(r), tone: r == Roles.owner ? Tone.board : Tone.neutral),
        ],
      );
}

String roleSummary(List<String> roleIds, Map<String, String> roleNames) =>
    roleIds.isEmpty ? 'No role' : roleIds.map((r) => roleNames[r] ?? titleCase(r)).join(', ');

Future<Map<String, String>> loadRoleNames(ReadDb db) async =>
    {for (final r in await db.query(const Query(Col.roles).sort('name').take(500))) r.id: r.str('name')};

/// A label with a large, easy-to-copy value (addresses, keys, passwords).
class BigValue extends StatelessWidget {
  const BigValue({super.key, required this.label, required this.value, this.copyable = true, this.caption});
  final String label;
  final String value;
  final bool copyable;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                Gap.v4,
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    value,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (caption != null)
                  Text(caption!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          if (copyable)
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                context.toast('Copied');
              },
            ),
        ],
      ),
    );
  }
}

/// Shows a new temporary password once, with what to tell the person.
Future<void> showTemporaryPassword(
  BuildContext context, {
  required String name,
  required String username,
  required String password,
  bool reset = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) {
      final theme = Theme.of(c);
      final first = name.split(' ').firstWhere((w) => w.isNotEmpty && !w.endsWith('.'), orElse: () => name);
      return AlertDialog(
        icon: Icon(reset ? Icons.lock_reset : Icons.how_to_reg_outlined),
        title: Text(reset ? 'New password for $name' : 'Account ready for $name'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Give $first these details in person or over the phone:'),
                Gap.v12,
                BigValue(label: 'Username', value: username),
                Gap.v8,
                BigValue(label: 'Temporary password', value: password),
                Gap.v12,
                Text(
                  '• When $first signs in, Kendra asks them to choose their own password straight away.\n'
                  '• This password is shown only once. If it is lost, use "Reset password".',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: 'Username: $username\nTemporary password: $password'));
              c.toast('Copied');
            },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('Copy both'),
          ),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
        ],
      );
    },
  );
}

/// For the most destructive actions: the person must type [word] to go on.
Future<bool> confirmByTyping(
  BuildContext context, {
  required String title,
  required String message,
  required String word,
  required String confirmLabel,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => _TypeToConfirm(title: title, message: message, word: word, confirmLabel: confirmLabel),
  );
  return r ?? false;
}

class _TypeToConfirm extends StatefulWidget {
  const _TypeToConfirm({required this.title, required this.message, required this.word, required this.confirmLabel});
  final String title;
  final String message;
  final String word;
  final String confirmLabel;

  @override
  State<_TypeToConfirm> createState() => _TypeToConfirmState();
}

class _TypeToConfirmState extends State<_TypeToConfirm> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = _ctrl.text.trim().toUpperCase() == widget.word;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: cs.error),
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            Gap.v16,
            TextField(
              controller: _ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Type ${widget.word} to confirm'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: ok ? () => Navigator.pop(context, true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A row in an "actions" card: what it does, and the button that does it.
class ActionRow extends StatelessWidget {
  const ActionRow({super.key, required this.title, required this.message, required this.button, this.icon});
  final String title;
  final String message;
  final Widget button;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 480;
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          Gap.v4,
          Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      );
      final lead = icon == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: Gap.md, top: 2),
              child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            );
      if (narrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [?lead, Expanded(child: text)]),
            Gap.v8,
            Padding(padding: EdgeInsets.only(left: icon == null ? 0 : 36), child: button),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [?lead, Expanded(child: text), Gap.h16, button],
      );
    });
  }
}

/// One "Field: old → new" line, with the arrow drawn as an icon.
class DiffLine extends StatelessWidget {
  const DiffLine(this.line, {super.key, this.style});
  final String line;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final st = style ?? Theme.of(context).textTheme.bodySmall;
    final parts = line.split(AuditFormat.arrow);
    return Text.rich(
      TextSpan(children: [
        for (final (i, p) in parts.indexed) ...[
          if (i > 0)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward, size: (st?.fontSize ?? 12) + 1, color: st?.color),
              ),
            ),
          TextSpan(text: p),
        ],
      ]),
      style: st,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

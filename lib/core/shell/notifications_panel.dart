import 'package:flutter/material.dart';

import '../contracts/collections.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../services/app_services.dart';
import '../ui/format.dart';
import '../ui/live.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// The bell in the top bar, with an unread count.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.session;
    if (s == null) return const SizedBox.shrink();
    return LiveBuilder<int>(
      watch: const {Col.notifications},
      deps: [s.userId],
      loading: const IconButton(onPressed: null, icon: Icon(Icons.notifications_none)),
      load: (db) => db.count(Query(Col.notifications).eq('user_id', s.userId).eq('read', false)),
      builder: (context, n) => IconButton(
        tooltip: n == 0 ? 'Notifications' : '$n unread',
        onPressed: () => _open(context),
        icon: Badge(
          isLabelVisible: n > 0,
          label: Text(n > 99 ? '99+' : '$n'),
          child: Icon(n > 0 ? Icons.notifications_active_outlined : Icons.notifications_none),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    if (context.isCompact) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.8, child: const _Panel()),
      );
    } else {
      showDialog<void>(
        context: context,
        barrierColor: Colors.black26,
        builder: (c) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 64, right: 16),
            child: Material(
              elevation: 12,
              borderRadius: BorderRadius.circular(Radii.lg),
              clipBehavior: Clip.antiAlias,
              child: const SizedBox(width: 420, height: 560, child: _Panel()),
            ),
          ),
        ),
      );
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final s = app.auth.session!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
          child: Row(children: [
            Expanded(child: Text('Notifications', style: theme.textTheme.titleMedium)),
            TextButton(
              onPressed: () => app.notifications.markAllRead(app.db, s.userId),
              child: const Text('Mark all read'),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: LiveBuilder<List<Rec>>(
            watch: const {Col.notifications},
            load: (db) => db.query(Query(Col.notifications).eq('user_id', s.userId).take(60)),
            builder: (context, items) {
              if (items.isEmpty) {
                return const EmptyState(
                    icon: Icons.notifications_none, title: 'All caught up', message: 'Nothing needs your attention.');
              }
              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final n = items[i];
                  final unread = !n.flag('read');
                  final tone = toneForSeverity(n.strOrNull('severity'));
                  final colors = ToneColors.of(c, tone);
                  return ListTile(
                    tileColor: unread ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25) : null,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: colors.background,
                      child: Icon(_icon(n.str('kind')), size: 18, color: colors.foreground),
                    ),
                    title: Text(n.str('title'),
                        style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [n.str('body'), formatRelative(n.createdAt)].where((x) => x.isNotEmpty).join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      if (unread) await app.db.update(Col.notifications, n.id, {'read': true});
                      if (!c.mounted) return;
                      Navigator.of(c).pop();
                      final route = n.strOrNull('route_id');
                      if (route != null) app.nav.open(route, n.map('route_args'));
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  static IconData _icon(String kind) => switch (kind) {
        'finding' => Icons.radar,
        'approval' => Icons.how_to_reg_outlined,
        'proposal' => Icons.lightbulb_outline,
        'briefing' => Icons.wb_sunny_outlined,
        _ => Icons.notifications_none,
      };
}

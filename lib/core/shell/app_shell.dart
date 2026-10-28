import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../contracts/collections.dart';
import '../data/remote/remote_store.dart';
import '../modules/module.dart';
import '../services/app_services.dart';
import '../tour/tour_anchor.dart';
import '../tour/tour_overlay.dart';
import '../ui/format.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'change_password.dart';
import 'command_palette.dart';
import 'notifications_panel.dart';

bool get _isApple => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;
String get modKey => _isApple ? '⌘' : 'Ctrl';

/// The signed-in frame around every screen.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late AppServices app;
  bool _init = false;
  Timer? _idleTimer;
  DateTime _lastActivity = DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    app = context.app;
    app.registry.addListener(_rebuild);
    app.nav.addListener(_rebuild);
    app.auth.addListener(_rebuild);
    HardwareKeyboard.instance.addHandler(_onKey);
    _idleTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkIdle());
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
  }

  @override
  void dispose() {
    app.registry.removeListener(_rebuild);
    app.nav.removeListener(_rebuild);
    app.auth.removeListener(_rebuild);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool _onKey(KeyEvent e) {
    _lastActivity = DateTime.now();
    return false;
  }

  void _checkIdle() {
    final mins = app.settings.idleLockMinutes;
    if (mins <= 0 || app.tour.active) return;
    if (DateTime.now().difference(_lastActivity) > Duration(minutes: mins)) app.auth.lock();
  }

  Future<void> _afterFirstFrame() async {
    final prefs = await app.prefs();
    final visible = _visibleRoutes();
    final last = prefs?.strOrNull('last_route');
    if (last != null && visible.any((r) => r.id == last)) {
      app.nav.select(last);
    } else if (app.nav.current == null && visible.isNotEmpty) {
      app.nav.select(visible.first.id);
    }
    if (!mounted) return;
    if (app.auth.session?.mustChangePassword ?? false) {
      await showChangePasswordDialog(context, forced: true);
    }
    await app.maybeStartTour();
  }

  List<ModuleRoute> _visibleRoutes() {
    final rs =
        app.registry.routes.where((r) => r.showInNav && (r.permission == null || app.auth.can(r.permission!))).toList()
          ..sort((a, b) {
            final s = a.section.index.compareTo(b.section.index);
            return s != 0 ? s : a.order.compareTo(b.order);
          });
    return rs;
  }

  void _go(ModuleRoute r) {
    app.nav.select(r.id);
    app.savePrefs({'last_route': r.id});
  }

  void _openPalette() => showCommandPalette(context, _visibleRoutes());

  @override
  Widget build(BuildContext context) {
    final routes = _visibleRoutes();
    final current = app.nav.current;
    final size = context.windowSize;

    final shortcuts = <ShortcutActivator, VoidCallback>{
      SingleActivator(LogicalKeyboardKey.keyK, meta: _isApple, control: !_isApple): _openPalette,
      SingleActivator(LogicalKeyboardKey.keyL, meta: _isApple, control: !_isApple): () => app.auth.lock(),
      for (var i = 0; i < routes.length && i < 9; i++)
        SingleActivator(
          LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
          meta: _isApple,
          control: !_isApple,
        ): () =>
            _go(routes[i]),
    };

    final content = _Content(current: current);

    Widget body;
    if (size == WindowSize.compact) {
      body = _CompactLayout(routes: routes, current: current, onGo: _go, onPalette: _openPalette, child: content);
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(routes: routes, current: current, onGo: _go, collapsed: size == WindowSize.medium),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(onPalette: _openPalette),
                const Divider(height: 1),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      );
    }

    return Listener(
      onPointerDown: (_) => _lastActivity = DateTime.now(),
      onPointerSignal: (_) => _lastActivity = DateTime.now(),
      child: CallbackShortcuts(
        bindings: shortcuts,
        child: Focus(
          autofocus: true,
          child: TourOverlay(child: Material(child: body)),
        ),
      ),
    );
  }
}

/// The nested navigator that holds the current screen and its detail pages.
class _Content extends StatelessWidget {
  const _Content({required this.current});
  final String? current;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final route = current == null ? null : app.registry.route(current!);
    final Widget root = route == null
        ? const EmptyState(
            icon: Icons.dashboard_outlined,
            title: 'Nothing here yet',
            message: 'Choose a screen from the menu.',
          )
        : Builder(builder: (c) => route.builder(c, app.nav.args));
    return NavigatorPopHandler(
      onPopWithResult: (_) => app.nav.contentKey.currentState?.maybePop(),
      child: Navigator(
        key: app.nav.contentKey,
        pages: [_InstantPage(key: ValueKey('${current}_${app.nav.args.hashCode}'), child: root)],
        onDidRemovePage: (_) {},
      ),
    );
  }
}

/// Switching top-level screens should feel instant, not slide.
class _InstantPage extends Page<void> {
  const _InstantPage({required LocalKey super.key, required this.child});
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _InstantRoute(this);
}

class _InstantRoute extends PageRoute<void> {
  _InstantRoute(_InstantPage page) : super(settings: page);

  // Reads the child from the current page so rebuilds reach the screen.
  _InstantPage get _page => settings as _InstantPage;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _page.child;

  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final mark = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(9)),
      child: Icon(Icons.local_hospital_outlined, color: theme.colorScheme.onPrimary, size: 20),
    );
    if (compact) return mark;
    return Row(
      children: [
        mark,
        Gap.h12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                app.settings.hospitalName,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Kendra HMS',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.routes, required this.current, required this.onGo, required this.collapsed});
  final List<ModuleRoute> routes;
  final String? current;
  final void Function(ModuleRoute) onGo;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = <Widget>[];
    NavSection? section;
    for (final r in routes) {
      if (r.section != section) {
        section = r.section;
        if (collapsed) {
          if (items.isNotEmpty) {
            items.add(const Padding(padding: EdgeInsets.symmetric(vertical: 6, horizontal: 16), child: Divider()));
          }
        } else if (r.section != NavSection.home) {
          items.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
              child: Text(
                r.section.label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        }
      }
      final selected = r.id == current;
      final tile = Padding(
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 12 : 10, vertical: 1),
        child: Material(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => onGo(r),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 12, vertical: 10),
              child: Row(
                mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  Icon(r.icon, size: 22, color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                  if (!collapsed) ...[
                    Gap.h12,
                    Expanded(
                      child: Text(
                        r.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? cs.onPrimaryContainer : cs.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      items.add(
        TourAnchor(
          id: 'nav.${r.id}',
          child: collapsed ? Tooltip(message: r.title, child: tile) : tile,
        ),
      );
    }

    return Container(
      width: collapsed ? 76 : 256,
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(collapsed ? 21 : 18, 18, 12, 12),
            child: _Brand(compact: collapsed),
          ),
          Expanded(
            child: TourAnchor(
              id: 'shell.nav',
              child: ListView(padding: const EdgeInsets.only(bottom: 12), children: items),
            ),
          ),
          if (!collapsed) const _DeviceFooter(),
        ],
      ),
    );
  }
}

class _DeviceFooter extends StatelessWidget {
  const _DeviceFooter();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final String text;
    final Tone tone;
    if (app.isDemo) {
      text = 'Demo hospital · sample data';
      tone = Tone.warning;
    } else if (app.remote != null) {
      text = 'Connected to hub';
      tone = Tone.success;
    } else if (app.hub?.running ?? false) {
      text = 'Hub on · sharing with other devices';
      tone = Tone.info;
    } else {
      text = 'This device only';
      tone = Tone.neutral;
    }
    final c = ToneColors.of(context, tone);
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.md)),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: c.foreground)),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onPalette, this.compact = false});
  final VoidCallback onPalette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      height: compact ? 56 : 64,
      color: cs.surface,
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 20),
      child: Row(
        children: [
          if (compact) ...[const SizedBox(width: 8), const _Brand(compact: true), Gap.h12],
          if (compact)
            Expanded(
              child: Text(
                context.app.settings.hospitalName,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: TourAnchor(
                    id: 'shell.palette',
                    child: InkWell(
                      onTap: onPalette,
                      borderRadius: BorderRadius.circular(Radii.md),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(Radii.md),
                          border: Border.all(color: cs.outlineVariant),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.search, size: 20, color: cs.onSurfaceVariant),
                            Gap.h8,
                            Expanded(
                              child: Text(
                                'Search patients, screens and actions',
                                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _KeyCap('$modKey K'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (compact)
            TourAnchor(
              id: 'shell.palette',
              child: IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: onPalette),
            ),
          const _LinkStatus(),
          const TourAnchor(id: 'shell.bell', child: NotificationBell()),
          Gap.h4,
          const TourAnchor(id: 'shell.profile', child: _ProfileMenu()),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Shows "Offline – reconnecting" on client devices when the hub is unreachable.
class _LinkStatus extends StatelessWidget {
  const _LinkStatus();

  @override
  Widget build(BuildContext context) {
    final remote = context.app.remote;
    if (remote == null) return const SizedBox.shrink();
    return ValueListenableBuilder<HubLink>(
      valueListenable: remote.link,
      builder: (context, link, _) {
        if (link == HubLink.online) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(link == HubLink.offline ? Icons.cloud_off : Icons.sync, size: 16),
            label: Text(link == HubLink.offline ? 'Offline · retrying' : 'Connecting'),
            onPressed: remote.reconnectNow,
          ),
        );
      },
    );
  }
}

class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final s = app.auth.session;
    if (s == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Your account',
      position: PopupMenuPosition.under,
      onSelected: (v) async {
        switch (v) {
          case 'password':
            await showChangePasswordDialog(context);
          case 'tour':
            app.startTour();
          case 'light':
            await app.setThemeMode(ThemeMode.light);
          case 'dark':
            await app.setThemeMode(ThemeMode.dark);
          case 'system':
            await app.setThemeMode(ThemeMode.system);
          case 'lock':
            await app.auth.lock();
          case 'logout':
            await app.auth.logout();
        }
      },
      itemBuilder: (c) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.displayName, style: Theme.of(c).textTheme.titleSmall),
              Text('@${s.username} · ${s.roleIds.map(titleCase).join(', ')}', style: Theme.of(c).textTheme.bodySmall),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'tour',
          child: ListTile(leading: Icon(Icons.explore_outlined), title: Text('Take the tour')),
        ),
        const PopupMenuItem(
          value: 'password',
          child: ListTile(leading: Icon(Icons.password), title: Text('Change password')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'light',
          child: ListTile(
            leading: const Icon(Icons.light_mode_outlined),
            title: const Text('Light'),
            trailing: app.themeMode.value == ThemeMode.light ? const Icon(Icons.check) : null,
          ),
        ),
        PopupMenuItem(
          value: 'dark',
          child: ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('Dark'),
            trailing: app.themeMode.value == ThemeMode.dark ? const Icon(Icons.check) : null,
          ),
        ),
        PopupMenuItem(
          value: 'system',
          child: ListTile(
            leading: const Icon(Icons.brightness_auto_outlined),
            title: const Text('Match system'),
            trailing: app.themeMode.value == ThemeMode.system ? const Icon(Icons.check) : null,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'lock',
          child: ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Lock screen'),
            trailing: Text('$modKey L'),
          ),
        ),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out')),
        ),
      ],
      child: Padding(padding: const EdgeInsets.all(4), child: Avatar(s.displayName, size: 34)),
    );
  }
}

class _CompactLayout extends StatelessWidget {
  const _CompactLayout({
    required this.routes,
    required this.current,
    required this.onGo,
    required this.onPalette,
    required this.child,
  });
  final List<ModuleRoute> routes;
  final String? current;
  final void Function(ModuleRoute) onGo;
  final VoidCallback onPalette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pinned = [...routes.where((r) => r.mobilePriority != null)]
      ..sort((a, b) => a.mobilePriority!.compareTo(b.mobilePriority!));
    final bar = <ModuleRoute>[...pinned.take(4)];
    for (final r in routes) {
      if (bar.length >= 4) break;
      if (!bar.contains(r)) bar.add(r);
    }
    final idx = bar.indexWhere((r) => r.id == current);
    final hasMore = routes.length > bar.length;

    return Column(
      children: [
        SafeArea(bottom: false, child: _TopBar(onPalette: onPalette, compact: true)),
        const Divider(height: 1),
        Expanded(child: child),
        // NavigationBar needs at least two destinations.
        if (bar.length + (hasMore ? 1 : 0) >= 2)
          TourAnchor(
            id: 'shell.nav',
            child: NavigationBar(
              selectedIndex: idx < 0 ? (hasMore ? bar.length : 0) : idx,
              onDestinationSelected: (i) {
                if (i < bar.length) {
                  onGo(bar[i]);
                } else {
                  _showMore(context);
                }
              },
              destinations: [
                for (final r in bar) NavigationDestination(icon: Icon(r.icon), label: r.title),
                if (hasMore) const NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
              ],
            ),
          ),
      ],
    );
  }

  void _showMore(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => ListView(
          controller: scroll,
          children: [
            for (final r in routes)
              ListTile(
                leading: Icon(r.icon),
                title: Text(r.title),
                subtitle: Text(r.section.label),
                selected: r.id == current,
                onTap: () {
                  Navigator.pop(c);
                  onGo(r);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Count badge helper for nav items and the bell.
Future<int> unreadCount(AppServices app) async {
  final s = app.auth.session;
  if (s == null) return 0;
  return app.store.count(app.notifications.unreadFor(s.userId));
}

const notificationsCollection = Col.notifications;

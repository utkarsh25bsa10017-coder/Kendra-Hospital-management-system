import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../contracts/collections.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../modules/module.dart';
import '../services/app_services.dart';
import '../ui/format.dart';
import '../ui/tokens.dart';

class _Item {
  _Item(this.icon, this.title, this.subtitle, this.run);
  final IconData icon;
  final String title;
  final String subtitle;
  final void Function(BuildContext) run;
}

/// Ctrl/Cmd + K: find a patient, open a screen or start an action by typing.
Future<void> showCommandPalette(BuildContext context, List<ModuleRoute> routes) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black38,
    builder: (_) => _Palette(routes: routes),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.routes});
  final List<ModuleRoute> routes;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _ctrl = TextEditingController();
  String _q = '';
  int _sel = 0;
  List<Rec> _patients = const [];
  int _gen = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _matches(String text, List<String> extra) {
    if (_q.isEmpty) return true;
    final hay = [text, ...extra].join(' ').toLowerCase();
    return _q.toLowerCase().split(RegExp(r'\s+')).every(hay.contains);
  }

  Future<void> _searchPatients() async {
    final app = context.app;
    final g = ++_gen;
    if (_q.length < 2 || app.registry.route('patients.profile') == null) {
      setState(() => _patients = const []);
      return;
    }
    try {
      final r = await app.store.query(const Query(Col.patients).matching(_q).take(6));
      if (mounted && g == _gen) setState(() => _patients = r);
    } catch (_) {}
  }

  List<_Item> _items(AppServices app) {
    final out = <_Item>[];
    for (final p in _patients) {
      out.add(_Item(
        Icons.person_outline,
        p.str('full_name'),
        '${p.str('uhid')} · ${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${p.str('phone')}',
        (c) => app.nav.open('patients.profile', {'id': p.id}),
      ));
    }
    for (final a in app.registry.quickActions) {
      if (a.permission != null && !app.auth.can(a.permission!)) continue;
      if (_matches(a.label, a.keywords)) out.add(_Item(a.icon, a.label, 'Action', a.run));
    }
    for (final r in widget.routes) {
      if (_matches(r.title, [r.section.label, r.description])) {
        out.add(_Item(r.icon, r.title, r.section.label, (c) => app.nav.select(r.id)));
      }
    }
    return out;
  }

  void _run(_Item item) {
    Navigator.pop(context);
    item.run(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final items = _items(app);
    if (_sel >= items.length) _sel = items.isEmpty ? 0 : items.length - 1;

    return Align(
      alignment: const Alignment(0, -0.6),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 16,
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 620, maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Focus(
                onKeyEvent: (_, e) {
                  if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
                  if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                    setState(() => _sel = (_sel + 1).clamp(0, items.isEmpty ? 0 : items.length - 1));
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() => _sel = (_sel - 1).clamp(0, items.isEmpty ? 0 : items.length - 1));
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.enter && items.isNotEmpty) {
                    _run(items[_sel]);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Type a patient name, UHID, phone, or what you want to do',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) {
                      setState(() {
                        _q = v.trim();
                        _sel = 0;
                      });
                      _searchPatients();
                    },
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: items.isEmpty
                    ? const Padding(padding: EdgeInsets.all(24), child: Text('No matches'))
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: items.length,
                        itemBuilder: (c, i) {
                          final it = items[i];
                          return ListTile(
                            dense: true,
                            selected: i == _sel,
                            selectedTileColor: theme.colorScheme.primaryContainer,
                            leading: Icon(it.icon),
                            title: Text(it.title),
                            subtitle: Text(it.subtitle),
                            onTap: () => _run(it),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: theme.colorScheme.surfaceContainerLow,
                child: Row(children: [
                  Text('↑ ↓ to move · Enter to open · Esc to close',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

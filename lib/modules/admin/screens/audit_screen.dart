import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../audit_format.dart';
import 'admin_widgets.dart';

enum _When { any, today, week, month, custom }

/// Who did what, when, on which device. Append-only and hash-chained.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key, this.actorId});

  /// Show one person's entries (opened from a staff account).
  final String? actorId;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  static const _pageSize = 50;

  late String _actor = widget.actorId ?? '';
  String _table = '';
  String _action = '';
  _When _when = _When.any;
  DateTimeRange? _range;

  List<AuditEntry> _entries = const [];
  bool _loading = true;
  bool _hasMore = false;
  int _generation = 0;
  Map<String, String> _people = const {};
  Map<String, String> _names = const {};
  AuditVerification? _check;
  bool _checking = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loadPeople();
    _load();
  }

  Future<void> _loadPeople() async {
    final users = await context.app.readDb.query(const Query(Col.users).withArchived().sort('display_name').take(2000));
    if (mounted) setState(() => _people = {for (final u in users) u.id: u.str('display_name')});
  }

  (DateTime?, DateTime?) _dates() {
    final now = DateTime.now();
    return switch (_when) {
      _When.any => (null, null),
      _When.today => (startOfDay(now), null),
      _When.week => (startOfDay(now).subtract(const Duration(days: 6)), null),
      _When.month => (startOfDay(now).subtract(const Duration(days: 29)), null),
      _When.custom => _range == null ? (null, null) : (startOfDay(_range!.start), endOfDay(_range!.end)),
    };
  }

  Future<void> _load({bool more = false}) async {
    final app = context.app;
    final gen = ++_generation;
    setState(() => _loading = true);
    final (from, to) = _dates();
    try {
      final page = await app.store.auditLog(AuditFilter(
        actorId: _actor.isEmpty ? null : _actor,
        collection: _table.isEmpty ? null : _table,
        action: _action.isEmpty ? null : _action,
        from: from,
        to: to,
        beforeSeq: more && _entries.isNotEmpty ? _entries.last.seq : null,
        limit: _pageSize,
      ));
      final names = await _recordNames(app, page);
      if (!mounted || gen != _generation) return;
      setState(() {
        _entries = more ? [..._entries, ...page] : page;
        _names = more ? {..._names, ...names} : names;
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _loading = false);
      app.nav.toast('Could not load the audit log: $e', error: true);
    }
  }

  /// Readable names for the patients and staff the entries mention.
  static Future<Map<String, String>> _recordNames(AppServices app, List<AuditEntry> page) async {
    final out = <String, String>{};
    final patients = page.where((e) => e.collection == Col.patients).map((e) => e.recordId);
    for (final p in (await app.readDb.byIds(Col.patients, patients)).values) {
      out[p.id] = '${p.str('full_name')} · ${p.str('uhid')}';
    }
    final users = page.where((e) => e.collection == Col.users).map((e) => e.recordId);
    for (final u in (await app.readDb.byIds(Col.users, users)).values) {
      out[u.id] = u.str('display_name');
    }
    final roles = page.where((e) => e.collection == Col.roles).map((e) => e.recordId);
    for (final r in (await app.readDb.byIds(Col.roles, roles)).values) {
      out[r.id] = r.str('name');
    }
    return out;
  }

  void _set(VoidCallback change) {
    setState(change);
    _load();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
      initialDateRange: _range ?? DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    );
    if (r == null) return;
    _set(() {
      _range = r;
      _when = _When.custom;
    });
  }

  Future<void> _verify() async {
    final app = context.app;
    setState(() => _checking = true);
    try {
      final v = await app.store.verifyAudit();
      if (mounted) setState(() => _check = v);
    } catch (e) {
      app.nav.toast('Could not check the log: $e', error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _device(AuditEntry e) {
    final app = context.app;
    if (e.deviceId.isEmpty) return '';
    if (e.deviceId == app.config.deviceId) return 'This device';
    final id = e.deviceId;
    return 'Device ${id.length > 6 ? id.substring(id.length - 6) : id}';
  }

  String _record(AuditEntry e) {
    if (e.collection == null) return '';
    final name = e.recordId == null ? null : _names[e.recordId];
    final rid = e.recordId ?? '';
    // Settings and roles use readable keys as ids; generated ids are shortened.
    if (name == null && (e.collection == Col.settings || e.collection == Col.roles)) return rid;
    return name ?? (rid.isEmpty ? '' : '#${rid.length > 8 ? rid.substring(rid.length - 8) : rid}');
  }

  (String, Map<String, Object?>)? _link(AuditEntry e) {
    final id = e.recordId;
    if (id == null || id.isEmpty) return null;
    final route = switch (e.collection) {
      Col.patients => 'patients.profile',
      Col.users => 'admin.user',
      Col.roles => 'admin.role',
      Col.findings => 'tower.findings',
      _ => null,
    };
    if (route == null || !context.app.nav.canOpen(route)) return null;
    return (route, {'id': id});
  }

  void _open(AuditEntry e) {
    final l = _link(e);
    if (l != null) context.app.nav.open(l.$1, l.$2);
  }

  String _rangeLabel() {
    final r = _range;
    if (r == null) return 'Choose dates…';
    return '${formatDateShort(r.start)} – ${formatDateShort(r.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final tables = app.schemas.all.map((s) => s.name).toList()..sort();
    final check = _check;

    final filters = FormGrid(minFieldWidth: context.isCompact ? 160 : 180, maxColumns: 4, children: [
      AppDropdown<String>(
        label: 'Person',
        value: _actor,
        items: [
          ('', 'Everyone'),
          ('system', 'Kendra (automatic)'),
          for (final e in _people.entries) (e.key, e.value),
          if (_actor.isNotEmpty && _actor != 'system' && !_people.containsKey(_actor)) (_actor, 'Selected person'),
        ],
        onChanged: (v) => _set(() => _actor = v ?? ''),
      ),
      AppDropdown<String>(
        label: 'Table',
        value: _table,
        items: [('', 'All tables'), for (final t in tables) (t, AuditFormat.collection(t))],
        onChanged: (v) => _set(() => _table = v ?? ''),
      ),
      AppDropdown<String>(
        label: 'Action',
        value: _action,
        items: [('', 'All actions'), for (final a in AuditFormat.actions.entries) (a.key, a.value)],
        onChanged: (v) => _set(() => _action = v ?? ''),
      ),
      AppDropdown<_When>(
        // Rebuilt when the choice changes, so a cancelled date picker shows the old choice again.
        key: ValueKey('when:$_when:$_range'),
        label: 'When',
        value: _when,
        items: [
          (_When.any, 'Any time'),
          (_When.today, 'Today'),
          (_When.week, 'Last 7 days'),
          (_When.month, 'Last 30 days'),
          (_When.custom, _rangeLabel()),
        ],
        onChanged: (v) {
          if (v == _When.custom) {
            _pickRange();
          } else if (v != null) {
            _set(() => _when = v);
          }
        },
      ),
    ]);

    return PageScaffold(
      title: 'Audit log',
      subtitle: 'Every change and sign-in, with who did it and on which device. Entries can never be edited.',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _loading ? null : () => _load()),
      ],
      headerBottom: filters,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (check == null)
            SectionCard(
              child: ActionRow(
                icon: Icons.fact_check_outlined,
                title: 'Check that nothing was tampered with',
                message: 'Each entry is sealed to the one before it. The check confirms that no entry was changed '
                    'or removed since it was written.',
                button: OutlinedButton.icon(
                  onPressed: _checking ? null : _verify,
                  icon: _checking
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(_checking ? 'Checking…' : 'Check integrity'),
                ),
              ),
            )
          else if (check.ok)
            NoticeBanner(
              icon: Icons.verified_user_outlined,
              tone: Tone.success,
              title: 'All ${formatNumber(check.checked)} entries intact',
              message: 'Nobody has changed or removed anything in the log.',
              action: TextButton(onPressed: _checking ? null : _verify, child: const Text('Check again')),
            )
          else
            NoticeBanner(
              icon: Icons.gpp_bad_outlined,
              tone: Tone.danger,
              title: 'Entry ${check.brokenAtSeq ?? '?'} was altered',
              message: '${check.message}. Keep the current database and a backup as they are, and contact '
                  'whoever supports Kendra for your hospital.',
              action: TextButton(onPressed: _checking ? null : _verify, child: const Text('Check again')),
            ),
          Gap.v16,
          if (_loading && _entries.isEmpty)
            const LoadingView()
          else
            DataList<AuditEntry>(
              items: _entries,
              empty: const EmptyState(
                icon: Icons.history,
                title: 'No entries match',
                message: 'Try another person, table or date range.',
              ),
              onTap: _open,
              title: (e) => '${e.actorName} · ${AuditFormat.action(e.action)}'
                  '${e.collection == null ? '' : ' ${AuditFormat.collection(e.collection).toLowerCase()}'}',
              subtitle: (e) => [
                [formatDateTime(e.ts), _device(e)].where((s) => s.isNotEmpty).join(' · '),
                if (_record(e).isNotEmpty) _record(e),
                ...AuditFormat.details(app.schemas, e, max: 2).map(AuditFormat.plain),
              ].join('\n'),
              columns: [
                ListColumn('When', (e) => TwoLine(formatDate(e.ts), formatTime(e.ts)), width: 120),
                ListColumn('Who', (e) => TwoLine(e.actorName, _device(e)), flex: 3),
                ListColumn(
                  'Action',
                  (e) => StatusChip(AuditFormat.action(e.action), tone: AuditFormat.tone(e.action)),
                  width: 150,
                ),
                ListColumn('Record', (e) {
                  final linked = _link(e) != null;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(AuditFormat.collection(e.collection), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      if (_record(e).isNotEmpty)
                        Text(
                          _record(e),
                          overflow: TextOverflow.ellipsis,
                          style: muted?.copyWith(
                            color: linked ? theme.colorScheme.primary : null,
                            decoration: linked ? TextDecoration.underline : null,
                          ),
                        ),
                    ],
                  );
                }, flex: 3),
                ListColumn('Details', (e) {
                  final lines = AuditFormat.details(app.schemas, e);
                  if (lines.isEmpty) return Text('—', style: muted);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [for (final l in lines) DiffLine(l)],
                  );
                }, flex: 6),
              ],
            ),
          if (_entries.isNotEmpty) ...[
            Gap.v12,
            Row(
              children: [
                Expanded(child: Text('Showing the newest ${formatNumber(_entries.length)} matching entries', style: muted)),
                if (_hasMore)
                  OutlinedButton.icon(
                    onPressed: _loading ? null : () => _load(more: true),
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Show older'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

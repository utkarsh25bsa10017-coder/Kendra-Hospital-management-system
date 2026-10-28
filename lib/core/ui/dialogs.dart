import 'package:flutter/material.dart';

import '../contracts/collections.dart';
import '../data/db.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../services/app_services.dart';
import 'format.dart';
import 'tokens.dart';
import 'widgets.dart';

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final cs = Theme.of(context).colorScheme;
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: message == null ? null : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Asks for a written reason. [presets] are one-tap choices that fill the box.
Future<String?> reasonDialog(
  BuildContext context, {
  required String title,
  String? message,
  String label = 'Reason',
  String confirmLabel = 'Save',
  List<String> presets = const [],
  bool destructive = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (c) => _ReasonDialog(
      title: title,
      message: message,
      label: label,
      confirmLabel: confirmLabel,
      presets: presets,
      destructive: destructive,
    ),
  );
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.message,
    required this.label,
    required this.confirmLabel,
    required this.presets,
    required this.destructive,
  });
  final String title;
  final String? message;
  final String label;
  final String confirmLabel;
  final List<String> presets;
  final bool destructive;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message != null) ...[Text(widget.message!), Gap.v12],
            if (widget.presets.isNotEmpty) ...[
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final p in widget.presets)
                    ActionChip(label: Text(p), onPressed: () => setState(() => _ctrl.text = p)),
                ],
              ),
              Gap.v12,
            ],
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: widget.label),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: widget.destructive ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
          onPressed: ok ? () => Navigator.pop(context, _ctrl.text.trim()) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A form in a dialog on desktop, or a full-screen page on phones.
Future<T?> showFormSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) builder, double width = 640}) {
  if (context.isCompact) {
    return Navigator.of(context).push<T>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (c) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(Gap.lg), child: builder(c))),
      ),
    ));
  }
  return showDialog<T>(
    context: context,
    builder: (c) => Dialog(
      insetPadding: const EdgeInsets.all(Gap.xl),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.sizeOf(c).height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
              child: Row(children: [
                Expanded(child: Text(title, style: Theme.of(c).textTheme.titleLarge)),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(c)),
              ]),
            ),
            Flexible(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), child: builder(c))),
          ],
        ),
      ),
    ),
  );
}

/// Searchable picker for any collection.
Future<Rec?> pickRecord(
  BuildContext context, {
  required String title,
  required Query Function(String search) query,
  required String Function(Rec r) itemTitle,
  String Function(Rec r)? itemSubtitle,
  Widget Function(Rec r)? itemTrailing,
  String emptyText = 'Nothing found',
  Widget? footer,
}) {
  return showDialog<Rec>(
    context: context,
    builder: (c) => _PickerDialog(
      title: title,
      query: query,
      itemTitle: itemTitle,
      itemSubtitle: itemSubtitle,
      itemTrailing: itemTrailing,
      emptyText: emptyText,
      footer: footer,
    ),
  );
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({
    required this.title,
    required this.query,
    required this.itemTitle,
    this.itemSubtitle,
    this.itemTrailing,
    required this.emptyText,
    this.footer,
  });
  final String title;
  final Query Function(String) query;
  final String Function(Rec) itemTitle;
  final String Function(Rec)? itemSubtitle;
  final Widget Function(Rec)? itemTrailing;
  final String emptyText;
  final Widget? footer;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  String _search = '';
  List<Rec>? _items;
  late ReadDb _db;
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _db = context.app.readDb;
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final g = ++_gen;
    final r = await _db.query(widget.query(_search));
    if (mounted && g == _gen) setState(() => _items = r);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: theme.textTheme.titleLarge),
              Gap.v12,
              SearchField(
                autofocus: true,
                hint: 'Type to search',
                onChanged: (v) {
                  _search = v;
                  _load();
                },
              ),
              Gap.v8,
              Flexible(
                child: items == null
                    ? const LoadingView()
                    : items.isEmpty
                        ? Padding(padding: const EdgeInsets.all(24), child: Text(widget.emptyText, textAlign: TextAlign.center))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: items.length,
                            itemBuilder: (c, i) {
                              final r = items[i];
                              return ListTile(
                                title: Text(widget.itemTitle(r)),
                                subtitle: widget.itemSubtitle == null ? null : Text(widget.itemSubtitle!(r)),
                                trailing: widget.itemTrailing?.call(r),
                                onTap: () => Navigator.pop(context, r),
                              );
                            },
                          ),
              ),
              if (widget.footer != null) ...[Gap.v8, widget.footer!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Pick a patient by name, UHID or phone.
Future<Rec?> pickPatient(BuildContext context, {String title = 'Choose patient'}) => pickRecord(
      context,
      title: title,
      query: (s) => const Query(Col.patients).matching(s).sort('updated_at', desc: true).take(30),
      itemTitle: (p) => p.str('full_name'),
      itemSubtitle: (p) => [
        p.str('uhid'),
        ageLabel(p.date('dob'), p.intOrNull('age_years')),
        genderLabel(p.strOrNull('gender')),
        p.str('phone'),
      ].where((s) => s.isNotEmpty && s != '—').join(' · '),
      emptyText: 'No patient matches. Register them first.',
    );

/// Pick a clinician (staff marked as doctors).
Future<Rec?> pickDoctor(BuildContext context) => pickRecord(
      context,
      title: 'Choose doctor',
      query: (s) => const Query(Col.users).eq('is_clinician', true).eq('active', true).matching(s).sort('display_name'),
      itemTitle: (u) => u.str('display_name'),
      itemSubtitle: (u) => [u.str('department'), u.str('specialization')].where((s) => s.isNotEmpty).join(' · '),
      emptyText: 'No doctors yet. Add staff marked as clinicians in Administration.',
    );

/// Runs [action], showing friendly errors as a toast. Returns true on success.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  final app = context.app;
  try {
    await action();
    if (success != null) app.nav.toast(success);
    return true;
  } on ValidationException catch (e) {
    app.nav.toast(e.message, error: true);
  } on ConflictException catch (e) {
    app.nav.toast(e.message, error: true);
  } on PermissionDeniedException catch (e) {
    app.nav.toast(e.message, error: true);
  } catch (e) {
    app.nav.toast(e.toString(), error: true);
  }
  return false;
}

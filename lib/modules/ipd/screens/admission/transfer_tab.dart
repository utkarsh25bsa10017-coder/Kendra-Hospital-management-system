import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../../ipd_schema.dart';
import '../../ipd_service.dart';
import '../../widgets/ipd_widgets.dart';
import '../admission_screen.dart';

/// Move the patient to another free bed; shows where they have been.
class TransferTab extends StatefulWidget {
  const TransferTab({super.key, required this.view});
  final AdmissionView view;

  @override
  State<TransferTab> createState() => _TransferTabState();
}

class _TransferTabState extends State<TransferTab> {
  static const _presets = [
    'Patient request',
    'Upgrade to private room',
    'Needs ICU care',
    'Step down from ICU',
    'Isolation needed',
    'Bed needs repair',
  ];

  Rec? _to;
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _transfer() async {
    final app = context.app;
    final to = _to;
    if (to == null) {
      app.nav.toast('Choose the new bed', error: true);
      return;
    }
    if (_reason.text.trim().isEmpty) {
      app.nav.toast('Say why the patient is moving', error: true);
      return;
    }
    final from = widget.view.bedLabel;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => IpdService.transfer(app.db, widget.view.admission,
          toBedId: to.id, reason: _reason.text, byName: app.auth.session?.displayName),
      success: 'Moved to ${to.str('label')}. $from is marked for cleaning.',
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _to = null;
        _reason.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final theme = Theme.of(context);
    final canMove = context.can(IpdPerms.admit) && !v.discharged;
    final history = _History(view: v);
    if (!canMove) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (v.discharged)
            const ToneBanner(tone: Tone.neutral, icon: Icons.info_outline, title: 'This patient has been discharged'),
          if (v.discharged) Gap.v16,
          history,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Move to another bed',
          subtitle: 'Now in ${v.bedLabel}${v.wardName.isEmpty ? '' : ' · ${v.wardName}'}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FreeBedPicker(
                selected: _to,
                initialWardId: v.admission.strOrNull('ward_id'),
                excludeBedId: v.bed?.id,
                onChanged: (b) => setState(() => _to = b),
              ),
              Gap.v16,
              const SubHeading('Reason'),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final p in _presets)
                    ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
                ],
              ),
              Gap.v12,
              AppTextField(label: 'Reason for the move', controller: _reason, textCapitalization: TextCapitalization.sentences),
              Gap.v16,
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Gap.md,
                runSpacing: Gap.sm,
                children: [
                  Text(
                    '${v.bedLabel} goes for cleaning. From tomorrow, bed-days are charged at the new ward\'s rate.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  FilledButton.icon(
                    onPressed: _saving ? null : _transfer,
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(_to == null ? 'Transfer' : 'Transfer to ${_to!.str('label')}'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Gap.v16,
        history,
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.view});
  final AdmissionView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = view.admission;
    return LiveBuilder<(List<Rec>, Map<String, Rec>, Map<String, Rec>)>(
      watch: const {IpdCol.transfers},
      deps: [a.id],
      load: (db) async {
        final t = await db.query(Query(IpdCol.transfers).eq('admission_id', a.id).sort('at').take(200));
        final beds = await db.byIds(IpdCol.beds, [a.strOrNull('bed_id'), for (final x in t) ...[x.strOrNull('from_bed_id'), x.strOrNull('to_bed_id')]]);
        final wards = await db.byIds(IpdCol.wards, [
          a.strOrNull('ward_id'),
          for (final x in t) ...[x.strOrNull('from_ward_id'), x.strOrNull('to_ward_id')],
        ]);
        return (t, beds, wards);
      },
      builder: (context, data) {
        final (transfers, beds, wards) = data;
        String place(String? bedId, String? wardId) =>
            [beds[bedId]?.str('label') ?? 'Bed', if (wards[wardId] != null) wards[wardId]!.str('name')].join(' · ');
        final firstBed = transfers.isEmpty ? a.strOrNull('bed_id') : transfers.first.strOrNull('from_bed_id');
        final firstWard = transfers.isEmpty ? a.strOrNull('ward_id') : transfers.first.strOrNull('from_ward_id');
        final rows = <(IconData, String, String, String?)>[
          (Icons.login, 'Admitted to ${place(firstBed, firstWard)}', formatDateTime(a.date('admitted_at')), null),
          for (final t in transfers)
            (
              Icons.swap_horiz,
              'Moved to ${place(t.strOrNull('to_bed_id'), t.strOrNull('to_ward_id'))}',
              [formatDateTime(t.date('at')), if (t.str('by_name').isNotEmpty) t.str('by_name')].join(' · '),
              t.str('reason'),
            ),
          if (view.discharged) (Icons.logout, 'Discharged', formatDateTime(a.date('discharged_at')), null),
        ];
        return SectionCard(
          title: 'Bed history',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, (icon, title, time, reason)) in rows.indexed) ...[
                if (i > 0) const Divider(height: Gap.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: theme.colorScheme.primary),
                    Gap.h12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleSmall),
                          Text(time, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          if (reason != null && reason.isNotEmpty) ...[Gap.v4, Text(reason)],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

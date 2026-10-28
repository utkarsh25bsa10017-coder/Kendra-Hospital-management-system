import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';
import 'lab_widgets.dart';

/// The report as it is handed to the patient: hospital header, patient and
/// sample details, values with flags and reference intervals, signatures.
class LabReportView extends StatelessWidget {
  const LabReportView({super.key, required this.item});
  final LabItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.app.settings;
    final order = item.order;
    final result = item.result;
    final patient = item.patient;
    final values = result?.maps('values') ?? const [];
    final verified = result?.str('status') == ResultStatus.verified;
    final amended = (result?.maps('history') ?? const []).isNotEmpty;
    final compact = context.isCompact;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final address = [settings.str(SettingKeys.hospitalAddress), settings.str(SettingKeys.hospitalPhone)]
        .where((s) => s.isNotEmpty)
        .join(' · ');

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(Radii.md)),
          child: Icon(Icons.local_hospital_outlined, color: theme.colorScheme.onPrimary),
        ),
        Gap.h12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(settings.hospitalName, style: theme.textTheme.titleLarge),
              if (address.isNotEmpty) Text(address, style: muted),
              Text('Department of Laboratory Medicine', style: muted),
            ],
          ),
        ),
        if (!compact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('LABORATORY REPORT',
                  style: theme.textTheme.labelLarge?.copyWith(letterSpacing: 1.2, color: theme.colorScheme.primary)),
              Text(departmentLabel(item.test?.str('department')), style: muted),
            ],
          ),
      ],
    );

    final details = <(String, String)>[
      ('Patient', item.patientName),
      ('UHID', item.uhid),
      ('Age / sex', [ageLabel(patient?.date('dob'), patient?.intOrNull('age_years')), genderLabel(patient?.strOrNull('gender'))].join(' / ')),
      ('Referred by', item.doctorName.isEmpty ? 'Self' : item.doctorName),
      ('Sample ID', order.str('sample_id', '—')),
      ('Sample', item.test?.str('sample_type') ?? '—'),
      ('Collected', formatDateTime(order.date('collected_at'))),
      ('Reported', formatDateTime(result?.date('verified_at') ?? result?.date('entered_at'))),
    ];

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(compact ? Gap.lg : Gap.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Gap.v16,
                Divider(height: 2, thickness: 2, color: theme.colorScheme.primary),
                Gap.v16,
                if (!verified) ...[
                  LabBanner(
                    tone: Tone.warning,
                    icon: Icons.hourglass_top,
                    title: result == null ? 'No results yet' : 'Provisional report — not yet verified',
                    message: result == null
                        ? 'Results appear here once they are entered.'
                        : 'Do not act on these values until a pathologist has verified them.',
                  ),
                  Gap.v16,
                ],
                if (amended && result?.strOrNull('amend_reason') != null) ...[
                  Text('Amended report · ${result!.str('amend_reason')}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: ToneColors.of(context, Tone.warning).foreground, fontWeight: FontWeight.w600)),
                  Gap.v12,
                ],
                _DetailsGrid(details, columns: compact ? 2 : 4),
                Gap.v24,
                Text(item.testName.toUpperCase(),
                    style: theme.textTheme.titleSmall?.copyWith(letterSpacing: 0.6)),
                Gap.v8,
                if (values.isEmpty)
                  Padding(padding: const EdgeInsets.symmetric(vertical: Gap.lg), child: Text('No results entered.', style: muted))
                else
                  _ValuesTable(values: values, compact: compact),
                if (result != null && result.str('comments').isNotEmpty) ...[
                  Gap.v16,
                  Text.rich(TextSpan(children: [
                    TextSpan(text: 'Comments: ', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                    TextSpan(text: result.str('comments'), style: theme.textTheme.bodyMedium),
                  ])),
                ],
                Gap.v24,
                Wrap(
                  spacing: Gap.xxl,
                  runSpacing: Gap.lg,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    _Signature(label: 'Entered by', name: result?.str('entered_by_name') ?? '—', role: '',
                        at: result?.date('entered_at')),
                    _Signature(
                      label: 'Verified by',
                      name: verified ? result!.str('verified_by_name') : 'Pending verification',
                      role: verified ? 'Pathologist' : '',
                      at: verified ? result!.date('verified_at') : null,
                      signed: verified,
                    ),
                  ],
                ),
                Gap.v24,
                const Divider(height: 1),
                Gap.v8,
                Text(
                  'H / L: above / below the reference interval.  HH / LL: critical value, reported to the doctor at once.  '
                  'Results relate only to the sample tested and must be read with the clinical findings.',
                  style: muted,
                ),
                Gap.v8,
                Center(child: Text('— End of report —', style: muted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailsGrid extends StatelessWidget {
  const _DetailsGrid(this.items, {required this.columns});
  final List<(String, String)> items;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - (columns - 1) * Gap.lg) / columns;
      return Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.md,
        children: [
          for (final (label, value) in items)
            SizedBox(
              width: w,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  Text(value.isEmpty ? '—' : value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      );
    });
  }
}

class _ValuesTable extends StatelessWidget {
  const _ValuesTable({required this.values, required this.compact});
  final List<Map<String, Object?>> values;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Color? rowColor(Map<String, Object?> v) =>
        LabFlag.isCritical(v['flag'] as String?) ? ToneColors.of(context, Tone.danger).background : null;

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final v in values)
            Container(
              color: rowColor(v),
              padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${v['name']}', style: theme.textTheme.bodyMedium),
                        if ((v['ref'] as String? ?? '').isNotEmpty) Text('Ref ${v['ref']} ${v['unit'] ?? ''}'.trim(), style: muted),
                      ],
                    ),
                  ),
                  Gap.h8,
                  FlaggedValue(v),
                ],
              ),
            ),
        ],
      );
    }
    return Table(
      columnWidths: const {0: FlexColumnWidth(4), 1: FlexColumnWidth(2.2), 2: FlexColumnWidth(1.6), 3: FlexColumnWidth(3)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outline))),
          children: [
            for (final h in ['Investigation', 'Result', 'Unit', 'Biological reference interval'])
              Padding(padding: const EdgeInsets.symmetric(vertical: Gap.sm), child: Text(h, style: head)),
          ],
        ),
        for (final v in values)
          TableRow(
            decoration: BoxDecoration(
              color: rowColor(v),
              border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
            ),
            children: [
              Padding(padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4), child: Text('${v['name']}')),
              FlaggedValue(v, showUnit: false),
              Text('${v['unit'] ?? ''}', style: muted),
              Text('${v['ref'] ?? ''}', style: theme.textTheme.bodyMedium),
            ],
          ),
      ],
    );
  }
}

class _Signature extends StatelessWidget {
  const _Signature({required this.label, required this.name, required this.role, this.at, this.signed = true});
  final String label;
  final String name;
  final String role;
  final DateTime? at;
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: muted),
          Gap.v4,
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (signed && label == 'Verified by') ...[
              Icon(Icons.verified, size: 16, color: ToneColors.of(context, Tone.success).foreground),
              Gap.h4,
            ],
            Flexible(child: Text(name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          if (role.isNotEmpty) Text(role, style: muted),
          if (at != null) Text(formatDateTime(at), style: muted),
        ],
      ),
    );
  }
}

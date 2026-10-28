import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

/// STAT and urgent stand out; routine stays quiet.
class PriorityChip extends StatelessWidget {
  const PriorityChip(this.priority, {super.key, this.showRoutine = true});
  final String? priority;
  final bool showRoutine;

  @override
  Widget build(BuildContext context) => switch (priority) {
        Priority.stat => const StatusChip('STAT', tone: Tone.danger, icon: Icons.bolt),
        Priority.urgent => const StatusChip('Urgent', tone: Tone.warning, icon: Icons.priority_high),
        _ => showRoutine ? const StatusChip('Routine') : const SizedBox.shrink(),
      };
}

class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip(this.status, {super.key, this.resultStatus});
  final String status;
  final String? resultStatus;

  @override
  Widget build(BuildContext context) => switch (status) {
        Vals.ordered => const StatusChip('To collect', icon: Icons.schedule),
        Vals.collected => const StatusChip('Awaiting results', tone: Tone.info, icon: Icons.science_outlined),
        Vals.resulted => resultStatus == ResultStatus.amended
            ? const StatusChip('Amended · to verify', tone: Tone.warning, icon: Icons.edit_note)
            : const StatusChip('To verify', tone: Tone.warning, icon: Icons.rate_review_outlined),
        Vals.verified => const StatusChip('Verified', tone: Tone.success, icon: Icons.verified_outlined),
        Vals.cancelled => const StatusChip('Cancelled', icon: Icons.block),
        _ => StatusChip(titleCase(status)),
      };
}

/// "Due in 35 min" or "Overdue 1 h 5 min" (red).
class TatLabel extends StatelessWidget {
  const TatLabel(this.item, {super.key, required this.now, this.compact = false});
  final LabItem item;
  final DateTime now;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final turnaround = item.turnaround;
    if (turnaround != null) {
      final target = targetMinutes(item.priority, item.tatMinutes);
      final late = turnaround.inMinutes > target;
      final c = ToneColors.of(context, late ? Tone.danger : Tone.success);
      return Text(formatDuration(turnaround),
          style: theme.textTheme.bodyMedium?.copyWith(color: c.foreground, fontWeight: FontWeight.w600));
    }
    final left = item.due.difference(now);
    final overdue = left.isNegative;
    final soon = !overdue && left.inMinutes <= 30;
    final tone = overdue ? Tone.danger : (soon ? Tone.warning : Tone.neutral);
    final c = ToneColors.of(context, tone);
    final text = overdue ? 'Overdue ${formatDuration(-left)}' : 'Due in ${formatDuration(left)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(overdue ? Icons.timer_off_outlined : Icons.timer_outlined,
            size: 16, color: tone == Tone.neutral ? theme.colorScheme.onSurfaceVariant : c.foreground),
        Gap.h4,
        Flexible(
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tone == Tone.neutral ? theme.colorScheme.onSurfaceVariant : c.foreground,
                fontWeight: tone == Tone.neutral ? FontWeight.w400 : FontWeight.w600,
              )),
        ),
      ],
    );
  }
}

/// "High", "Critical low"... next to a value.
class FlagBadge extends StatelessWidget {
  const FlagBadge(this.flag, {super.key, this.dense = false});
  final String? flag;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!LabFlag.isAbnormal(flag)) return const SizedBox.shrink();
    final critical = LabFlag.isCritical(flag);
    return StatusChip(dense ? flag! : LabFlag.label(flag),
        tone: LabFlag.tone(flag), icon: critical ? Icons.warning_amber_rounded : (flag == LabFlag.high ? Icons.arrow_upward : (flag == LabFlag.low ? Icons.arrow_downward : null)));
  }
}

/// A result value coloured by its flag: "9.8 L".
class FlaggedValue extends StatelessWidget {
  const FlaggedValue(this.value, {super.key, this.unit = '', this.style, this.showUnit = true});
  final Map<String, Object?> value;
  final String unit;
  final TextStyle? style;
  final bool showUnit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flag = value['flag'] as String? ?? '';
    final isNum = value['numeric'] != null;
    final c = ToneColors.of(context, LabFlag.tone(flag));
    final base = style ?? theme.textTheme.bodyMedium;
    final u = showUnit && (value['unit'] as String? ?? '').isNotEmpty ? ' ${value['unit']}' : '';
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: '${value['value']}',
          style: base?.copyWith(
            fontWeight: flag.isEmpty ? FontWeight.w600 : FontWeight.w700,
            color: flag.isEmpty ? null : c.foreground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (u.isNotEmpty) TextSpan(text: u, style: base?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (flag.isNotEmpty && isNum)
          TextSpan(text: '  $flag', style: base?.copyWith(color: c.foreground, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// The order's summary line, red when critical.
class SummaryText extends StatelessWidget {
  const SummaryText(this.order, {super.key, this.maxLines = 2});
  final Rec order;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = order.str('result_summary');
    if (s.isEmpty) return Text('—', style: TextStyle(color: theme.colorScheme.onSurfaceVariant));
    final tone = order.flag('critical') ? Tone.danger : (order.flag('abnormal') ? Tone.warning : Tone.success);
    final c = ToneColors.of(context, tone);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (order.flag('critical')) ...[
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.warning_amber_rounded, size: 16, color: c.foreground)),
          Gap.h4,
        ],
        Flexible(
          child: Text(s,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: tone == Tone.success ? null : c.foreground, fontWeight: tone == Tone.success ? null : FontWeight.w600)),
        ),
      ],
    );
  }
}

/// A coloured message box (critical alerts, notices).
class LabBanner extends StatelessWidget {
  const LabBanner({super.key, required this.tone, required this.icon, required this.title, this.message, this.action});
  final Tone tone;
  final IconData icon;
  final String title;
  final String? message;
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
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.lg)),
      child: LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 520;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: c.foreground),
                Gap.h12,
                Expanded(child: text),
                if (action != null && !narrow) ...[Gap.h12, action!],
              ],
            ),
            if (action != null && narrow) ...[Gap.v12, Align(alignment: Alignment.centerRight, child: action!)],
          ],
        );
      }),
    );
  }
}

String patientLine(Rec? p) => p == null
    ? ''
    : [
        p.str('uhid'),
        ageLabel(p.date('dob'), p.intOrNull('age_years')),
        genderLabel(p.strOrNull('gender')),
      ].where((s) => s.isNotEmpty && s != '—').join(' · ');

/// Shows the tube labels after collection.
Future<void> showSampleLabels(BuildContext context, List<CollectedSample> samples) {
  final theme = Theme.of(context);
  final charged = samples.fold<int>(0, (a, s) => a + s.tests.length);
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: Icon(Icons.label_outline, color: theme.colorScheme.primary),
      title: Text(samples.length == 1 ? 'Label the tube' : 'Label ${samples.length} tubes'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Write this on each tube before it leaves the patient.', style: theme.textTheme.bodyMedium),
              Gap.v12,
              for (final s in samples) ...[
                Container(
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.sampleId,
                            style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700, letterSpacing: 1, fontFeatures: const [FontFeature.tabularFigures()])),
                        Gap.v4,
                        Text(s.labelText.split('\n').skip(1).join('\n'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
                      ],
                    ),
                  ),
                ),
                Gap.v8,
              ],
              Text('${plural(charged, 'test')} charged to the patient\'s bill.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
    ),
  );
}

/// Collects samples for [items], then shows what to write on the tubes.
Future<bool> collectSamples(BuildContext context, List<LabItem> items) async {
  var samples = <CollectedSample>[];
  final ok = await runGuarded(context, () async {
    samples = await LabService.collect(context.db, [for (final i in items) i.order]);
  });
  if (!ok || !context.mounted) return false;
  if (samples.isEmpty) {
    context.toast('Already collected by someone else');
    return false;
  }
  await showSampleLabels(context, samples);
  return true;
}

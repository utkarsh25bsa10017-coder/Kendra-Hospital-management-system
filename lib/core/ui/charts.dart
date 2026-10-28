import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Vertical bars with labels underneath. Hover or tap a bar to see its value.
class BarChart extends StatefulWidget {
  const BarChart({
    super.key,
    required this.values,
    required this.labels,
    this.format,
    this.height = 180,
    this.highlightLast = true,
    this.color,
  });

  final List<num> values;
  final List<String> labels;
  final String Function(num v)? format;
  final double height;
  final bool highlightLast;
  final Color? color;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final n = widget.values.length;
    if (n == 0) return SizedBox(height: widget.height);
    final maxV = widget.values.fold<num>(0, (a, b) => math.max(a, b));
    final fmt = widget.format ?? (v) => v.toString();
    final shown = _hover ?? (widget.highlightLast ? n - 1 : null);
    final labelEvery = n > 16 ? (n / 8).ceil() : 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 22,
          child: shown == null
              ? null
              : Text('${widget.labels[shown]}: ${fmt(widget.values[shown])}',
                  style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        ),
        Gap.v8,
        SizedBox(
          height: widget.height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hover = i),
                    onExit: (_) => setState(() => _hover = null),
                    child: GestureDetector(
                      onTap: () => setState(() => _hover = i),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: n > 20 ? 1 : 3),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            height: maxV == 0 ? 2 : math.max(2, widget.height * widget.values[i] / maxV),
                            decoration: BoxDecoration(
                              color: i == shown
                                  ? (widget.color ?? cs.primary)
                                  : (widget.color ?? cs.primary).withValues(alpha: 0.35),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Gap.v4,
        Row(
          children: [
            for (var i = 0; i < n; i++)
              Expanded(
                child: Text(
                  i % labelEvery == 0 ? widget.labels[i] : '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Horizontal share bars, e.g. revenue by department.
class ShareBars extends StatelessWidget {
  const ShareBars({super.key, required this.items, this.format});
  final List<(String, num)> items;
  final String Function(num v)? format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = items.fold<num>(0, (a, b) => a + b.$2);
    final maxV = items.fold<num>(0, (a, b) => math.max(a, b.$2));
    final fmt = format ?? (v) => v.toString();
    return Column(
      children: [
        for (final (label, v) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(label, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
                  Text(fmt(v), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (total > 0)
                    SizedBox(
                      width: 48,
                      child: Text('${(v * 100 / total).round()}%',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                ]),
                Gap.v4,
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: maxV == 0 ? 0 : v / maxV,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

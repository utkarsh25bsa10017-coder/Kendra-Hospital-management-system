import 'package:flutter/material.dart';

import 'tokens.dart';

class ListColumn<T> {
  const ListColumn(this.label, this.cell, {this.flex = 2, this.numeric = false, this.width});
  final String label;
  final Widget Function(T item) cell;
  final int flex;

  /// Right-align (amounts, counts).
  final bool numeric;

  /// Fixed width instead of [flex].
  final double? width;
}

/// A list that is a table on desktop and tablet, and tappable cards on phones.
///
/// Renders as a plain column, so put it inside a scrolling page.
class DataList<T> extends StatelessWidget {
  const DataList({
    super.key,
    required this.items,
    required this.columns,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.onTap,
    this.selected,
    this.empty,
  });

  final List<T> items;
  final List<ListColumn<T>> columns;

  /// Card layout on phones.
  final String Function(T item) title;
  final String Function(T item)? subtitle;
  final Widget Function(T item)? trailing;
  final Widget Function(T item)? leading;
  final void Function(T item)? onTap;
  final bool Function(T item)? selected;
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return empty ?? const SizedBox.shrink();
    if (context.isCompact) return _cards(context);
    return _table(context);
  }

  Widget _cards(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Card(
              clipBehavior: Clip.antiAlias,
              color: (selected?.call(item) ?? false) ? theme.colorScheme.primaryContainer : null,
              child: InkWell(
                onTap: onTap == null ? null : () => onTap!(item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
                  child: Row(
                    children: [
                      if (leading != null) ...[leading!(item), Gap.h12],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title(item), style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            if (subtitle != null) ...[
                              Gap.v4,
                              Text(subtitle!(item),
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ],
                        ),
                      ),
                      if (trailing != null) ...[Gap.h8, trailing!(item)],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    Widget cellBox(ListColumn<T> c, Widget child) {
      final aligned = Align(alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft, child: child);
      return c.width != null ? SizedBox(width: c.width, child: aligned) : Expanded(flex: c.flex, child: aligned);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: theme.colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: 10),
            child: Row(
              children: [
                for (final c in columns)
                  cellBox(
                    c,
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.md),
                      child: Text(c.label,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Material(
              color: (selected?.call(items[i]) ?? false) ? theme.colorScheme.primaryContainer : Colors.transparent,
              child: InkWell(
                onTap: onTap == null ? null : () => onTap!(items[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: 12),
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium,
                    child: Row(
                      children: [
                        for (final c in columns)
                          cellBox(c, Padding(padding: const EdgeInsets.only(right: Gap.md), child: c.cell(items[i]))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Primary + secondary text in one table cell.
class TwoLine extends StatelessWidget {
  const TwoLine(this.primary, this.secondary, {super.key});
  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(primary, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        if (secondary != null && secondary!.isNotEmpty)
          Text(secondary!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

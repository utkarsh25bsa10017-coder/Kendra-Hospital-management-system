import 'dart:async';

import 'package:flutter/material.dart';

import '../tour/tour_anchor.dart';
import 'format.dart';
import 'tokens.dart';

/// The main button on a page. On phones it becomes a floating button.
class PageAction {
  const PageAction(this.label, this.icon, this.onPressed, {this.tourAnchor});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tourAnchor;
}

/// Standard page: title row with actions, then content.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.primaryAction,
    this.scrollable = true,
    this.maxWidth,
    this.headerBottom,
  });

  final String title;
  final String? subtitle;

  /// Secondary actions (icon buttons, menus) shown next to the title.
  final List<Widget> actions;
  final PageAction? primaryAction;
  final Widget body;

  /// False when [body] manages its own scrolling (lists, split views).
  final bool scrollable;
  final double? maxWidth;

  /// Shown under the title, e.g. filter chips or tabs.
  final Widget? headerBottom;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    final pad = context.pagePadding;
    final canPop = Navigator.of(context).canPop();
    final theme = Theme.of(context);
    final pa = primaryAction;

    Widget primaryButton(PageAction a) {
      final b = FilledButton.icon(onPressed: a.onPressed, icon: Icon(a.icon, size: 20), label: Text(a.label));
      return a.tourAnchor == null ? b : TourAnchor(id: a.tourAnchor!, child: b);
    }

    final header = Padding(
      padding: EdgeInsets.fromLTRB(pad, compact ? 12 : 24, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (canPop) ...[
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Gap.h4,
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: compact ? theme.textTheme.titleLarge : theme.textTheme.headlineSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    if (subtitle != null) ...[
                      Gap.v4,
                      Text(subtitle!,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
              ...actions,
              if (pa != null && !compact) ...[Gap.h8, primaryButton(pa)],
            ],
          ),
          if (headerBottom != null) ...[Gap.v12, headerBottom!],
        ],
      ),
    );

    Widget content = body;
    if (maxWidth != null) {
      content = Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: content),
      );
    }

    final Widget page = scrollable
        ? CustomScrollView(slivers: [
            SliverToBoxAdapter(child: header),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 4, pad, compact && pa != null ? 96 : pad),
              sliver: SliverToBoxAdapter(child: content),
            ),
          ])
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: Padding(padding: EdgeInsets.fromLTRB(pad, 4, pad, 0), child: content),
              ),
            ],
          );

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(bottom: false, child: page),
      floatingActionButton: (compact && pa != null)
          ? FloatingActionButton.extended(onPressed: pa.onPressed, icon: Icon(pa.icon), label: Text(pa.label))
          : null,
    );
  }
}

/// A bordered panel with an optional title row.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.color,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null || trailing != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title != null) Text(title!, style: theme.textTheme.titleMedium),
                        if (subtitle != null)
                          Text(subtitle!,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              Gap.v12,
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.tone = Tone.neutral, this.icon});
  final String label;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: c.foreground), Gap.h4],
          Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c.foreground, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
            child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
          ),
          Gap.v16,
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            Gap.v8,
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
          if (action != null) ...[Gap.v16, action!],
        ],
      ),
    );
  }
}

/// A number with a label, for dashboards. Tap to drill down.
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon,
    this.tone = Tone.neutral,
    this.onTap,
  });

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;
  final Tone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ToneColors.of(context, tone);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.sm)),
                      child: Icon(icon, size: 18, color: c.foreground),
                    ),
                    Gap.h8,
                  ],
                  Expanded(
                    child: Text(label,
                        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (onTap != null) Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.outline),
                ],
              ),
              Gap.v12,
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              if (caption != null) ...[
                Gap.v4,
                Text(caption!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Label / value pairs that wrap into columns on wide screens.
class InfoGrid extends StatelessWidget {
  const InfoGrid(this.items, {super.key, this.minItemWidth = 200});
  final List<(String, String)> items;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minItemWidth).floor().clamp(1, 4);
      final w = (c.maxWidth - (cols - 1) * Gap.lg) / cols;
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
                  Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  Gap.v4,
                  SelectableText(value.isEmpty ? '—' : value, style: theme.textTheme.bodyLarge),
                ],
              ),
            ),
        ],
      );
    });
  }
}

/// Lays children out in as many columns as fit (at least [minWidth] each).
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minWidth = 260, this.spacing = Gap.lg, this.maxColumns = 4});
  final List<Widget> children;
  final double minWidth;
  final double spacing;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minWidth).floor().clamp(1, maxColumns);
      final w = (c.maxWidth - (cols - 1) * spacing) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 36});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: cs.primaryContainer,
      child: Text(initials(name),
          style: TextStyle(fontSize: size * 0.38, fontWeight: FontWeight.w600, color: cs.onPrimaryContainer)),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load this',
        message: error.toString(),
        action: onRetry == null ? null : OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      );
}

/// Search box that reports changes after the user pauses typing.
class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.onChanged, this.hint = 'Search', this.autofocus = false, this.initial = ''});
  final ValueChanged<String> onChanged;
  final String hint;
  final bool autofocus;
  final String initial;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final _ctrl = TextEditingController(text: widget.initial);
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 250), () => widget.onChanged(v.trim()));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      autofocus: widget.autofocus,
      onChanged: _changed,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        suffixIcon: _ctrl.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _ctrl.clear();
                  _changed('');
                },
              ),
      ),
    );
  }
}

/// One-of-many filter shown as chips.
class FilterChips<T> extends StatelessWidget {
  const FilterChips({super.key, required this.options, required this.value, required this.onChanged});
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (v, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                label: Text(label),
                selected: v == value,
                showCheckmark: false,
                onSelected: (_) => onChanged(v),
              ),
            ),
        ],
      ),
    );
  }
}

/// List on the left, details on the right on wide screens; on phones the
/// caller pushes the detail as its own page.
class SplitView extends StatelessWidget {
  const SplitView({super.key, required this.list, this.detail, this.listWidth = 400, this.placeholder});
  final Widget list;
  final Widget? detail;
  final double listWidth;
  final Widget? placeholder;

  static bool isSplit(BuildContext context) => MediaQuery.sizeOf(context).width >= 1100;

  @override
  Widget build(BuildContext context) {
    if (!isSplit(context)) return list;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: listWidth, child: list),
        Gap.h16,
        Expanded(
          child: detail ??
              placeholder ??
              const Center(child: Text('Select an item to see the details')),
        ),
      ],
    );
  }
}

/// Small section heading inside a card or form.
class SubHeading extends StatelessWidget {
  const SubHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
      child: Text(text.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
    );
  }
}

/// Money in a tabular font so columns line up.
class MoneyText extends StatelessWidget {
  const MoneyText(this.paise, {super.key, this.style, this.color});
  final int? paise;
  final TextStyle? style;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        formatMoney(paise),
        style: (style ?? Theme.of(context).textTheme.bodyMedium)
            ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: color),
      );
}

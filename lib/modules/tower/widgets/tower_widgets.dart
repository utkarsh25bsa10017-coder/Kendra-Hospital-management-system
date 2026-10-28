import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../tower_data.dart';

class SeverityChip extends StatelessWidget {
  const SeverityChip(this.severity, {super.key});
  final String? severity;

  @override
  Widget build(BuildContext context) {
    final s = Severity.parse(severity);
    return StatusChip(
      s.label,
      tone: toneForSeverity(s.name),
      icon: switch (s) {
        Severity.critical => Icons.error_outline,
        Severity.high => Icons.warning_amber_rounded,
        _ => null,
      },
    );
  }
}

class FindingStatusChip extends StatelessWidget {
  const FindingStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) => StatusChip(FindingStatus.label(status), tone: FindingStatus.tone(status));
}

/// A small coloured square with an icon, used at the start of list rows.
class ToneIcon extends StatelessWidget {
  const ToneIcon(this.icon, {super.key, this.tone = Tone.neutral, this.size = 36});
  final IconData icon;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(Radii.md)),
      child: Icon(icon, size: size * 0.52, color: c.foreground),
    );
  }
}

/// Keyboard hints such as "J K  next / previous".
class KeyHints extends StatelessWidget {
  const KeyHints(this.hints, {super.key});
  final List<(String, String)> hints;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Wrap(
      spacing: Gap.lg,
      runSpacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (keys, label) in hints)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in keys.split(' ')) ...[
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(k,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
                ),
                Gap.h4,
              ],
              Text(label, style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
      ],
    );
  }
}

/// A tappable row that opens another screen ("Bill INV-104 ›").
class LinkRow extends StatelessWidget {
  const LinkRow({super.key, required this.icon, required this.label, this.caption, this.onTap});
  final IconData icon;
  final String label;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: onTap == null ? cs.onSurfaceVariant : cs.primary),
            Gap.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: onTap == null ? cs.onSurface : cs.primary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (caption != null)
                    Text(caption!,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (onTap != null) Icon(Icons.chevron_right, size: 20, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// The records that prove a finding. Each opens its screen when the module
/// that owns it is switched on.
class EvidenceList extends StatelessWidget {
  const EvidenceList(this.items, {super.key});
  final List<Map<String, Object?>> items;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (items.isEmpty) {
      return Text('The agent did not attach any records.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, e) in items.indexed) ...[
          if (i > 0) const Divider(height: 1),
          _evidence(app, e),
        ],
      ],
    );
  }

  Widget _evidence(AppServices app, Map<String, Object?> e) {
    final route = e['route_id'] as String?;
    final args = (e['route_args'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final collection = e['collection'] as String?;
    final available = route != null && app.registry.route(route) != null;
    return LinkRow(
      icon: switch (collection) {
        Col.patients => Icons.person_outline,
        'invoices' || 'billing_invoices' || Col.charges => Icons.receipt_long_outlined,
        Col.serviceOrders || 'lab_orders' => Icons.biotech_outlined,
        Col.prescriptions || Col.medicines || 'pharmacy_products' => Icons.medication_outlined,
        _ => Icons.description_outlined,
      },
      label: (e['label'] as String?) ?? subjectName(collection),
      caption: route == null ? subjectName(collection) : (available ? null : 'Its module is switched off'),
      onTap: available ? () => app.nav.open(route, args) : null,
    );
  }
}

/// Two columns on wide screens (main on the left), stacked on narrow ones.
class TwoColumns extends StatelessWidget {
  const TwoColumns({super.key, required this.main, required this.side, this.breakpoint = 960, this.sideFlex = 2, this.mainFlex = 3});
  final Widget main;
  final Widget side;
  final double breakpoint;
  final int mainFlex;
  final int sideFlex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < breakpoint) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, Gap.v16, side]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: mainFlex, child: main),
          Gap.h16,
          Expanded(flex: sideFlex, child: side),
        ],
      );
    });
  }
}

/// Muted helper text with an icon, e.g. why a button is disabled.
class InlineNote extends StatelessWidget {
  const InlineNote(this.text, {super.key, this.icon = Icons.info_outline, this.tone});
  final String text;
  final IconData icon;
  final Tone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone == null ? theme.colorScheme.onSurfaceVariant : ToneColors.of(context, tone!).foreground;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
        Gap.h8,
        Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color))),
      ],
    );
  }
}

/// Shows a proposal's payload in a readable form: a small table for an
/// `items` list, label/value pairs for everything else. Ids are left out.
class PayloadView extends StatelessWidget {
  const PayloadView(this.payload, {super.key});
  final Map<String, Object?> payload;

  static bool _hidden(String k) => k == 'id' || k.endsWith('_id') || k.endsWith('_ids');

  static String label(String k) {
    var s = k;
    for (final suffix in ['_paise', '_at', '_qty']) {
      if (s.endsWith(suffix) && s.length > suffix.length) s = s.substring(0, s.length - suffix.length);
    }
    if (k.endsWith('_qty')) s = '$s qty';
    return switch (s) { 'qty' => 'Qty', _ => sentenceCase(s) };
  }

  static String value(String k, Object? v) {
    if (v == null) return '—';
    if (k.endsWith('_paise') && v is num) return formatMoney(v.toInt());
    if (v is bool) return v ? 'Yes' : 'No';
    if (v is num) return formatNumber(v);
    if (v is DateTime) return formatDateTime(v);
    if (v is String) {
      final d = DateTime.tryParse(v);
      if (d != null && v.length >= 10 && v.contains('-')) return v.length > 10 ? formatDateTime(d.toLocal()) : formatDate(d);
      return v;
    }
    if (v is List) return v.map((e) => e is Map ? (e['name'] ?? e['label'] ?? '…').toString() : '$e').join(', ');
    if (v is Map) return v.entries.where((e) => !_hidden(e.key.toString())).map((e) => '${label(e.key.toString())}: ${value(e.key.toString(), e.value)}').join(', ');
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = payload['items'];
    final rows = items is List ? items.whereType<Map>().map((m) => m.cast<String, Object?>()).toList() : const <Map<String, Object?>>[];
    final rest = [
      for (final e in payload.entries)
        if (e.key != 'items' && !_hidden(e.key)) (label(e.key), value(e.key, e.value)),
    ];
    final cols = <String>[];
    for (final r in rows) {
      for (final k in r.keys) {
        if (!_hidden(k) && !cols.contains(k) && cols.length < 5) cols.add(k);
      }
    }
    bool numeric(String k) => rows.every((r) => r[k] == null || r[k] is num);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isNotEmpty && cols.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: cs.surfaceContainerLow,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                  child: Row(children: [
                    for (final (i, k) in cols.indexed)
                      Expanded(
                        flex: i == 0 ? 3 : 2,
                        child: Text(label(k),
                            textAlign: i > 0 && numeric(k) ? TextAlign.right : TextAlign.left,
                            style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ]),
                ),
                for (final (ri, r) in rows.take(12).indexed) ...[
                  if (ri > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                    child: Row(children: [
                      for (final (i, k) in cols.indexed)
                        Expanded(
                          flex: i == 0 ? 3 : 2,
                          child: Text(value(k, r[k]),
                              textAlign: i > 0 && numeric(k) ? TextAlign.right : TextAlign.left,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFeatures: const [FontFeature.tabularFigures()],
                                fontWeight: i == 0 ? FontWeight.w600 : null,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ]),
                  ),
                ],
                if (rows.length > 12)
                  Padding(
                    padding: const EdgeInsets.all(Gap.sm),
                    child: Text('and ${rows.length - 12} more', style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        if (rows.isNotEmpty && rest.isNotEmpty) Gap.v12,
        if (rest.isNotEmpty) InfoGrid(rest, minItemWidth: 160),
      ],
    );
  }
}

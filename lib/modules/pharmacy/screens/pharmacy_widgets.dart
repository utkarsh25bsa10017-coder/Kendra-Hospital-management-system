import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';

/// "Exp Mar 2027", amber when near, red when expired.
class ExpiryChip extends StatelessWidget {
  const ExpiryChip(this.expiry, {super.key, this.prefix = 'Exp '});
  final DateTime? expiry;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    if (expiry == null) return const StatusChip('No expiry');
    if (PharmacyService.isExpired(expiry, now)) {
      return StatusChip('Expired ${PharmacyService.expiryLabel(expiry)}', tone: Tone.danger, icon: Icons.event_busy);
    }
    if (PharmacyService.isNearExpiry(expiry, now)) {
      return StatusChip('$prefix${PharmacyService.expiryLabel(expiry)}', tone: Tone.warning, icon: Icons.schedule);
    }
    return StatusChip('$prefix${PharmacyService.expiryLabel(expiry)}');
  }
}

/// Out / Low / Near expiry / Expired chips for a product.
class StockChips extends StatelessWidget {
  const StockChips(this.info, {super.key, this.showOk = true});
  final StockInfo info;
  final bool showOk;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (info.out)
        const StatusChip('Out', tone: Tone.danger)
      else if (info.low)
        const StatusChip('Low', tone: Tone.warning),
      if (info.nearExpiry) const StatusChip('Near expiry', tone: Tone.warning),
      if (info.expired) const StatusChip('Expired', tone: Tone.danger),
      if (info.negativeBatches > 0) const StatusChip('Check count', tone: Tone.danger),
    ];
    if (chips.isEmpty && showOk) chips.add(const StatusChip('In stock', tone: Tone.success));
    return Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: chips);
  }
}

class MoveTypeChip extends StatelessWidget {
  const MoveTypeChip(this.type, {super.key});
  final String type;

  @override
  Widget build(BuildContext context) => StatusChip(
        MoveType.label(type),
        tone: switch (type) {
          MoveType.receipt => Tone.success,
          MoveType.returned => Tone.info,
          MoveType.expiryWriteoff => Tone.danger,
          MoveType.adjustment => Tone.warning,
          _ => Tone.neutral,
        },
      );
}

class PoStatusChip extends StatelessWidget {
  const PoStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) => switch (status) {
        PoStatus.draft => const StatusChip('Draft'),
        PoStatus.ordered => const StatusChip('Ordered', tone: Tone.info),
        PoStatus.received => const StatusChip('Received', tone: Tone.success),
        PoStatus.cancelled => const StatusChip('Cancelled', tone: Tone.danger),
        _ => StatusChip(titleCase(status)),
      };
}

/// A tinted box with an icon, a title and some lines (allergy warnings,
/// stock problems, agent suggestions).
class NoticeBox extends StatelessWidget {
  const NoticeBox({super.key, required this.tone, required this.icon, required this.title, this.lines = const [], this.action});
  final Tone tone;
  final IconData icon;
  final String title;
  final List<String> lines;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c.foreground, size: 20),
          Gap.h8,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
                for (final l in lines) ...[
                  Gap.v4,
                  Text(l, style: theme.textTheme.bodySmall?.copyWith(color: c.foreground)),
                ],
              ],
            ),
          ),
          if (action != null) ...[Gap.h8, action!],
        ],
      ),
    );
  }
}

/// − [ 10 ] + quantity input.
class QtyStepper extends StatefulWidget {
  const QtyStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.max, this.unit});
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int? max;
  final String? unit;

  @override
  State<QtyStepper> createState() => _QtyStepperState();
}

class _QtyStepperState extends State<QtyStepper> {
  late final _ctrl = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(QtyStepper old) {
    super.didUpdateWidget(old);
    if (int.tryParse(_ctrl.text) != widget.value) _ctrl.text = '${widget.value}';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _set(int v) {
    var n = v < widget.min ? widget.min : v;
    if (widget.max != null && n > widget.max!) n = widget.max!;
    _ctrl.text = '$n';
    widget.onChanged(n);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: 'Less',
          onPressed: widget.value > widget.min ? () => _set(widget.value - 1) : null,
          icon: const Icon(Icons.remove, size: 18),
        ),
        Gap.h4,
        SizedBox(
          width: 64,
          child: TextField(
            controller: _ctrl,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 12)),
            onChanged: (s) {
              final n = int.tryParse(s);
              if (n != null) widget.onChanged(widget.max != null && n > widget.max! ? widget.max! : n);
            },
          ),
        ),
        Gap.h4,
        IconButton.outlined(
          tooltip: 'More',
          onPressed: widget.max == null || widget.value < widget.max! ? () => _set(widget.value + 1) : null,
          icon: const Icon(Icons.add, size: 18),
        ),
        if (widget.unit != null) ...[
          Gap.h8,
          Text(widget.unit!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// Muted small text.
class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.maxLines = 2});
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
  }
}

/// "12 tablets" with the product's unit.
String qtyLabel(int qty, String unit) {
  final u = unit.isEmpty ? 'unit' : unit;
  return plural(qty, u, switch (u) { 'box' => 'boxes', _ => '${u}s' });
}

/// Pick a product, showing what is on the shelf.
Future<Rec?> pickProduct(BuildContext context, Map<String, StockInfo> stock, {String title = 'Add medicine'}) =>
    pickRecord(
      context,
      title: title,
      query: (s) => const Query(PCol.products).eq('active', true).matching(s).sort('name').take(40),
      itemTitle: (p) => p.str('name'),
      itemSubtitle: (p) {
        final s = stock[p.id];
        return [
          p.str('generic_name'),
          if (s != null) s.out ? 'Out of stock' : '${qtyLabel(s.onHand, p.str('unit'))} in stock',
          formatMoney(p.integer('mrp_paise')),
        ].where((x) => x.isNotEmpty).join(' · ');
      },
      emptyText: 'No medicine matches. Add it under Medicines first.',
    );

/// Copies [text] and says so.
Future<void> copyText(BuildContext context, String text, String what) async {
  final app = context.app;
  await Clipboard.setData(ClipboardData(text: text));
  app.nav.toast('$what copied. Paste it into WhatsApp or email.');
}

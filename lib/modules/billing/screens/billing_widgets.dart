import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';

/// Status of a bill in one chip: Draft, ₹450 due, Paid, Cancelled...
class InvoiceStatusChip extends StatelessWidget {
  const InvoiceStatusChip(this.invoice, {super.key});
  final Rec invoice;

  @override
  Widget build(BuildContext context) {
    final inv = invoice;
    final balance = inv.integer('balance_paise');
    if (inv.str('kind') == InvoiceKind.creditNote) return const StatusChip('Credit note', tone: Tone.info);
    return switch (inv.str('status')) {
      InvoiceStatus.draft => const StatusChip('Draft', icon: Icons.edit_note),
      InvoiceStatus.cancelled => const StatusChip('Cancelled', tone: Tone.danger),
      _ when balance > 0 && inv.integer('paid_paise') > 0 => StatusChip('${formatMoney(balance)} due', tone: Tone.warning),
      _ when balance > 0 => const StatusChip('Unpaid', tone: Tone.warning),
      _ when balance < 0 => StatusChip('Refund ${formatMoney(-balance)}', tone: Tone.danger),
      _ => const StatusChip('Paid', icon: Icons.check, tone: Tone.success),
    };
  }
}

/// Title row above a list or panel.
class BillSectionHeader extends StatelessWidget {
  const BillSectionHeader(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                if (subtitle != null)
                  Text(subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (trailing != null) ...[Gap.h8, trailing!],
        ],
      ),
    );
  }
}

/// A tinted message with an optional action, e.g. "waiting for approval".
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.tone, required this.icon, required this.title, this.message, this.actions = const []});
  final Tone tone;
  final IconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;

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
          Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
        ],
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.md, Gap.md),
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 520;
        final icon_ = Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: c.foreground, size: 22));
        if (narrow || actions.isEmpty) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            icon_,
            Gap.h12,
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                text,
                if (actions.isNotEmpty) ...[Gap.v8, Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: actions)],
              ]),
            ),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          icon_,
          Gap.h12,
          Expanded(child: text),
          Gap.h12,
          Wrap(spacing: Gap.sm, children: actions),
        ]);
      }),
    );
  }
}

/// "Label ........ ₹1,250.00" for totals panels.
class AmountLine extends StatelessWidget {
  const AmountLine(this.label, this.paise, {super.key, this.caption, this.strong = false, this.large = false, this.color, this.negative = false});
  final String label;
  final int paise;
  final String? caption;
  final bool strong;
  final bool large;
  final Color? color;

  /// Show as a deduction (−₹50.00).
  final bool negative;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = large ? theme.textTheme.titleLarge : theme.textTheme.bodyLarge;
    final style = base?.copyWith(fontWeight: strong || large ? FontWeight.w700 : null, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: (large ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)?.copyWith(color: color)),
              if (caption != null)
                Text(caption!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
            ]),
          ),
          Gap.h12,
          MoneyText(negative ? -paise : paise, style: style),
        ],
      ),
    );
  }
}

/// A payment or refund in a list.
class PaymentTile extends StatelessWidget {
  const PaymentTile(this.payment, {super.key, this.showBill = false, this.onTap});
  final Rec payment;
  final bool showBill;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payment;
    final refund = p.str('kind') == PaymentKind.refund;
    final cs = theme.colorScheme;
    final details = [
      if (showBill) p.str('invoice_number'),
      if (p.str('reference').isNotEmpty) 'Ref ${p.str('reference')}',
      p.str('received_by_name'),
      formatDateTime(p.date('received_at')),
    ].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: refund ? cs.errorContainer : cs.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(refund ? Icons.undo : modeIcon(p.str('mode')),
                size: 18, color: refund ? cs.onErrorContainer : cs.onPrimaryContainer),
          ),
          Gap.h12,
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${refund ? 'Refund' : modeLabel(p.str('mode'))}${refund ? ' · ${modeLabel(p.str('mode'))}' : ''} · ${p.str('number')}',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
              Text(details,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
          Gap.h8,
          MoneyText(refund ? -p.integer('amount_paise') : p.integer('amount_paise'),
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              color: refund ? cs.error : null),
        ]),
      ),
    );
  }
}

/// Small grey text.
class MutedText extends StatelessWidget {
  const MutedText(this.text, {super.key, this.maxLines = 2});
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

/// "3 h", "2 days" — how long a charge has waited.
String waitingLabel(DateTime since, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(since);
  if (d.isNegative || d.inMinutes < 1) return 'just now';
  return formatDuration(d);
}

/// Opens a draft for [patientId] (re-using one that is already open) and
/// shows it. Used by the desk, the patient profile and quick actions.
Future<void> openBillForPatient(BuildContext context, String patientId) async {
  final app = context.app;
  Rec? draft;
  final ok = await runGuarded(context, () async {
    draft = await app.readDb.first(Query(BillCol.invoices)
        .eq('patient_id', patientId)
        .eq('status', InvoiceStatus.draft)
        .sort('created_at', desc: true));
    if (draft != null) {
      final more = await BillingService.unbilledFor(app.readDb, patientId);
      if (more.isNotEmpty) await BillingService.addCharges(app.db, draft!.id, more);
    } else {
      draft = await BillingService.createDraft(app.db, patientId);
    }
  });
  if (!ok || draft == null) return;
  app.nav.open('billing.invoice', {'id': draft!.id});
}

/// The one action on a list row ("Create bill", "Take payment"): tinted with
/// the primary colour so it reads as the next step, not as a warning.
class RowAction extends StatelessWidget {
  const RowAction(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FilledButton.tonal(
      style: FilledButton.styleFrom(backgroundColor: cs.primaryContainer, foregroundColor: cs.onPrimaryContainer),
      onPressed: onPressed,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

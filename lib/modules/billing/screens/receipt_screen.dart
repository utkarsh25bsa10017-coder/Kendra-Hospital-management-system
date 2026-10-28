import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'bill_print.dart';
import 'invoice_screen.dart';

/// A clean, printable bill / receipt with the hospital's letterhead.
class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({super.key, required this.invoiceId});
  final String invoiceId;

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<BillData?>(
      watch: const {BillCol.invoices, BillCol.lines, BillCol.payments},
      deps: [invoiceId],
      load: (db) => BillData.load(db, invoiceId),
      builder: (context, data) {
        if (data == null) {
          return const PageScaffold(title: 'Receipt', body: EmptyState(icon: Icons.receipt_long_outlined, title: 'Bill not found'));
        }
        return PageScaffold(
          title: data.isCreditNote ? 'Credit note' : 'Receipt',
          subtitle: '${data.invoice.str('number')} · ${data.invoice.str('patient_name')}',
          maxWidth: 860,
          actions: [
            PrintButton(
              name: '${data.isCreditNote ? 'Credit note' : 'Bill'} ${data.invoice.str('number')}',
              build: () => billPdf(data, Letterhead.of(context.app.settings)),
            ),
          ],
          body: _Paper(data: data),
        );
      },
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper({required this.data});
  final BillData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.app.settings;
    final inv = data.invoice;
    final p = data.patient;
    final address = settings.str(SettingKeys.hospitalAddress);
    final phone = settings.str(SettingKeys.hospitalPhone);
    final gstin = settings.str(SettingKeys.hospitalGstin);
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final draft = data.isDraft;
    final cancelled = inv.str('status') == InvoiceStatus.cancelled;
    final docLabel = data.isCreditNote ? 'CREDIT NOTE' : (draft ? 'DRAFT' : 'BILL / RECEIPT');
    final when = inv.date('finalised_at') ?? inv.createdAt;
    final received = data.payments.where((x) => x.str('kind') != PaymentKind.refund).toList();
    final refunds = data.payments.where((x) => x.str('kind') == PaymentKind.refund).toList();

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 560;
      final pad = narrow ? Gap.lg : 40.0;

      final letterhead = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(settings.hospitalName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (address.isNotEmpty) Text(address, style: muted),
        if (phone.isNotEmpty) Text('Phone $phone', style: muted),
        if (gstin.isNotEmpty) Text('GSTIN $gstin', style: muted),
      ]);
      final docBlock = Column(
        crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Text(docLabel,
              style: theme.textTheme.labelLarge
                  ?.copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w700, color: cancelled ? cs.error : cs.primary)),
          Gap.v4,
          Text(inv.str('number'), style: theme.textTheme.titleMedium),
          Text(formatDateTime(when), style: muted),
        ],
      );

      final patient = Wrap(spacing: Gap.xl, runSpacing: Gap.md, children: [
        _Field('Patient', inv.str('patient_name')),
        _Field('UHID', inv.str('patient_uhid')),
        if (p != null) _Field('Age / sex', '${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${genderLabel(p.strOrNull('gender'))}'),
        if (p != null && p.str('phone').isNotEmpty) _Field('Mobile', p.str('phone')),
        _Field(
            'Payer',
            [
              payerLabel(inv.strOrNull('payer_type')),
              if (p != null && inv.str('payer_type') != 'self' && p.str('insurer').isNotEmpty) p.str('insurer'),
            ].join(' · ')),
        if (p != null && inv.str('payer_type') != 'self' && p.str('policy_no').isNotEmpty) _Field('Policy / ID', p.str('policy_no')),
      ]);

      final head = theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700);
      final lines = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.sm),
          color: cs.surfaceContainerLow,
          child: Row(children: [
            SizedBox(width: 28, child: Text('#', style: head)),
            Expanded(child: Text('Description', style: head)),
            if (!narrow) SizedBox(width: 48, child: Text('Qty', style: head, textAlign: TextAlign.right)),
            if (!narrow) SizedBox(width: 104, child: Text('Rate', style: head, textAlign: TextAlign.right)),
            SizedBox(width: 112, child: Text('Amount', style: head, textAlign: TextAlign.right)),
          ]),
        ),
        for (final (i, l) in data.lines.indexed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: Gap.sm),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 28, child: Text('${i + 1}', style: muted)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.str('description')),
                  Text(
                    [
                      categoryLabel(l.strOrNull('category')),
                      if (l.str('service_code').isNotEmpty) l.str('service_code'),
                      if (narrow) '${l.integer('quantity', 1)} × ${formatMoney(l.integer('unit_price_paise'))}',
                    ].join(' · '),
                    style: muted,
                  ),
                ]),
              ),
              if (!narrow) SizedBox(width: 48, child: Text('${l.integer('quantity', 1)}', textAlign: TextAlign.right)),
              if (!narrow)
                SizedBox(width: 104, child: Align(alignment: Alignment.centerRight, child: MoneyText(l.integer('unit_price_paise')))),
              SizedBox(width: 112, child: Align(alignment: Alignment.centerRight, child: MoneyText(l.integer('amount_paise')))),
            ]),
          ),
      ]);

      Widget row(String label, int paise, {bool strong = false, bool minus = false}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(label, style: strong ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)),
              MoneyText(minus ? -paise : paise, style: strong ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700) : null),
            ]),
          );

      final discount = inv.integer('discount_paise');
      final totals = SizedBox(
        width: narrow ? double.infinity : 320,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          row('Total', inv.integer('gross_paise')),
          if (discount != 0) row('Discount${inv.str('discount_reason').isEmpty ? '' : ' (${inv.str('discount_reason')})'}', discount, minus: true),
          const Divider(),
          row(data.isCreditNote ? 'Credit' : 'Net payable', inv.integer('net_paise'), strong: true),
          if (!draft && !data.isCreditNote) ...[
            row('Received', BillingService.received(inv)),
            if (inv.integer('refunded_paise') > 0) row('Refunded', inv.integer('refunded_paise'), minus: true),
            row(cancelled ? 'Balance (cancelled)' : 'Balance due', cancelled ? 0 : inv.integer('balance_paise'), strong: true),
          ],
        ]),
      );

      final paper = Container(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        padding: EdgeInsets.all(pad),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (narrow) ...[letterhead, Gap.v16, docBlock] else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: letterhead),
            Gap.h24,
            docBlock,
          ]),
          if (draft || cancelled) ...[
            Gap.v16,
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                border: Border.all(color: cs.error),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                draft
                    ? 'DRAFT — not valid as a bill until it is finalised'
                    : 'CANCELLED${data.related == null ? '' : ' — reversed by credit note ${data.related!.str('number')}'}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(color: cs.error, letterSpacing: 0.6),
              ),
            ),
          ],
          if (data.isCreditNote && data.related != null) ...[
            Gap.v12,
            Text('Against bill ${data.related!.str('number')} dated ${formatDate(data.related!.date('finalised_at'))}'
                '${inv.str('cancel_reason').isEmpty ? '' : '. Reason: ${inv.str('cancel_reason')}'}'),
          ],
          Divider(height: Gap.xxl, color: cs.outlineVariant),
          patient,
          Gap.v24,
          lines,
          Gap.v16,
          Align(alignment: Alignment.centerRight, child: totals),
          Gap.v16,
          Text('${data.isCreditNote ? 'Amount credited' : 'Amount'}: ${amountInWords(inv.integer('net_paise').abs())}',
              style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
          if (received.isNotEmpty) ...[
            Gap.v24,
            Text('Received with thanks', style: theme.textTheme.titleSmall),
            Gap.v8,
            for (final x in received) _MoneyRow(x),
          ],
          if (refunds.isNotEmpty) ...[
            Gap.v16,
            Text('Refunded', style: theme.textTheme.titleSmall),
            Gap.v8,
            for (final x in refunds) _MoneyRow(x),
          ],
          Divider(height: Gap.xxl, color: cs.outlineVariant),
          Wrap(alignment: WrapAlignment.spaceBetween, runSpacing: Gap.sm, spacing: Gap.lg, children: [
            Text(
                inv.str('finalised_by_name').isEmpty
                    ? 'Prepared ${formatDateTime(inv.createdAt)}'
                    : 'Billed by ${inv.str('finalised_by_name')} · ${formatDateTime(inv.date('finalised_at'))}',
                style: muted),
            Text('Computer-generated bill. No signature needed.', style: muted),
          ]),
        ]),
      );
      return Padding(padding: const EdgeInsets.only(bottom: Gap.xl), child: paper);
    });
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value.isEmpty ? '—' : value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow(this.payment);
  final Rec payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = payment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(
            [
              p.str('number'),
              modeLabel(p.str('mode')),
              if (p.str('reference').isNotEmpty) 'Ref ${p.str('reference')}',
              formatDateTime(p.date('received_at')),
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ),
        Gap.h8,
        MoneyText(p.integer('amount_paise'), style: theme.textTheme.bodyMedium),
      ]),
    );
  }
}

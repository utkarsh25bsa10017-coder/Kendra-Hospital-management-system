import 'dart:typed_data';

import 'package:kendra_hms/core/core.dart';
import 'package:pdf/widgets.dart' as pw;

import '../billing_schema.dart';
import '../billing_service.dart';
import 'invoice_screen.dart';

/// The printed bill / receipt / credit note: the same content as the
/// receipt screen, on A4.
Future<Uint8List> billPdf(BillData data, Letterhead letterhead) {
  final inv = data.invoice;
  final p = data.patient;
  final draft = data.isDraft;
  final cancelled = inv.str('status') == InvoiceStatus.cancelled;
  final when = inv.date('finalised_at') ?? inv.createdAt;
  final received = data.payments.where((x) => x.str('kind') != PaymentKind.refund).toList();
  final refunds = data.payments.where((x) => x.str('kind') == PaymentKind.refund).toList();
  final insured = inv.str('payer_type') != 'self';
  final discount = inv.integer('discount_paise');

  pw.Widget payments(String title, List<Rec> list) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        PrintKit.section(title),
        for (final x in list)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Row(children: [
              pw.Expanded(
                child: pw.Text(
                  [
                    x.str('number'),
                    modeLabel(x.str('mode')),
                    if (x.str('reference').isNotEmpty) 'Ref ${x.str('reference')}',
                    formatDateTime(x.date('received_at')),
                  ].join(' · '),
                  style: PrintKit.muted,
                ),
              ),
              pw.Text(formatMoney(x.integer('amount_paise'))),
            ]),
          ),
      ]);

  return PrintDoc(
    letterhead: letterhead,
    title: '${data.isCreditNote ? 'Credit note' : 'Bill'} ${inv.str('number')}',
    label: data.isCreditNote ? 'CREDIT NOTE' : (draft ? 'DRAFT' : 'BILL / RECEIPT'),
    meta: [inv.str('number'), formatDateTime(when)],
    banner: draft
        ? 'DRAFT — not valid as a bill until it is finalised'
        : cancelled
            ? 'CANCELLED${data.related == null ? '' : ' — reversed by credit note ${data.related!.str('number')}'}'
            : null,
    footer: inv.str('finalised_by_name').isEmpty
        ? 'Prepared ${formatDateTime(inv.createdAt)}. Computer-generated bill. No signature needed.'
        : 'Billed by ${inv.str('finalised_by_name')}, ${formatDateTime(inv.date('finalised_at'))}. '
            'Computer-generated bill. No signature needed.',
    body: [
      if (data.isCreditNote && data.related != null)
        PrintKit.paragraph('Against bill ${data.related!.str('number')} dated ${formatDate(data.related!.date('finalised_at'))}'
            '${inv.str('cancel_reason').isEmpty ? '' : '. Reason: ${inv.str('cancel_reason')}'}'),
      PrintKit.fields([
        ('Patient', inv.str('patient_name')),
        ('UHID', inv.str('patient_uhid')),
        if (p != null) ('Age / sex', '${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${genderLabel(p.strOrNull('gender'))}'),
        if (p != null && p.str('phone').isNotEmpty) ('Mobile', p.str('phone')),
        ('Payer', [payerLabel(inv.strOrNull('payer_type')), if (p != null && insured && p.str('insurer').isNotEmpty) p.str('insurer')].join(' · ')),
        if (p != null && insured && p.str('policy_no').isNotEmpty) ('Policy / ID', p.str('policy_no')),
      ]),
      pw.SizedBox(height: 14),
      PrintKit.table(
        headers: ['#', 'Description', 'Qty', 'Rate', 'Amount'],
        widths: const {0: pw.FixedColumnWidth(22), 2: pw.FixedColumnWidth(34), 3: pw.FixedColumnWidth(72), 4: pw.FixedColumnWidth(80)},
        right: const {2, 3, 4},
        rows: [
          for (final (i, l) in data.lines.indexed)
            [
              '${i + 1}',
              PrintKit.twoLine(l.str('description'),
                  [categoryLabel(l.strOrNull('category')), if (l.str('service_code').isNotEmpty) l.str('service_code')].join(' · ')),
              '${l.integer('quantity', 1)}',
              formatMoney(l.integer('unit_price_paise')),
              formatMoney(l.integer('amount_paise')),
            ],
        ],
      ),
      pw.SizedBox(height: 8),
      PrintKit.totals([
        ('Total', inv.integer('gross_paise'), strong: false),
        if (discount != 0)
          ('Discount${inv.str('discount_reason').isEmpty ? '' : ' (${inv.str('discount_reason')})'}', -discount, strong: false),
        ('', null, strong: false),
        (data.isCreditNote ? 'Credit' : 'Net payable', inv.integer('net_paise'), strong: true),
        if (!draft && !data.isCreditNote) ...[
          ('Received', BillingService.received(inv), strong: false),
          if (inv.integer('refunded_paise') > 0) ('Refunded', -inv.integer('refunded_paise'), strong: false),
          (cancelled ? 'Balance (cancelled)' : 'Balance due', cancelled ? 0 : inv.integer('balance_paise'), strong: true),
        ],
      ]),
      pw.SizedBox(height: 8),
      pw.Text('${data.isCreditNote ? 'Amount credited' : 'Amount'}: ${amountInWords(inv.integer('net_paise').abs())}',
          style: pw.TextStyle(fontStyle: pw.FontStyle.italic)),
      if (received.isNotEmpty) payments('Received with thanks', received),
      if (refunds.isNotEmpty) payments('Refunded', refunds),
    ],
  ).build();
}

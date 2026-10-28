import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'billing_widgets.dart';

class _PatientMoney {
  _PatientMoney(this.unbilled, this.bills, this.payments);
  final List<Rec> unbilled;
  final List<Rec> bills;
  final List<Rec> payments;

  int get unbilledTotal => unbilled.fold<int>(0, (a, c) => a + c.integer('amount_paise'));
  int get due => bills
      .where((b) => b.str('status') == InvoiceStatus.finalised && b.str('kind') == InvoiceKind.invoice)
      .fold<int>(0, (a, b) => a + b.integer('balance_paise'));
  int get paid => payments.fold<int>(0, (a, p) => a + (p.str('kind') == PaymentKind.refund ? -1 : 1) * p.integer('amount_paise'));
}

/// The patient profile's "Bills" tab: what is waiting, what was billed,
/// what was paid.
class PatientBillsTab extends StatelessWidget {
  const PatientBillsTab({super.key, required this.patient});
  final Rec patient;

  @override
  Widget build(BuildContext context) {
    final canBill = context.can(BillingPerms.invoice);
    final theme = Theme.of(context);
    return LiveBuilder<_PatientMoney>(
      watch: const {Col.charges, BillCol.invoices, BillCol.payments},
      deps: [patient.id],
      load: (db) async => _PatientMoney(
        await BillingService.unbilledFor(db, patient.id),
        await db.query(Query(BillCol.invoices).eq('patient_id', patient.id).sort('bill_date', desc: true).take(50)),
        await db.query(Query(BillCol.payments).eq('patient_id', patient.id).sort('received_at', desc: true).take(30)),
      ),
      builder: (context, d) {
        String whole(int p) => formatMoney(p, alwaysDecimals: false);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ResponsiveGrid(minWidth: 170, spacing: Gap.md, children: [
            KpiTile(
                label: 'Not billed yet',
                value: whole(d.unbilledTotal),
                caption: plural(d.unbilled.length, 'charge'),
                icon: Icons.pending_actions_outlined,
                tone: d.unbilled.isEmpty ? Tone.neutral : Tone.warning),
            KpiTile(
                label: 'Balance due',
                value: whole(d.due),
                caption: d.due > 0 ? 'On final bills' : (d.due < 0 ? 'We owe the patient' : 'Nothing due'),
                icon: Icons.hourglass_bottom,
                tone: d.due > 0 ? Tone.warning : Tone.success),
            KpiTile(label: 'Paid', value: whole(d.paid), caption: 'Recent payments, net of refunds', icon: Icons.payments_outlined, tone: Tone.info),
            KpiTile(label: 'Bills', value: '${d.bills.where((b) => b.str('kind') == InvoiceKind.invoice).length}', caption: 'Including drafts', icon: Icons.receipt_long_outlined),
          ]),
          if (d.unbilled.isNotEmpty) ...[
            Gap.v16,
            SectionCard(
              title: 'Not billed yet',
              subtitle: 'Charges posted by the departments',
              trailing: canBill
                  ? FilledButton.icon(
                      onPressed: () => openBillForPatient(context, patient.id),
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('Create bill'))
                  : null,
              child: Column(children: [
                for (final (i, c) in d.unbilled.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c.str('description'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                          MutedText('${categoryLabel(c.strOrNull('category'))} · ${sourceLabel(c.strOrNull('source_module'))} · '
                              '${formatDate(c.date('service_date') ?? c.createdAt)}'),
                        ]),
                      ),
                      MoneyText(c.integer('amount_paise')),
                    ]),
                  ),
                ],
              ]),
            ),
          ],
          Gap.v16,
          BillSectionHeader('Bills', subtitle: d.bills.isEmpty ? null : 'Newest first'),
          DataList<Rec>(
            items: d.bills,
            empty: Card(
              child: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No bills yet',
                action: canBill && d.unbilled.isEmpty
                    ? OutlinedButton(onPressed: () => openBillForPatient(context, patient.id), child: const Text('Start a bill'))
                    : null,
              ),
            ),
            onTap: (b) => context.app.nav.open('billing.invoice', {'id': b.id}),
            title: (b) => b.str('number'),
            subtitle: (b) => '${formatDate(b.date('bill_date'))} · net ${formatMoney(b.integer('net_paise'))}',
            trailing: (b) => InvoiceStatusChip(b),
            columns: [
              ListColumn('Bill', (b) => TwoLine(b.str('number'), formatDateTime(b.date('bill_date'))), flex: 3),
              ListColumn('Status', (b) => InvoiceStatusChip(b), width: 140),
              ListColumn('Net', (b) => MoneyText(b.integer('net_paise')), width: 116, numeric: true),
              ListColumn('Received', (b) => MoneyText(b.integer('paid_paise')), width: 116, numeric: true),
              ListColumn('Balance', (b) => MoneyText(b.integer('balance_paise')), width: 116, numeric: true),
            ],
          ),
          if (d.payments.isNotEmpty) ...[
            Gap.v16,
            SectionCard(
              title: 'Payments and refunds',
              child: Column(children: [
                for (final (i, p) in d.payments.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  PaymentTile(p, showBill: true, onTap: () => context.app.nav.open('billing.invoice', {'id': p.str('invoice_id')})),
                ],
              ]),
            ),
          ],
        ]);
      },
    );
  }
}

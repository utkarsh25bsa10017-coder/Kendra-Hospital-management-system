import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

abstract final class BillingPerms {
  static const view = 'billing.view';
  static const invoice = 'billing.invoice';
  static const payment = 'billing.payment';
  static const closeDay = 'billing.close_day';
}

/// Billing's own tables.
abstract final class BillCol {
  static const invoices = 'invoices';
  static const lines = 'invoice_lines';
  static const payments = 'payments';
  static const closings = 'day_closings';
}

/// Approval types Billing owns (see `approvalHandlers`).
abstract final class BillingApprovals {
  static const discount = 'billing.discount';
  static const refund = 'billing.refund';
  static const cancel = 'billing.cancel';
}

abstract final class InvoiceStatus {
  static const draft = 'draft';
  static const finalised = 'final';
  static const cancelled = 'cancelled';
}

abstract final class InvoiceKind {
  static const invoice = 'invoice';
  static const creditNote = 'credit_note';
}

abstract final class PaymentKind {
  static const payment = 'payment';
  static const refund = 'refund';
  static const advance = 'advance';
}

const invoicesCollection = CollectionSchema(
  name: BillCol.invoices,
  owner: 'billing',
  description: 'Bills and credit notes. A final bill is never edited: corrections are credit notes and refunds.',
  // Board members apply approved discounts, refunds and cancellations.
  writePermissions: {BillingPerms.invoice, BillingPerms.payment, CorePerms.approvalsDecide},
  compositeIndexes: [
    ['patient_id', 'status'],
  ],
  fields: [
    Field.text('number', required: true, unique: true, searchable: true), // DRAFT-12, INV-26-000123, CN-26-000004
    Field.text('kind', required: true, indexed: true), // invoice | credit_note
    Field.text('credit_note_for', indexed: true), // invoice id a credit note reverses
    Field.ref('patient_id', Col.patients, required: true),
    Field.text('patient_name', searchable: true),
    Field.text('patient_uhid', searchable: true),
    Field.ref('encounter_id', Col.encounters),
    Field.text('payer_type', indexed: true), // self | insurance | corporate
    Field.text('status', required: true, indexed: true), // draft | final | cancelled
    Field.integer('gross_paise'),
    Field.integer('discount_paise'),
    Field.integer('net_paise'),
    Field.integer('paid_paise'), // payments minus refunds: money held against this bill
    Field.integer('refunded_paise'),
    Field.integer('adjusted_paise'), // part of the refunds that reduced what the patient owes
    Field.integer('balance_paise'), // net - adjusted - paid; negative = we owe the patient
    Field.dateTime('bill_date', indexed: true), // created (drafts) or finalised
    Field.dateTime('finalised_at', indexed: true),
    Field.ref('finalised_by', Col.users),
    Field.text('finalised_by_name'),
    Field.text('discount_reason'),
    Field.ref('discount_by', Col.users),
    Field.text('discount_by_name'),
    Field.dateTime('discount_at', indexed: true),
    Field.text('discount_approval_id'),
    Field.dateTime('cancelled_at'),
    Field.text('cancel_reason'),
    Field.text('cancel_approval_id'),
    Field.text('notes'),
  ],
);

const invoiceLinesCollection = CollectionSchema(
  name: BillCol.lines,
  owner: 'billing',
  writePermissions: {BillingPerms.invoice, CorePerms.approvalsDecide},
  fields: [
    Field.ref('invoice_id', BillCol.invoices, required: true),
    Field.ref('patient_id', Col.patients),
    Field.integer('position'),
    Field.text('charge_id', indexed: true),
    Field.text('source'), // charge | manual
    Field.text('source_module'),
    Field.text('service_code', indexed: true),
    Field.text('description', required: true),
    Field.text('category'),
    Field.integer('quantity'),
    Field.integer('unit_price_paise'),
    Field.integer('list_price_paise'), // price-list price when the line was made
    Field.integer('amount_paise'),
    Field.integer('discount_paise'), // this line's share of the bill discount
    Field.integer('net_paise'),
    Field.dateTime('service_date'),
  ],
);

const paymentsCollection = CollectionSchema(
  name: BillCol.payments,
  owner: 'billing',
  description: 'Money in (payments, advances) and out (refunds). amount_paise is always positive.',
  writePermissions: {BillingPerms.payment, CorePerms.approvalsDecide},
  fields: [
    Field.text('number', required: true, unique: true, searchable: true), // RCPT-26-000123 / RFND-26-000004
    Field.ref('invoice_id', BillCol.invoices),
    Field.text('invoice_number', searchable: true),
    Field.ref('patient_id', Col.patients, required: true),
    Field.text('patient_name', searchable: true),
    Field.text('kind', required: true, indexed: true), // payment | refund | advance
    Field.text('mode', required: true, indexed: true), // cash | card | upi | cheque | insurance | other
    Field.integer('amount_paise', required: true),
    Field.text('reference'),
    Field.ref('received_by', Col.users),
    Field.text('received_by_name'),
    Field.dateTime('received_at', required: true, indexed: true),
    Field.text('approval_id'),
    Field.text('notes'),
  ],
);

const dayClosingsCollection = CollectionSchema(
  name: BillCol.closings,
  owner: 'billing',
  description: 'A cashier counting the cash drawer at the end of the day.',
  writePermissions: {BillingPerms.closeDay},
  fields: [
    Field.text('closing_date', required: true, indexed: true), // yyyy-MM-dd
    Field.ref('user_id', Col.users, required: true),
    Field.text('user_name'),
    Field.json('expected'), // {"cash": paise, "upi": paise, ...}, payments minus refunds
    Field.integer('expected_cash_paise'),
    Field.integer('counted_cash_paise'),
    Field.integer('variance_paise'), // counted - expected; negative = short
    Field.text('notes'),
    Field.dateTime('closed_at', required: true, indexed: true),
  ],
);

const billingCollections = [invoicesCollection, invoiceLinesCollection, paymentsCollection, dayClosingsCollection];

/// Payment modes, most common first.
const paymentModes = <(String, String)>[
  ('cash', 'Cash'),
  ('upi', 'UPI'),
  ('card', 'Card'),
  ('cheque', 'Cheque'),
  ('insurance', 'Insurance'),
  ('other', 'Other'),
];

/// Modes that need a transaction / cheque / claim reference.
const modesNeedingReference = {'card', 'upi', 'cheque', 'insurance'};

String modeLabel(String mode) {
  for (final (m, l) in paymentModes) {
    if (m == mode) return l;
  }
  return titleCase(mode);
}

IconData modeIcon(String mode) => switch (mode) {
      'cash' => Icons.payments_outlined,
      'upi' => Icons.qr_code_2,
      'card' => Icons.credit_card,
      'cheque' => Icons.receipt_outlined,
      'insurance' => Icons.health_and_safety_outlined,
      _ => Icons.account_balance_wallet_outlined,
    };

String categoryLabel(String? c) => switch (c) {
      Vals.consultation => 'Consultation',
      Vals.lab => 'Lab',
      Vals.radiology => 'Radiology',
      Vals.pharmacy => 'Pharmacy',
      Vals.procedure => 'Procedure',
      Vals.bed => 'Bed / room',
      Vals.nursing => 'Nursing',
      Vals.other => 'Other',
      null || '' => 'Other',
      _ => titleCase(c),
    };

String payerLabel(String? p) => switch (p) {
      'insurance' => 'Insurance',
      'corporate' => 'Corporate',
      _ => 'Self pay',
    };

String sourceLabel(String? module) => switch (module) {
      null || '' => 'Added at billing',
      'opd' => 'OPD',
      'ipd' => 'IPD',
      'lab' => 'Lab',
      'pharmacy' => 'Pharmacy',
      'appointments' => 'Appointments',
      'billing' => 'Billing',
      _ => titleCase(module),
    };

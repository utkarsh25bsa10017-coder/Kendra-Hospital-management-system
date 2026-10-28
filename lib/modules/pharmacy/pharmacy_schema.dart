import 'package:kendra_hms/core/core.dart';

abstract final class PharmacyPerms {
  static const view = 'pharmacy.view';
  static const dispense = 'pharmacy.dispense';
  static const purchase = 'pharmacy.purchase';
  static const catalog = 'pharmacy.catalog';
  static const adjust = 'pharmacy.adjust';
}

/// Pharmacy tables. Stock lives in batches; every change to a batch's
/// quantity is a movement written in the same batch() as the update, so a
/// batch's `qty_on_hand` always equals the sum of its movements.
abstract final class PCol {
  static const products = 'pharmacy_products';
  static const suppliers = 'pharmacy_suppliers';
  static const batches = 'pharmacy_batches';
  static const movements = 'pharmacy_movements';
  static const orders = 'pharmacy_orders';
  static const receipts = 'pharmacy_receipts';
  static const dispenses = 'pharmacy_dispenses';
}

/// pharmacy_movements.type
abstract final class MoveType {
  static const receipt = 'receipt';
  static const dispense = 'dispense';
  static const returned = 'return';
  static const adjustment = 'adjustment';
  static const expiryWriteoff = 'expiry_writeoff';

  static String label(String t) => switch (t) {
        receipt => 'Received',
        dispense => 'Dispensed',
        returned => 'Returned',
        adjustment => 'Adjustment',
        expiryWriteoff => 'Expiry write-off',
        _ => titleCase(t),
      };
}

/// pharmacy_orders.status
abstract final class PoStatus {
  static const draft = 'draft';
  static const ordered = 'ordered';
  static const received = 'received';
  static const cancelled = 'cancelled';
}

/// pharmacy_dispenses.kind
abstract final class DispenseKind {
  static const prescription = 'prescription';
  static const counter = 'counter';
  static const returned = 'return';
}

/// Stock may be changed by whoever dispenses, receives or adjusts it, and by
/// board members carrying out an approved adjustment or write-off.
const _stockWriters = {
  PharmacyPerms.dispense,
  PharmacyPerms.purchase,
  PharmacyPerms.adjust,
  CorePerms.approvalsDecide,
};

const pharmacyCollections = <CollectionSchema>[
  CollectionSchema(
    name: PCol.products,
    owner: 'pharmacy',
    description: 'What the pharmacy stocks: one product per core medicine, with prices and reorder rules.',
    writePermissions: {PharmacyPerms.catalog, PharmacyPerms.purchase},
    fields: [
      Field.ref('medicine_id', Col.medicines),
      Field.text('name', required: true, searchable: true),
      Field.text('generic_name', searchable: true),
      Field.text('sku', required: true, unique: true, searchable: true),
      Field.text('unit'), // dispensing unit, copied from the medicine
      Field.integer('mrp_paise'), // per dispensing unit
      Field.integer('purchase_price_paise'), // last cost per unit
      Field.real('gst_percent'),
      Field.integer('reorder_level'),
      Field.integer('reorder_qty'),
      Field.text('rack'),
      Field.ref('preferred_supplier_id', PCol.suppliers),
      Field.boolean('active', indexed: true),
    ],
  ),
  CollectionSchema(
    name: PCol.suppliers,
    owner: 'pharmacy',
    writePermissions: {PharmacyPerms.purchase, PharmacyPerms.catalog},
    fields: [
      Field.text('name', required: true, searchable: true),
      Field.text('phone', searchable: true),
      Field.text('gstin'),
      Field.text('address'),
      Field.integer('lead_days'),
      Field.boolean('active', indexed: true),
    ],
  ),
  CollectionSchema(
    name: PCol.batches,
    owner: 'pharmacy',
    description: 'Stock on the shelf, per batch. qty_on_hand only changes together with a movement.',
    writePermissions: _stockWriters,
    compositeIndexes: [
      ['product_id', 'expiry_date'],
    ],
    fields: [
      Field.ref('product_id', PCol.products, required: true),
      Field.text('batch_no', required: true, searchable: true),
      Field.dateTime('expiry_date', indexed: true), // last day of the expiry month
      Field.integer('mrp_paise'),
      Field.integer('cost_paise'),
      Field.integer('qty_received'),
      Field.integer('qty_on_hand', indexed: true),
      Field.ref('supplier_id', PCol.suppliers),
      Field.ref('receipt_id', PCol.receipts),
    ],
  ),
  CollectionSchema(
    name: PCol.movements,
    owner: 'pharmacy',
    description: 'Every change in stock, signed: + into the shelf, − out of it.',
    writePermissions: _stockWriters,
    fields: [
      Field.ref('product_id', PCol.products),
      Field.ref('batch_id', PCol.batches),
      Field.integer('qty'),
      Field.text('type', indexed: true), // receipt | dispense | return | adjustment | expiry_writeoff
      Field.text('ref_collection'),
      Field.text('ref_id', indexed: true),
      Field.text('reason'),
      Field.ref('patient_id', Col.patients),
      Field.integer('value_paise'), // qty × cost, signed like qty
      Field.text('by_name'),
      Field.dateTime('moved_at', indexed: true),
    ],
  ),
  CollectionSchema(
    name: PCol.orders,
    owner: 'pharmacy',
    writePermissions: {PharmacyPerms.purchase, CorePerms.approvalsDecide},
    fields: [
      Field.text('number', required: true, unique: true, searchable: true), // PO-26-000012
      Field.ref('supplier_id', PCol.suppliers),
      Field.text('status', required: true, indexed: true), // draft | ordered | received | cancelled
      Field.json('items'), // [{product_id, name, qty, cost_paise}]
      Field.integer('total_paise'),
      Field.dateTime('raised_at', indexed: true),
      Field.dateTime('ordered_at'),
      Field.dateTime('expected_at'),
      Field.dateTime('received_at'),
      Field.boolean('from_proposal'),
      Field.text('notes'),
      Field.text('cancel_reason'),
    ],
  ),
  CollectionSchema(
    name: PCol.receipts,
    owner: 'pharmacy',
    writePermissions: {PharmacyPerms.purchase},
    fields: [
      Field.text('number', required: true, unique: true, searchable: true), // GRN-26-000007
      Field.ref('supplier_id', PCol.suppliers),
      Field.ref('order_id', PCol.orders),
      Field.text('supplier_invoice_no', searchable: true),
      // [{product_id, name, batch_id, batch_no, expiry, qty, cost_paise, mrp_paise, amount_paise}]
      Field.json('items'),
      Field.integer('total_paise'),
      Field.dateTime('received_at', indexed: true),
      Field.text('received_by_name'),
    ],
  ),
  CollectionSchema(
    name: PCol.dispenses,
    owner: 'pharmacy',
    writePermissions: {PharmacyPerms.dispense},
    compositeIndexes: [
      ['patient_id', 'dispensed_at'],
    ],
    fields: [
      Field.text('number', required: true, unique: true, searchable: true), // PH-26-000123
      Field.ref('patient_id', Col.patients),
      Field.ref('encounter_id', Col.encounters),
      Field.ref('prescription_id', Col.prescriptions),
      Field.ref('doctor_id', Col.users),
      Field.text('kind', required: true, indexed: true), // prescription | counter | return
      // [{product_id, name, batch_id, batch_no, expiry, qty, mrp_paise, amount_paise, rx_index?, of_index?}]
      Field.json('items'),
      Field.integer('total_paise'), // negative for returns
      Field.text('dispensed_by_name'),
      Field.dateTime('dispensed_at', indexed: true),
      Field.ref('return_of', PCol.dispenses), // the original dispense, for returns
      Field.text('reason'),
    ],
  ),
];

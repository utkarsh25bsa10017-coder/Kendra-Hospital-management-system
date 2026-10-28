// Renders the billing screens to build/screens/billing_<size>_*.png.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/billing/billing_module.dart';
import 'package:kendra_hms/modules/billing/billing_schema.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

Future<Map<String, Object?>> _first(AppServices app, Query q) async {
  final r = await app.store.query(q.take(1));
  if (r.isEmpty) throw StateError('No record for ${q.collection}');
  return {'id': r.first.id};
}

Future<Map<String, Object?>> _draft(AppServices app) =>
    _first(app, const Query(BillCol.invoices).eq('status', InvoiceStatus.draft).sort('created_at', desc: true));

/// A final bill that is paid in full, preferably one with a discount.
Future<Map<String, Object?>> _paid(AppServices app) async {
  const paid = Query(BillCol.invoices);
  final q = paid.eq('kind', InvoiceKind.invoice).eq('status', InvoiceStatus.finalised).eq('balance_paise', 0);
  final withDiscount = await app.store.query(q.gt('discount_paise', 0).sort('finalised_at', desc: true).take(1));
  return withDiscount.isNotEmpty ? {'id': withDiscount.first.id} : _first(app, q.sort('finalised_at', desc: true));
}

Future<Map<String, Object?>> _unpaid(AppServices app) => _first(
    app,
    const Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .eq('status', InvoiceStatus.finalised)
        .gt('balance_paise', 0)
        .sort('finalised_at', desc: true));

Future<Map<String, Object?>> _patientWithBills(AppServices app) async {
  final inv = await app.store.query(const Query(BillCol.invoices).eq('status', InvoiceStatus.finalised).gt('discount_paise', 0).take(1));
  return {'id': inv.first.str('patient_id')};
}

Future<void> _tap(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) return;
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

final _specs = [
  const ShotSpec('desk', 'billing.desk'),
  ShotSpec('draft', 'billing.invoice', args: _draft),
  ShotSpec('bill_paid', 'billing.invoice', args: _paid),
  ShotSpec('receipt', 'billing.receipt', args: _paid),
  const ShotSpec('bills', 'billing.invoices'),
  const ShotSpec('collections', 'billing.collections'),
  const ShotSpec('prices', 'billing.prices'),
  ShotSpec('patient_bills', 'patients.profile',
      args: _patientWithBills, after: (t, app) => _tap(t, find.widgetWithText(Tab, 'Bills'))),
  // Dialogs stay open, so this one goes last.
  ShotSpec('payment', 'billing.invoice',
      args: _unpaid, after: (t, app) => _tap(t, find.text('Take payment'))),
];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('billing $name', (t) async {
      await captureScreens(t,
          prefix: 'billing_$name',
          size: size,
          modules: [PatientsModule(), BillingModule()],
          specs: _specs,
          username: 'billing');
    });
  }
}

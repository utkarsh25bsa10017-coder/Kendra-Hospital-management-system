// Prints the demo hospital's bills to build/print/billing_*.pdf.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/billing/billing_schema.dart';
import 'package:kendra_hms/modules/billing/screens/bill_print.dart';
import 'package:kendra_hms/modules/billing/screens/invoice_screen.dart';

import '../../helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every kind of bill prints', () async {
    final app = await bootTestHospital(installedModules(), demo: true);
    addTearDown(app.close);
    app.agents!.dispose();
    await signInDemo(app, 'billing');
    final head = Letterhead.of(app.settings);
    expect(head.name, isNot('Hospital'));

    Future<void> printFirst(String name, Query q) async {
      final inv = await app.readDb.first(q);
      expect(inv, isNotNull, reason: 'the demo has no $name');
      final data = (await BillData.load(app.readDb, inv!.id))!;
      expectPdf(await billPdf(data, head), 'billing_$name');
    }

    const bills = Query(BillCol.invoices);
    final finalBills = bills.eq('kind', InvoiceKind.invoice).eq('status', InvoiceStatus.finalised);
    await printFirst('paid_discount', finalBills.eq('balance_paise', 0).gt('discount_paise', 0));
    await printFirst('unpaid', finalBills.gt('balance_paise', 0));
    await printFirst('draft', bills.eq('status', InvoiceStatus.draft));
    if (await app.readDb.first(bills.eq('kind', InvoiceKind.creditNote)) != null) {
      await printFirst('credit_note', bills.eq('kind', InvoiceKind.creditNote));
      await printFirst('cancelled', bills.eq('status', InvoiceStatus.cancelled));
    }
  });
}

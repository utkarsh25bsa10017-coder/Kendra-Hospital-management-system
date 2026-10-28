// Prints the demo hospital's lab reports to build/print/lab_*.pdf.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/lab/lab_module.dart';
import 'package:kendra_hms/modules/lab/lab_service.dart';
import 'package:kendra_hms/modules/lab/screens/report_print.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('verified, provisional and critical reports print', () async {
    final app = await bootTestHospital([PatientsModule(), LabModule()], demo: true);
    addTearDown(app.close);
    app.agents!.dispose();
    await signInDemo(app, 'pathology');
    final head = Letterhead.of(app.settings);

    Future<void> printFirst(String name, Query q) async {
      final order = await app.readDb.first(q);
      expect(order, isNotNull, reason: 'the demo has no $name report');
      final item = (await LabService.loadItems(app.readDb, [order!])).single;
      expect(item.result, isNotNull, reason: name);
      expectPdf(await labReportPdf(item, head), 'lab_$name', pages: 1);
    }

    final verified = LabService.labOrders().eq('status', Vals.verified);
    await printFirst('verified', verified.eq('abnormal', false));
    await printFirst('abnormal', verified.eq('abnormal', true).eq('critical', false));
    await printFirst('critical', verified.eq('critical', true));
    await printFirst('provisional', LabService.labOrders().eq('status', Vals.resulted));
  });
}

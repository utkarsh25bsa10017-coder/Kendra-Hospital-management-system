// Prints the demo hospital's discharge summaries to build/print/ipd_*.pdf.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/ipd/ipd_schema.dart';
import 'package:kendra_hms/modules/ipd/screens/discharge_print.dart';

import '../../helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('discharge summaries print at every stage of a stay', () async {
    final app = await bootTestHospital(installedModules(), demo: true);
    addTearDown(app.close);
    app.agents!.dispose();
    await signInDemo(app, 'nurse');
    final head = Letterhead.of(app.settings);

    Future<DischargeData> printOne(String name, String id) async {
      final data = (await DischargeData.load(app.readDb, id))!;
      expectPdf(await dischargePdf(data, head), 'ipd_$name', pages: 1);
      return data;
    }

    Future<DischargeData> printFirst(String name, Query q) async {
      final a = await app.readDb.first(q);
      expect(a, isNotNull, reason: 'the demo has no $name admission');
      return printOne(name, a!.id);
    }

    const stays = Query(IpdCol.admissions);
    final discharged = await printFirst('discharged', stays.eq('status', IpdVals.discharged).sort('discharged_at', desc: true));
    expect(discharged.view.admission.str('discharge_summary'), isNotEmpty);
    await printFirst('signed_off', stays.eq('status', IpdVals.dischargePending));
    await printFirst('provisional', stays.eq('status', IpdVals.admitted).sort('admitted_at'));

    final moved = await app.readDb.first(const Query(IpdCol.transfers).sort('at', desc: true));
    expect(moved, isNotNull, reason: 'the demo has a bed transfer');
    final withMove = await printOne('transferred', moved!.str('admission_id'));
    expect(withMove.transfers, isNotEmpty);
    expect(await DischargeData.load(app.readDb, 'no-such-admission'), isNull);
  });
}

// Prints the demo hospital's prescriptions to build/print/opd_*.pdf.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/module_list.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/opd/opd_schema.dart';
import 'package:kendra_hms/modules/opd/screens/consultation_note_screen.dart';
import 'package:kendra_hms/modules/opd/screens/prescription_print.dart';

import '../../helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signed and unsigned prescriptions print', () async {
    final app = await bootTestHospital(installedModules(), demo: true);
    addTearDown(app.close);
    app.agents!.dispose();
    await signInDemo(app, 'board');
    final head = Letterhead.of(app.settings);

    // A signed visit with medicines and tests, the fullest the demo has.
    final signed = await app.readDb
        .query(const Query(OpdCol.consultations).eq('status', ConsultStatus.signed).isNotNull('prescription_id').take(200));
    NoteData? full;
    for (final c in signed) {
      final d = (await NoteData.load(app.readDb, c.id))!;
      if (d.items.isNotEmpty && d.orders.isNotEmpty && (full == null || d.items.length > full.items.length)) full = d;
    }
    expect(full, isNotNull, reason: 'the demo has no signed visit with medicines and tests');
    expect(full!.signed, isTrue);
    expect(prescriptionName(full), startsWith('Prescription ${full.patient!.str('full_name')}'));
    expectPdf(await prescriptionPdf(full, head), 'opd_signed', pages: 1);

    // Loading by id gives the same document.
    expectPdf(await prescriptionPdfFor(app.readDb, head, full.consultation.id), 'opd_signed_by_id');
    expect(() => prescriptionPdfFor(app.readDb, head, 'missing'), throwsA(isA<ValidationException>()));

    final draft = await app.readDb.first(const Query(OpdCol.consultations).eq('status', ConsultStatus.draft));
    if (draft != null) {
      final d = (await NoteData.load(app.readDb, draft.id))!;
      expect(d.signed, isFalse);
      expectPdf(await prescriptionPdf(d, head), 'opd_unsigned');
    }
  });
}

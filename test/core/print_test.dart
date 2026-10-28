import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:pdf/pdf.dart';

import '../helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled font has the rupee sign, the minus sign and accented letters', () async {
    final font = TtfParser(await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
    for (final c in '₹−—·×éñü'.runes) {
      expect(font.charToGlyphIndexMap[c], isNotNull, reason: 'missing ${String.fromCharCode(c)}');
    }
  });

  test('a document has the letterhead, flows over pages and numbers them', () async {
    const head = Letterhead(name: 'Test Hospital', address: '12 MG Road, Pune', phone: '020 1234', gstin: '27ABCDE1234F1Z5');
    expect(head.lines, ['12 MG Road, Pune', 'Phone 020 1234', 'GSTIN 27ABCDE1234F1Z5']);
    final short = await PrintDoc(
      letterhead: head,
      label: 'BILL / RECEIPT',
      meta: const ['B-0001', '1 Jan 2026'],
      banner: 'DRAFT',
      body: [
        PrintKit.fields(const [('Patient', 'Ravi Kumar'), ('UHID', 'TH-000001'), ('Mobile', '')]),
        PrintKit.table(headers: const ['#', 'Item', 'Amount'], right: const {2}, rows: [
          ['1', PrintKit.twoLine('Consultation', 'OPD'), formatMoney(50000)],
        ]),
        PrintKit.totals(const [('Total', 50000, strong: false), ('', null, strong: false), ('Net', 50000, strong: true)]),
        PrintKit.signature('Consultant', name: 'Dr Mehta'),
      ],
    ).build();
    expectPdf(short, 'core_sample', pages: 1);

    final long = await PrintDoc(
      letterhead: head,
      label: 'LABORATORY REPORT',
      body: [
        PrintKit.table(headers: const ['Test', 'Result'], rows: [
          for (var i = 0; i < 150; i++) ['Test $i', '${i * 3}'],
        ]),
      ],
    ).build();
    expect(pdfPages(long), greaterThan(1));
  });
}

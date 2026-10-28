import 'dart:typed_data';

import 'package:kendra_hms/core/core.dart';
import 'package:pdf/widgets.dart' as pw;

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

/// The printed lab report: the same content as the report view, on A4.
Future<Uint8List> labReportPdf(LabItem item, Letterhead letterhead) {
  final order = item.order;
  final result = item.result;
  final patient = item.patient;
  final values = result?.maps('values') ?? const [];
  final verified = result?.str('status') == ResultStatus.verified;
  final amended = (result?.maps('history') ?? const []).isNotEmpty;
  final sampleId = order.str('sample_id');

  pw.Widget valueCell(Map<String, Object?> v) {
    final flag = v['flag'] as String? ?? '';
    return pw.Text('${v['value']}',
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: flag.isEmpty ? null : pw.FontWeight.bold,
          color: LabFlag.isCritical(flag) ? PrintKit.danger : null,
        ));
  }

  // H / L on their own; criticals and abnormal choices spelt out.
  pw.Widget flagCell(Map<String, Object?> v) {
    final flag = v['flag'] as String? ?? '';
    final text = switch (flag) {
      LabFlag.low || LabFlag.high => flag,
      LabFlag.criticalLow || LabFlag.criticalHigh => '$flag Critical',
      LabFlag.abnormal => 'Abnormal',
      _ => '',
    };
    return pw.Text(text,
        style: pw.TextStyle(
            fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: LabFlag.isCritical(flag) ? PrintKit.danger : null));
  }

  pw.Widget signer(String label, String name, String role, DateTime? at) => pw.SizedBox(
        width: 200,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(label, style: PrintKit.muted),
          PrintKit.signature(role, name: name),
          if (at != null) pw.Text(formatDateTime(at), style: PrintKit.muted),
        ]),
      );

  return PrintDoc(
    letterhead: letterhead,
    title: 'Lab report ${item.testName} ${item.patientName}',
    label: 'LABORATORY REPORT',
    meta: [
      if (sampleId.isNotEmpty) 'Sample $sampleId',
      departmentLabel(item.test?.str('department')),
    ],
    banner: verified
        ? null
        : result == null
            ? 'NO RESULTS YET — results appear here once they are entered'
            : 'PROVISIONAL REPORT — not yet verified. Do not act on these values until a pathologist has verified them.',
    footer: [item.patientName, item.uhid, item.testName].where((s) => s.isNotEmpty).join(' · '),
    body: [
      if (amended && result?.strOrNull('amend_reason') != null)
        PrintKit.paragraph('Amended report · ${result!.str('amend_reason')}',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PrintKit.danger)),
      PrintKit.fields(columns: 4, [
        ('Patient', item.patientName),
        ('UHID', item.uhid),
        ('Age / sex', [ageLabel(patient?.date('dob'), patient?.intOrNull('age_years')), genderLabel(patient?.strOrNull('gender'))].join(' / ')),
        ('Referred by', item.doctorName.isEmpty ? 'Self' : item.doctorName),
        ('Sample ID', sampleId),
        ('Sample', item.test?.str('sample_type') ?? ''),
        ('Collected', formatDateTime(order.date('collected_at'))),
        ('Reported', formatDateTime(result?.date('verified_at') ?? result?.date('entered_at'))),
      ]),
      PrintKit.section(item.testName),
      if (values.isEmpty)
        PrintKit.paragraph('No results entered.', style: PrintKit.muted)
      else
        PrintKit.table(
          headers: ['Investigation', 'Result', 'Flag', 'Unit', 'Biological reference interval'],
          widths: const {0: pw.FlexColumnWidth(3.4), 1: pw.FlexColumnWidth(1.6), 2: pw.FlexColumnWidth(1.6), 3: pw.FlexColumnWidth(1.6), 4: pw.FlexColumnWidth(3.6)},
          rows: [
            for (final v in values) ['${v['name']}', valueCell(v), flagCell(v), '${v['unit'] ?? ''}', '${v['ref'] ?? ''}'],
          ],
        ),
      if (result != null && result.str('comments').isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10),
          child: pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(text: 'Comments: ', style: PrintKit.strong),
              pw.TextSpan(text: result.str('comments')),
            ]),
          ),
        ),
      pw.SizedBox(height: 18),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (result != null) signer('Entered by', result.str('entered_by_name'), 'Laboratory technologist', result.date('entered_at')),
        if (verified)
          signer('Verified by', result!.str('verified_by_name'), 'Pathologist', result.date('verified_at'))
        else
          pw.SizedBox(
            width: 200,
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Verified by', style: PrintKit.muted),
              pw.SizedBox(height: 30),
              pw.Text('Pending verification', style: PrintKit.strong),
              pw.Text('Pathologist', style: PrintKit.muted),
            ]),
          ),
      ]),
      pw.SizedBox(height: 16),
      pw.Divider(color: PrintKit.rule, thickness: 0.6, height: 8),
      pw.Text(
        'H / L: above / below the reference interval.  HH / LL: critical value, reported to the doctor at once.  '
        'Results relate only to the sample tested and must be read with the clinical findings.',
        style: PrintKit.small,
      ),
      pw.SizedBox(height: 6),
      pw.Center(child: pw.Text('— End of report —', style: PrintKit.muted)),
    ],
  ).build();
}

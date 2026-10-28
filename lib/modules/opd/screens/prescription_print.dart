import 'dart:typed_data';

import 'package:kendra_hms/core/core.dart';
import 'package:pdf/widgets.dart' as pw;

import '../clinical.dart';
import '../opd_service.dart';
import 'consultation_note_screen.dart';
import 'opd_widgets.dart';

/// The print job's name, also the file name when saving as PDF.
String prescriptionName(NoteData d) =>
    'Prescription ${d.patient?.str('full_name') ?? ''} ${formatDate(d.consultation.date('started_at') ?? d.consultation.createdAt)}'
        .replaceAll(RegExp(r'\s+'), ' ');

/// Loads consultation [consultationId] and prints its prescription.
Future<Uint8List> prescriptionPdfFor(ReadDb db, Letterhead letterhead, String consultationId) async {
  final d = await NoteData.load(db, consultationId);
  if (d == null) throw ValidationException('Consultation not found');
  return prescriptionPdf(d, letterhead);
}

/// The printed OPD prescription the patient takes home: the same content as
/// the consultation note screen, on A4, with the doctor's signature line.
Future<Uint8List> prescriptionPdf(NoteData d, Letterhead letterhead) {
  final c = d.consultation;
  final p = d.patient;
  final when = c.date('started_at') ?? c.createdAt;
  final token = d.encounter?.intOrNull('token_no');
  final doctorName = doctorLabel(c.str('signed_by_name', d.doctor?.str('display_name') ?? ''));
  final department = d.doctor?.str('department') ?? d.encounter?.str('department') ?? '';
  final specialization = d.doctor?.str('specialization') ?? '';
  final registration = d.doctor?.str('registration_no') ?? '';
  final allergies = p?.str('allergies') ?? '';
  final vitals = c.map('vitals');
  final items = d.items;
  final orders = d.orderRows;
  final followUp = c.date('follow_up_date');
  final signerRole = [if (specialization.isNotEmpty) specialization, if (registration.isNotEmpty) 'Reg. no. $registration'].join(' · ');

  // Clinical notes as label / text rows, so a usual visit fits on one page.
  pw.Widget row(String label, pw.Widget value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 5),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 88, child: pw.Text(label, style: PrintKit.muted)),
          pw.Expanded(child: value),
        ]),
      );
  List<pw.Widget> textRow(String label, String body) => body.trim().isEmpty ? const [] : [row(label, pw.Text(body.trim()))];
  final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);

  return PrintDoc(
    letterhead: letterhead,
    title: prescriptionName(d),
    label: 'PRESCRIPTION',
    meta: [if (token != null) 'OPD · Token $token' else 'OPD', formatDateTime(when)],
    banner: d.signed ? null : 'UNSIGNED — not valid until the doctor signs',
    footer: [
      d.signed ? 'Signed electronically by $doctorName on ${formatDateTime(c.date('signed_at'))}.' : 'Draft — not signed.',
      if (c.date('amended_at') != null) 'Amended ${formatDateTime(c.date('amended_at'))}.',
    ].join(' '),
    body: [
      PrintKit.fields([
        ('Patient', p?.str('full_name') ?? ''),
        ('UHID', p?.str('uhid') ?? ''),
        ('Age / sex', p == null ? '' : patientLine(p, withUhid: false)),
        if (p != null && p.str('phone').isNotEmpty) ('Mobile', p.str('phone')),
        ('Doctor', doctorName),
        ('Department', department),
      ]),
      pw.SizedBox(height: 8),
      Allergy.isNone(allergies)
          ? pw.Text('No known allergies', style: PrintKit.muted)
          : pw.Text('Allergies: ${allergies.trim()}', style: pw.TextStyle(color: PrintKit.danger, fontWeight: pw.FontWeight.bold)),
      pw.Divider(color: PrintKit.rule, thickness: 0.6, height: 18),
      if (vitals.isNotEmpty) row('Vitals', pw.Text(Vitals.summary(vitals, long: true))),
      ...textRow('Complaint', c.str('chief_complaint')),
      ...textRow('History', c.str('history')),
      ...textRow('Examination', c.str('examination')),
      if (c.str('diagnosis').isNotEmpty)
        row(
          'Diagnosis',
          pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(text: c.str('diagnosis'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
              if (c.str('icd_code').isNotEmpty) pw.TextSpan(text: '   ICD-10 ${c.str('icd_code')}', style: PrintKit.muted),
            ]),
          ),
        ),
      if (items.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('Rx',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, fontStyle: pw.FontStyle.italic, color: PrintKit.accent)),
        pw.SizedBox(height: 2),
        PrintKit.table(
          headers: ['#', 'Medicine', 'Dose', 'Frequency', 'Days', 'Qty', 'Instructions'],
          widths: const {
            0: pw.FixedColumnWidth(20),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.4),
            3: pw.FixedColumnWidth(62),
            4: pw.FixedColumnWidth(34),
            5: pw.FixedColumnWidth(30),
            6: pw.FlexColumnWidth(2.2),
          },
          right: const {4, 5},
          rows: [
            for (final (i, m) in items.indexed)
              [
                '${i + 1}',
                PrintKit.twoLine(m['drug_name'] as String? ?? '', m['generic_name'] as String? ?? ''),
                m['dose'] as String? ?? '',
                m['frequency'] as String? ?? '',
                m['duration_days'] is num ? '${(m['duration_days'] as num).toInt()}' : '',
                m['quantity'] is num ? '${(m['quantity'] as num).toInt()}' : '',
                [m['instructions'], m['route']].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              ],
          ],
        ),
        pw.SizedBox(height: 10),
      ],
      if (orders.isNotEmpty)
        row(
          'Investigations',
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            for (final o in orders)
              pw.RichText(
                text: pw.TextSpan(children: [
                  pw.TextSpan(text: o['name'] as String? ?? ''),
                  if (o['priority'] == 'urgent' || o['priority'] == 'stat')
                    pw.TextSpan(
                        text: o['priority'] == 'stat' ? '  STAT' : '  URGENT',
                        style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PrintKit.danger)),
                  if ((o['result'] as String? ?? '').isNotEmpty) pw.TextSpan(text: ' — ${o['result']}', style: PrintKit.muted),
                ]),
              ),
          ]),
        ),
      ...textRow('Advice', c.str('advice')),
      if (followUp != null) row('Follow-up', pw.Text('${formatWeekday(followUp)}, ${formatDate(followUp)}', style: bold)),
      ...textRow('Other notes', c.str('notes')),
      pw.SizedBox(height: 12),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: PrintKit.signature(signerRole.isEmpty ? 'Consultant' : signerRole, name: doctorName),
      ),
    ],
  ).build();
}

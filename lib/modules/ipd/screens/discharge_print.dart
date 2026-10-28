import 'dart:typed_data';

import 'package:kendra_hms/core/core.dart';
import 'package:pdf/widgets.dart' as pw;

import '../bed_days.dart';
import '../ipd_schema.dart';
import 'admission_screen.dart';

/// Everything the printed discharge summary needs about one stay.
class DischargeData {
  DischargeData({
    required this.view,
    required this.admittingDoctor,
    required this.transfers,
    required this.beds,
    required this.wards,
    required this.lastVitals,
  });

  final AdmissionView view;
  final Rec? admittingDoctor;
  final List<Rec> transfers;
  final Map<String, Rec> beds;
  final Map<String, Rec> wards;

  /// The newest note with vitals in it.
  final Rec? lastVitals;

  static Future<DischargeData?> load(ReadDb db, String admissionId) async {
    final view = await AdmissionView.load(db, admissionId);
    if (view == null) return null;
    final a = view.admission;
    final transfers = await db.query(Query(IpdCol.transfers).eq('admission_id', a.id).sort('at').take(200));
    final notes = await db.query(Query(IpdCol.notes).eq('admission_id', a.id).eq('kind', 'vitals').sort('recorded_at', desc: true).take(20));
    return DischargeData(
      view: view,
      admittingDoctor: await db.get(Col.users, a.strOrNull('admitting_doctor_id')),
      transfers: transfers,
      beds: await db.byIds(IpdCol.beds, [for (final t in transfers) ...[t.strOrNull('from_bed_id'), t.strOrNull('to_bed_id')]]),
      wards: await db.byIds(IpdCol.wards, [for (final t in transfers) ...[t.strOrNull('from_ward_id'), t.strOrNull('to_ward_id')]]),
      lastVitals: notes.where((n) => n.map('vitals').isNotEmpty).firstOrNull,
    );
  }
}

/// The printed discharge summary, signed by the treating consultant and
/// handed to the patient before they leave.
Future<Uint8List> dischargePdf(DischargeData data, Letterhead letterhead, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final v = data.view;
  final a = v.admission;
  final p = v.patient;
  final doctor = v.doctor;
  final admittedBy = data.admittingDoctor;
  final admitted = a.date('admitted_at') ?? a.createdAt;
  final out = a.date('discharged_at');
  final advised = a.date('discharge_requested_at');
  final signedOff = v.status != IpdVals.admitted;
  final type = a.str('discharge_type', 'normal');
  final allergies = p?.str('allergies') ?? '';
  final vitals = data.lastVitals == null ? const <String>[] : vitalBits(data.lastVitals!.map('vitals'));

  String place(String? bedId, String? wardId) =>
      [data.beds[bedId]?.str('label') ?? 'Bed', if (data.wards[wardId] != null) data.wards[wardId]!.str('name')].join(' · ');
  String doctorLine(Rec u) => [u.str('specialization'), u.str('department')].where((s) => s.isNotEmpty).toSet().join(' · ');

  List<pw.Widget> text(String title, String body) => [
        if (body.trim().isNotEmpty) ...[PrintKit.section(title), PrintKit.paragraph(body.trim())],
      ];

  return PrintDoc(
    letterhead: letterhead,
    title: 'Discharge summary ${a.str('number')} ${v.patientName}',
    label: 'DISCHARGE SUMMARY',
    meta: [a.str('number'), formatDate(out ?? advised ?? at)],
    banner: signedOff ? null : 'PROVISIONAL — the doctor has not signed off this discharge yet',
    footer: 'Printed ${formatDateTime(at)}. Bring this summary to every follow-up visit. '
        'If symptoms get worse, come back to the hospital at once.',
    body: [
      PrintKit.fields([
        ('Patient', v.patientName),
        ('UHID', p?.str('uhid') ?? ''),
        ('Age / sex', p == null ? '' : '${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${genderLabel(p.strOrNull('gender'))}'),
        if (p != null && p.str('phone').isNotEmpty) ('Mobile', p.str('phone')),
        if (p != null && p.str('blood_group').isNotEmpty) ('Blood group', p.str('blood_group')),
        if (p != null && p.str('address').isNotEmpty) ('Address', [p.str('address'), p.str('city')].where((s) => s.isNotEmpty).join(', ')),
      ]),
      if (allergies.isNotEmpty)
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 8),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PrintKit.danger, width: 0.8)),
          child: pw.Text('Allergies: $allergies', style: pw.TextStyle(color: PrintKit.danger, fontWeight: pw.FontWeight.bold)),
        ),
      PrintKit.section('Admission'),
      PrintKit.fields([
        ('Consultant', doctor?.str('display_name') ?? ''),
        if (admittedBy != null && admittedBy.id != doctor?.id) ('Admitted by', admittedBy.str('display_name')),
        ('Ward / bed', [v.bedLabel, if (v.wardName.isNotEmpty) v.wardName].join(' · ')),
        ('Admitted', formatDateTime(admitted)),
        if (out != null)
          ('Discharged', formatDateTime(out))
        else if (signedOff && advised != null)
          ('Discharge advised', formatDateTime(advised)),
        ('Length of stay', plural(BedDays.count(admittedAt: admitted, dischargedAt: out, now: at), 'day')),
        if (signedOff) ('Type of discharge', dischargeTypeLabel(type)),
      ]),
      if (a.str('diagnosis').isNotEmpty) ...[
        PrintKit.section('Diagnosis'),
        pw.Text(a.str('diagnosis'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
      ],
      ...text('Reason for admission', a.str('reason')),
      ...text('Course in hospital', a.str('discharge_summary')),
      if (vitals.isNotEmpty) ...[
        PrintKit.section('Last recorded vitals'),
        pw.Text('${vitals.join('   ·   ')}   (${formatDateTime(data.lastVitals!.date('recorded_at') ?? data.lastVitals!.createdAt)})'),
      ],
      if (data.transfers.isNotEmpty) ...[
        PrintKit.section('Bed moves'),
        PrintKit.table(
          headers: ['When', 'From', 'To', 'Reason'],
          widths: const {0: pw.FixedColumnWidth(122)},
          rows: [
            for (final t in data.transfers)
              [
                formatDateTime(t.date('at')),
                place(t.strOrNull('from_bed_id'), t.strOrNull('from_ward_id')),
                place(t.strOrNull('to_bed_id'), t.strOrNull('to_ward_id')),
                t.str('reason'),
              ],
          ],
        ),
      ],
      ...text('Advice on discharge', a.str('discharge_advice')),
      if (type == 'lama')
        PrintKit.paragraph('The patient is leaving against medical advice. The risks of leaving were explained to the patient '
            'and relatives, who chose to leave.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 16),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
        PrintKit.signature(
          [
            if (doctor != null && doctorLine(doctor).isNotEmpty) doctorLine(doctor) else 'Treating consultant',
            if ((doctor?.str('registration_no') ?? '').isNotEmpty) 'Reg. no. ${doctor!.str('registration_no')}',
          ].join(' · '),
          name: doctor?.str('display_name') ?? '',
        ),
        PrintKit.signature('Summary received, advice explained', name: 'Patient / relative'),
      ]),
    ],
  ).build();
}

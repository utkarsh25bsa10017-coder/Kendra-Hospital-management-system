import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../contracts/collections.dart';
import '../services/settings_service.dart';
import '../ui/format.dart';

/// Printed documents: bills, lab reports, prescriptions, discharge summaries.
///
/// A module builds the body with `package:pdf/widgets.dart` (imported `as pw`)
/// and the helpers in [PrintKit], and [PrintDoc] adds the letterhead, page
/// numbers and footer, so every printout looks like it came from one hospital:
///
/// ```dart
/// final bytes = await PrintDoc(
///   letterhead: Letterhead.of(context.app.settings),
///   label: 'BILL / RECEIPT',
///   meta: [inv.str('number'), formatDateTime(when)],
///   body: [PrintKit.fields([('Patient', name), ('UHID', uhid)])],
/// ).build();
/// ```
///
/// Show it with `PrintButton` (lib/core/print/print_button.dart).
class PrintDoc {
  const PrintDoc({
    required this.letterhead,
    required this.label,
    required this.body,
    this.meta = const [],
    this.banner,
    this.footer,
    this.title,
  });

  final Letterhead letterhead;

  /// Spaced capitals at the top right: "BILL / RECEIPT", "PRESCRIPTION".
  final String label;

  /// Lines under the label: the document number, the date.
  final List<String> meta;

  /// A boxed red warning under the header: "DRAFT — not valid as a bill".
  final String? banner;

  final List<pw.Widget> body;

  /// Small print on every page, left of the page number.
  final String? footer;

  /// The PDF's title (shown by viewers and as the file name when saving).
  final String? title;

  Future<Uint8List> build() async {
    final doc = pw.Document(title: title ?? label, creator: 'Kendra HMS', theme: await PrintFonts.theme());
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 28),
      header: (ctx) => ctx.pageNumber == 1 ? _header() : _runningHeader(),
      footer: _footer,
      build: (_) => [
        if (banner != null)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 12),
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PrintKit.danger, width: 1.2)),
            alignment: pw.Alignment.center,
            child: pw.Text(banner!,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(color: PrintKit.danger, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6)),
          ),
        ...body,
      ],
    ));
    return doc.save();
  }

  pw.Widget _header() => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 14),
        padding: const pw.EdgeInsets.only(bottom: 10),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PrintKit.rule, width: 1))),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(letterhead.name, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              for (final line in letterhead.lines) pw.Text(line, style: PrintKit.muted),
            ]),
          ),
          pw.SizedBox(width: 16),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(label,
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, letterSpacing: 1.4, color: PrintKit.accent)),
            for (final (i, m) in meta.indexed)
              pw.Text(m, style: i == 0 ? const pw.TextStyle(fontSize: 11) : PrintKit.muted),
          ]),
        ]),
      );

  pw.Widget _runningHeader() => pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.only(bottom: 4),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PrintKit.rule, width: 0.5))),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text(letterhead.name, style: PrintKit.muted)),
          pw.Text([label, if (meta.isNotEmpty) meta.first].join(' · '), style: PrintKit.muted),
        ]),
      );

  pw.Widget _footer(pw.Context ctx) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 10),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Expanded(child: pw.Text(footer ?? '', style: PrintKit.small)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: PrintKit.small),
        ]),
      );
}

/// The hospital's name and contact lines from Administration → Settings.
class Letterhead {
  const Letterhead({required this.name, this.address = '', this.phone = '', this.gstin = ''});

  factory Letterhead.of(SettingsService settings) => Letterhead(
        name: settings.hospitalName,
        address: settings.str(SettingKeys.hospitalAddress),
        phone: settings.str(SettingKeys.hospitalPhone),
        gstin: settings.str(SettingKeys.hospitalGstin),
      );

  final String name;
  final String address;
  final String phone;
  final String gstin;

  List<String> get lines => [
        if (address.isNotEmpty) address,
        if (phone.isNotEmpty) 'Phone $phone',
        if (gstin.isNotEmpty) 'GSTIN $gstin',
      ];
}

/// Noto Sans, bundled in assets/fonts: it has the rupee sign and accented
/// letters, which the PDF standard fonts lack.
abstract final class PrintFonts {
  static pw.ThemeData? _theme;

  static Future<pw.ThemeData> theme() async {
    if (_theme != null) return _theme!;
    Future<pw.Font> load(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-$name.ttf'));
    final base = await load('Regular');
    final bold = await load('Bold');
    final italic = await load('Italic');
    return _theme = pw.ThemeData.withFont(base: base, bold: bold, italic: italic, boldItalic: bold).copyWith(
          defaultTextStyle: pw.TextStyle(font: base, fontBold: bold, fontItalic: italic, fontBoldItalic: bold, fontSize: 10),
        );
  }
}

/// Building blocks for document bodies, styled to match each other.
abstract final class PrintKit {
  static const ink = PdfColor.fromInt(0xff1f2328);
  static const grey = PdfColor.fromInt(0xff5f6670);
  static const rule = PdfColor.fromInt(0xffc9ced6);
  static const shade = PdfColor.fromInt(0xfff1f3f5);
  static const accent = PdfColor.fromInt(0xff1d5fa8);
  static const danger = PdfColor.fromInt(0xffb3261e);

  static const muted = pw.TextStyle(fontSize: 9, color: grey);
  static const small = pw.TextStyle(fontSize: 7.5, color: grey);
  static final strong = pw.TextStyle(fontWeight: pw.FontWeight.bold);

  /// Label-over-value pairs in a grid (patient details and the like).
  /// Pairs with an empty value print a dash.
  static pw.Widget fields(List<(String, String)> items, {int columns = 3}) => pw.LayoutBuilder(
        builder: (context, box) {
          final width = (box!.maxWidth - (columns - 1) * 12) / columns;
          return pw.Wrap(spacing: 12, runSpacing: 8, children: [
            for (final (label, value) in items)
              pw.SizedBox(
                width: width,
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  pw.Text(label, style: muted),
                  pw.Text(value.isEmpty ? '—' : value, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ]),
              ),
          ]);
        },
      );

  /// A heading with a rule under it.
  static pw.Widget section(String title) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        padding: const pw.EdgeInsets.only(bottom: 2),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: rule, width: 0.6))),
        child: pw.Text(title.toUpperCase(),
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: grey)),
      );

  /// A ruled table. Cells are strings or `pw.Widget`s (e.g. [twoLine]).
  /// Columns in [right] are right-aligned (amounts, quantities).
  static pw.Widget table({
    required List<String> headers,
    required List<List<Object>> rows,
    Map<int, pw.TableColumnWidth> widths = const {},
    Set<int> right = const {},
  }) =>
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: rule, width: 0.5), bottom: pw.BorderSide(color: rule, width: 0.5)),
        headerDecoration: const pw.BoxDecoration(color: shade),
        headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: grey),
        cellStyle: const pw.TextStyle(fontSize: 9.5),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        headerPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        columnWidths: widths,
        defaultColumnWidth: const pw.FlexColumnWidth(),
        headerAlignment: pw.Alignment.centerLeft,
        cellAlignment: pw.Alignment.topLeft,
        headerAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        cellAlignments: {for (final i in right) i: pw.Alignment.topRight},
      );

  /// A main line with a grey line under it, for table cells.
  static pw.Widget twoLine(String main, String sub) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(main, style: const pw.TextStyle(fontSize: 9.5)),
        if (sub.isNotEmpty) pw.Text(sub, style: small),
      ]);

  /// Label / amount rows, right-aligned under a table (Total, Discount…).
  /// A null amount draws a rule.
  static pw.Widget totals(List<(String, int?, {bool strong})> rows, {double width = 240}) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.SizedBox(
          width: width,
          child: pw.Column(children: [
            for (final (label, paise, strong: s) in rows)
              paise == null
                  ? pw.Divider(color: rule, thickness: 0.6, height: 8)
                  : pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
                      child: pw.Row(children: [
                        pw.Expanded(child: pw.Text(label, style: s ? strong : null)),
                        pw.Text(formatMoney(paise), style: s ? pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11) : null),
                      ]),
                    ),
          ]),
        ),
      );

  /// Plain paragraph text, with a blank line between paragraphs.
  static pw.Widget paragraph(String text, {pw.TextStyle? style}) =>
      pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4), child: pw.Text(text, style: style));

  /// A signature line with the signer's name and role under it.
  static pw.Widget signature(String role, {String name = ''}) => pw.SizedBox(
        width: 180,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(height: 30),
          pw.Divider(color: ink, thickness: 0.6, height: 4),
          if (name.isNotEmpty) pw.Text(name, style: strong),
          pw.Text(role, style: muted),
        ]),
      );
}

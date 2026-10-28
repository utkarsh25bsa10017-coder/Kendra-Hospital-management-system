import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../services/app_services.dart';
import '../ui/tokens.dart';

/// Opens the system print dialog for the PDF that [build] makes. Every
/// platform offers "Save as PDF" there too.
Future<void> printDocument(BuildContext context, {required String name, required Future<Uint8List> Function() build}) async {
  final nav = context.app.nav;
  try {
    final bytes = await build();
    await Printing.layoutPdf(name: name, format: PdfPageFormat.a4, onLayout: (_) async => bytes);
  } catch (e, st) {
    debugPrint('printing "$name" failed: $e\n$st');
    nav.toast('Could not open the print dialog. Check that a printer is set up on this device.', error: true);
  }
}

/// "Print" for a page's actions: an icon on phones, a labelled button on
/// larger screens. [build] makes the PDF when it is pressed, so it always
/// prints the current data.
class PrintButton extends StatefulWidget {
  const PrintButton({super.key, required this.name, required this.build, this.label = 'Print'});

  /// The print job's name, also the file name when saving as PDF.
  final String name;
  final Future<Uint8List> Function() build;
  final String label;

  @override
  State<PrintButton> createState() => _PrintButtonState();
}

class _PrintButtonState extends State<PrintButton> {
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    await printDocument(context, name: widget.name, build: widget.build);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = _busy ? null : _print;
    if (context.isCompact) {
      return IconButton(tooltip: widget.label, icon: const Icon(Icons.print_outlined), onPressed: onPressed);
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.print_outlined, size: 20),
      label: Text(widget.label),
    );
  }
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads real fonts so screenshots show text instead of boxes.
Future<void> loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/development/flutter';
  final dir = '$sdk/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Light.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// Wrap the app in `RepaintBoundary(key: shotKey, ...)` to capture it.
final shotKey = GlobalKey();

/// Saves what is on screen to `build/screens/NAME.png`.
Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = File('build/screens/$name.png')..createSync(recursive: true);
    f.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
}

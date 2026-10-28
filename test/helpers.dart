import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:kendra_hms/core/auth/auth_service.dart';
import 'package:kendra_hms/core/auth/password.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/services/device_config.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';

/// A fresh hospital in a temp folder, with an owner account (owner / Passw0rd!).
Future<AppServices> bootTestHospital(List<HmsModule> modules, {bool demo = false, String? dir}) async {
  defaultPasswordIterations = 1000;
  final tmp = dir ?? Directory.systemTemp.createTempSync('kendra_test_').path;
  final config = await DeviceConfig.load(dataDir: tmp);
  if (demo) {
    return SetupService.createDemo(config: config, modules: modules);
  }
  return SetupService.createHospital(
    config: config,
    modules: modules,
    details: const HospitalDetails(name: 'Test Hospital', uhidPrefix: 'TH'),
    owner: const OwnerAccount(displayName: 'Test Owner', username: 'owner', password: 'Passw0rd!'),
    enabledModules: {for (final m in modules) m.id},
  );
}

/// Creates a staff account and returns it.
Future<Rec> addUser(AppServices app, String username, List<String> roles, {Map<String, Object?> extra = const {}}) =>
    (app.auth.backend as LocalAuthBackend).createUser(
      null,
      {'username': username, 'display_name': titleCase(username), 'role_ids': roles, 'must_change_password': false, ...extra},
      'Passw0rd!',
    );

Future<void> signIn(AppServices app, String username) async {
  if (app.auth.signedIn) await app.auth.logout();
  await app.auth.login(username, 'Passw0rd!');
}

/// Signs in as one of the demo hospital's staff (password demo1234).
Future<void> signInDemo(AppServices app, String username) async {
  if (app.auth.signedIn) await app.auth.logout();
  await app.auth.login(username, demoPassword);
}

/// Pages in a PDF made by `PrintDoc`.
int pdfPages(Uint8List pdf) => RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;

/// Checks that [pdf] is a PDF and saves it to `build/print/NAME.pdf` so the
/// printouts can be looked at.
void expectPdf(Uint8List pdf, String name, {int? pages}) {
  expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
  if (pages != null) expect(pdfPages(pdf), pages, reason: name);
  File('build/print/$name.pdf')
    ..createSync(recursive: true)
    ..writeAsBytesSync(pdf);
}

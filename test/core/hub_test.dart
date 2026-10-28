import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/auth/auth_service.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/data/remote/remote_store.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../helpers.dart';

void main() {
  test('a client device reads and writes through the hub', () async {
    final modules = [PatientsModule()];
    final hub = await bootTestHospital(modules);
    await addUser(hub, 'reception1', [Roles.receptionist]);
    final port = 20000 + DateTime.now().millisecond * 10 % 9000;
    hub.config.hubPort = port;
    await hub.startHub();
    final url = 'http://127.0.0.1:$port';
    final key = hub.config.networkKey!;

    expect(await probeHub(url, key), 'Test Hospital');
    await expectLater(probeHub(url, 'WRONG-KEY'), throwsA(isA<HubUnavailableException>()));

    final remote = RemoteRecordStore(
      baseUrl: url,
      networkKey: key,
      schemas: hub.schemas,
      deviceId: 'tablet-1',
      deviceName: 'Ward tablet',
    );
    final auth = AuthService(RemoteAuthBackend(remote));
    await expectLater(auth.login('reception1', 'nope'), throwsA(isA<AuthException>()));
    await auth.login('reception1', 'Passw0rd!');
    expect(auth.can('patients.edit'), isTrue);

    // Changes made on the hub reach the client.
    final changed = Completer<StoreChange>();
    final sub = remote.changes.where((c) => c.collection == Col.patients).listen((c) {
      if (!changed.isCompleted) changed.complete(c);
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final clientDb = Db(remote, () => auth.actor);
    final p = await clientDb.insert(Col.patients, {'uhid': 'TH-1', 'first_name': 'Asha', 'full_name': 'Asha', 'dob': DateTime(1990, 5, 1)});
    expect(p.date('dob'), DateTime(1990, 5, 1));
    expect((await changed.future.timeout(const Duration(seconds: 5))).id, p.id);

    // The hub attributes the write to the person signed in on the tablet.
    final onHub = await hub.store.get(Col.patients, p.id);
    expect(onHub!.str('created_by'), auth.session!.userId);
    final log = await hub.store.auditLog(AuditFilter(recordId: p.id));
    expect(log.single.deviceId, 'tablet-1');

    // Client permissions are checked on the hub.
    await expectLater(
      clientDb.insert(Col.users, {'username': 'hacker', 'display_name': 'x'}),
      throwsA(isA<PermissionDeniedException>()),
    );
    // Password hashes never leave the hub.
    final users = await remote.query(const Query(Col.users));
    expect(users.every((u) => !u.data.containsKey('password_hash')), isTrue);

    await sub.cancel();
    await remote.close();
    await hub.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('client reports offline when the hub is gone', () async {
    final remote = RemoteRecordStore(
      baseUrl: 'http://127.0.0.1:1',
      networkKey: 'X',
      schemas: SchemaRegistry(),
      deviceId: 'd',
      deviceName: 'd',
    );
    await expectLater(remote.call('count'), throwsA(isA<HubUnavailableException>()));
    expect(remote.link.value, HubLink.offline);
    await remote.close();
  }, skip: Platform.isWindows);
}

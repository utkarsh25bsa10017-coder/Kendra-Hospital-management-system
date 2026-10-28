// Renders the pharmacy screens to build/screens/pharmacy_<size>_<screen>.png
// so they can be reviewed without a display.
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_module.dart';
import 'package:kendra_hms/modules/pharmacy/pharmacy_schema.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

Future<Map<String, Object?>> _waitingRx(AppServices app) async {
  final rx = await app.store.query(const Query(Col.prescriptions).eq('status', Vals.active).sort('created_at').take(50));
  final withAllergyCheck = rx.where((r) => r.maps('items').any((i) => '${i['drug_name']}'.startsWith('Augmentin')));
  return {'prescriptionId': (withAllergyCheck.isNotEmpty ? withAllergyCheck.first : rx.first).id};
}

Future<Map<String, Object?>> _product(AppServices app) async =>
    {'id': (await app.store.query(const Query(PCol.products).eq('name', 'Brufen 400').take(1))).first.id};

Future<Map<String, Object?>> _openOrder(AppServices app) async =>
    {'id': (await app.store.query(const Query(PCol.orders).eq('status', PoStatus.ordered).take(1))).first.id};

Future<Map<String, Object?>> _receiveOrder(AppServices app) async => {'orderId': (await _openOrder(app))['id']};

Future<Map<String, Object?>> _dispense(AppServices app) async => {
      'id': (await app.store.query(
              const Query(PCol.dispenses).eq('kind', DispenseKind.prescription).sort('dispensed_at', desc: true).take(1)))
          .first
          .id
    };

Future<Map<String, Object?>> _patient(AppServices app) async {
  final d = await app.store.query(const Query(PCol.dispenses).sort('dispensed_at', desc: true).take(1));
  return {'patientId': d.first.str('patient_id')};
}

final specs = [
  const ShotSpec('queue', 'pharmacy.dispense'),
  ShotSpec('dispense_rx', 'pharmacy.dispense_rx', args: _waitingRx),
  ShotSpec('summary', 'pharmacy.dispense_summary', args: _dispense),
  ShotSpec('sale', 'pharmacy.sale', args: _patient),
  const ShotSpec('stock', 'pharmacy.stock'),
  ShotSpec('product', 'pharmacy.product', args: _product),
  const ShotSpec('orders', 'pharmacy.orders'),
  ShotSpec('order', 'pharmacy.order', args: _openOrder),
  ShotSpec('receive', 'pharmacy.receive', args: _receiveOrder),
  const ShotSpec('catalog', 'pharmacy.catalog'),
];

void main() {
  setUpAll(loadFonts);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('pharmacy $name', (t) => captureScreens(t,
        prefix: 'pharmacy_$name',
        size: size,
        modules: [PatientsModule(), PharmacyModule()],
        specs: specs,
        username: 'pharmacy'));
  }
}

// Renders the OPD screens to build/screens/opd_<size>_*.png for review.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/opd/clinical.dart';
import 'package:kendra_hms/modules/opd/opd_module.dart';
import 'package:kendra_hms/modules/opd/opd_schema.dart';
import 'package:kendra_hms/modules/opd/opd_service.dart';
import 'package:kendra_hms/modules/opd/screens/consult_screen.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../../screens/capture.dart';
import '../../screens/shots.dart';

String? _draftEncounterId;

/// Dr. Khan calls her next patient and has written most of the note.
Future<Map<String, Object?>> _filledDraft(AppServices app) async {
  if (_draftEncounterId != null) return {'encounterId': _draftEncounterId};
  final me = app.auth.session!.user;
  final enc = (await OpdService.nextWaiting(app.readDb, me.id))!;
  final note = await OpdService.start(app.db, enc, doctor: me);
  Map<String, Object?> med(String name, String generic, String form, String dose, String freq, int days, String instr) => {
        'medicine_id': null,
        'drug_name': name,
        'generic_name': generic,
        'form': form,
        'dose': dose,
        'frequency': freq,
        'duration_days': days,
        'route': Rx.defaultRoute(form, name),
        'instructions': instr,
        'quantity': Rx.quantity(frequency: freq, days: days, form: form, dose: dose, name: name),
      };
  await OpdService.saveDraft(app.db, note.id, {
    'chief_complaint': 'Cough and cold since 3 days, low-grade fever at night',
    'history': 'Eating and playing normally. Immunisation up to date. Elder sibling has a cold.',
    'examination': 'Active, playful. Throat congested. Chest clear, no wheeze. Ears normal.',
    'diagnosis': 'Acute upper respiratory tract infection',
    'icd_code': 'J06.9',
    'rx_draft': [
      med('Calpol 250 Syrup', 'Paracetamol', 'syrup', '5 ml', 'SOS', 3, 'If temperature above 100 °F'),
      med('Cetzine Syrup', 'Cetirizine', 'syrup', '2.5 ml', '0-0-1', 5, 'At bedtime'),
      med('Nasoclear Nasal Drops', 'Sodium chloride (saline)', 'drops', '2 drops', '1-1-1', 5, 'Before feeds'),
    ],
    'orders_draft': [
      {'service_code': null, 'name': 'Complete blood count (CBC)', 'order_type': 'lab', 'priority': 'routine'},
    ],
    'advice': 'Warm fluids. Saline drops before feeds. Come back at once if breathing fast or not feeding.',
    'follow_up_date': startOfDay(DateTime.now()).add(const Duration(days: 3)),
  });
  _draftEncounterId = enc.id;
  return {'encounterId': enc.id};
}

/// Dr. Khan's most recent signed note (the demo amends one of hers).
Future<Map<String, Object?>> _signedNote(AppServices app) async {
  final me = app.auth.session!.user;
  final amended = await app.readDb.first(Query(OpdCol.consultations).eq('doctor_id', me.id).isNotNull('amended_at'));
  final c = amended ??
      (await app.readDb.first(
          Query(OpdCol.consultations).eq('doctor_id', me.id).eq('status', ConsultStatus.signed).sort('signed_at', desc: true)))!;
  return {'id': c.id};
}

/// The patient with the most notes, so the clinical record has a history.
Future<Map<String, Object?>> _patientWithHistory(AppServices app) async {
  final rows = await app.readDb.query(const Query(OpdCol.consultations).take(2000));
  final counts = <String, int>{};
  for (final r in rows) {
    counts[r.str('patient_id')] = (counts[r.str('patient_id')] ?? 0) + 1;
  }
  final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return {'id': best.key};
}

Future<void> _tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).first);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

List<ShotSpec> _specs(Size size) {
  final twoPane = size.width >= ConsultScreen.twoPaneWidth;
  return [
    const ShotSpec('queue', 'opd.queue'),
    ShotSpec('consult', 'opd.consult', args: _filledDraft),
    if (!twoPane)
      ShotSpec('consult_summary', 'opd.consult', args: _filledDraft, after: (t, app) => _tapText(t, 'Patient summary')),
    ShotSpec('consult_rx', 'opd.consult', args: _filledDraft, after: (t, app) async {
      final field = find.widgetWithText(TextField, 'Medicine');
      await t.ensureVisible(field.first);
      await t.pump();
      await t.enterText(field.first, 'aug');
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }),
    ShotSpec('note', 'opd.consultation', args: _signedNote),
    ShotSpec('clinical_record', 'patients.profile', args: _patientWithHistory, after: (t, app) => _tapText(t, 'Clinical record')),
    // Last: the dialog stays open over whatever comes next.
    ShotSpec('vitals_dialog', 'opd.queue', after: (t, app) async {
      await t.tap(find.byIcon(Icons.more_vert).last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await _tapText(t, 'Record vitals');
    }),
  ];
}

void main() {
  setUpAll(loadFonts);
  setUp(() => _draftEncounterId = null);

  for (final (name, size) in [('desktop', desktopSize), ('tablet', tabletSize), ('phone', phoneSize)]) {
    testWidgets('opd $name', (t) => captureScreens(t,
        prefix: 'opd_$name',
        size: size,
        modules: [PatientsModule(), OpdModule()],
        username: 'drkhan',
        specs: _specs(size)));
  }
}

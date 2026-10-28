import 'dart:math';

import 'package:kendra_hms/core/core.dart';

import 'clinical.dart';
import 'clinical_data.dart';
import 'opd_schema.dart';
import 'opd_service.dart';

class _Med {
  const _Med(this.name, this.frequency, this.days, {this.dose, this.instructions = 'After food', this.alt});
  final String name; // a name from commonMedicines
  final String frequency;
  final int days;
  final String? dose;
  final String instructions;
  final _Med? alt; // used instead when the patient is allergic
}

enum _Kind { fever, gastro, bp, sugar, normal }

class _Template {
  const _Template({
    required this.complaint,
    required this.history,
    required this.exam,
    required this.dx,
    required this.icd,
    required this.meds,
    this.tests = const [],
    required this.advice,
    required this.followUpDays,
    this.kind = _Kind.normal,
  });
  final String complaint;
  final String history;
  final String exam;
  final String dx;
  final String icd;
  final List<_Med> meds;
  final List<String> tests;
  final String advice;
  final int followUpDays;
  final _Kind kind;
}

const _general = <_Template>[
  _Template(
    complaint: 'Fever with body ache since 2 days, sore throat',
    history: 'No cough or breathlessness. No travel history. Taking paracetamol at home.',
    exam: 'Conscious, oriented. Throat congested. Chest clear, bilateral air entry equal. P/A soft.',
    dx: 'Acute upper respiratory tract infection',
    icd: 'J06.9',
    meds: [_Med('Dolo 650', '1-1-1', 3), _Med('Levocet 5', '0-0-1', 5), _Med('Betadine Gargle', '1-0-1', 5, instructions: 'Gargle in warm water')],
    tests: ['Complete blood count (CBC)', 'Dengue NS1 antigen'],
    advice: 'Plenty of oral fluids. Steam inhalation twice a day. Rest for 2–3 days. Come back if fever lasts beyond 3 days.',
    followUpDays: 3,
    kind: _Kind.fever,
  ),
  _Template(
    complaint: 'Burning pain in upper abdomen since 4 days, worse after meals',
    history: 'Irregular meals and frequent tea. No vomiting, no black stools.',
    exam: 'P/A soft, epigastric tenderness present. No guarding. Bowel sounds normal.',
    dx: 'Acute gastritis',
    icd: 'K29.1',
    meds: [
      _Med('Pan 40', '1-0-0', 14, instructions: 'Before breakfast'),
      _Med('Sucrafil O Gel', '1-1-1', 7, instructions: 'Before food'),
      _Med('Domstal 10', '1-0-1', 5, instructions: 'Before food'),
    ],
    tests: ['USG abdomen'],
    advice: 'Avoid spicy and oily food, and tea on an empty stomach. Small frequent meals. No painkillers without advice.',
    followUpDays: 14,
  ),
  _Template(
    complaint: 'Routine BP check-up. Occasional headache in the mornings.',
    history: 'Known hypertensive for 5 years on Amlodipine 5 mg. Compliant with medicines. Non-smoker.',
    exam: 'CVS: S1 S2 normal, no murmur. No pedal oedema. Fundus not examined.',
    dx: 'Essential hypertension',
    icd: 'I10',
    meds: [_Med('Telma 40', '1-0-0', 30, instructions: 'Morning'), _Med('Amlong 5', '1-0-0', 30, instructions: 'Morning')],
    tests: ['Kidney function test (KFT)', 'Lipid profile', 'Serum electrolytes'],
    advice: 'Salt-restricted diet. Brisk walk 30 minutes daily. Check BP at home and bring the record next time.',
    followUpDays: 30,
    kind: _Kind.bp,
  ),
  _Template(
    complaint: 'Diabetes follow-up. Tiredness and increased thirst.',
    history: 'Known diabetic for 8 years on Metformin 500 mg twice daily. Diet control poor during festivals.',
    exam: 'No pedal oedema. Peripheral pulses felt. Foot examination normal, no ulcer.',
    dx: 'Type 2 diabetes mellitus',
    icd: 'E11.9',
    meds: [
      _Med('Glycomet 500', '1-0-1', 30),
      _Med('Amaryl 1', '1-0-0', 30, instructions: 'Before breakfast'),
      _Med('Atorva 10', '0-0-1', 30, instructions: 'At bedtime'),
    ],
    tests: ['HbA1c', 'Blood sugar — fasting', 'Lipid profile'],
    advice: 'Diabetic diet — avoid sweets, limit rice. Walk daily. Check sugar weekly and keep a record.',
    followUpDays: 30,
    kind: _Kind.sugar,
  ),
  _Template(
    complaint: 'Burning while passing urine and increased frequency since 3 days',
    history: 'No fever, no flank pain. Similar episode last year.',
    exam: 'Mild suprapubic tenderness. Renal angles non-tender.',
    dx: 'Urinary tract infection',
    icd: 'N39.0',
    meds: [
      _Med('Niftran 100', '1-0-1', 5),
      _Med('Citralka Syrup', '1-1-1', 5, dose: '10 ml', instructions: 'In a glass of water'),
      _Med('Dolo 650', 'SOS', 3, instructions: 'For fever or pain'),
    ],
    tests: ['Urine routine and microscopy', 'Urine culture'],
    advice: 'Drink 3 litres of water a day. Complete the full course of medicines.',
    followUpDays: 7,
  ),
  _Template(
    complaint: 'Loose motions 5–6 times since yesterday with mild abdominal cramps',
    history: 'Ate outside food two days ago. No blood in stools. Passing urine normally.',
    exam: 'Mild dehydration. P/A soft, mild diffuse tenderness. Bowel sounds increased.',
    dx: 'Acute gastroenteritis',
    icd: 'A09',
    meds: [
      _Med('Electral ORS', 'SOS', 3, instructions: '1 sachet in 1 litre water, after each loose stool'),
      _Med('O2 Tablet', '1-0-1', 5),
      _Med('Redotil 100', '1-1-1', 3),
    ],
    advice: 'ORS after every loose stool. Light diet — rice, curd, banana. Avoid outside food.',
    followUpDays: 3,
    kind: _Kind.gastro,
  ),
  _Template(
    complaint: 'Sneezing and running nose every morning since 2 weeks',
    history: 'Symptoms worse with dust. No fever. Similar complaints every winter.',
    exam: 'Nasal mucosa pale and boggy. Throat normal. Chest clear.',
    dx: 'Allergic rhinitis',
    icd: 'J30.4',
    meds: [_Med('Montair LC', '0-0-1', 14), _Med('Flomist Nasal Spray', '1-0-0', 14, instructions: '2 puffs in each nostril')],
    advice: 'Avoid dust. Wear a mask while cleaning. Wash pillow covers weekly.',
    followUpDays: 14,
  ),
];

const _paediatric = <_Template>[
  _Template(
    complaint: 'Cough and cold since 3 days, low-grade fever',
    history: 'Eating and playing normally. Immunisation up to date. Elder sibling has a cold.',
    exam: 'Active, playful. Throat congested. Chest clear, no wheeze. Ears normal.',
    dx: 'Acute upper respiratory tract infection',
    icd: 'J06.9',
    meds: [
      _Med('Calpol 250 Syrup', 'SOS', 3, instructions: 'If temperature above 100 °F'),
      _Med('Cetzine Syrup', '0-0-1', 5),
      _Med('Nasoclear Nasal Drops', '1-1-1', 5, instructions: 'Before feeds'),
    ],
    tests: ['Complete blood count (CBC)'],
    advice: 'Warm fluids. Saline drops before feeds. Come back at once if breathing fast or not feeding.',
    followUpDays: 3,
    kind: _Kind.fever,
  ),
  _Template(
    complaint: 'Loose stools and vomiting since 1 day',
    history: 'Passing urine normally. No blood in stools. Taking fluids in small sips.',
    exam: 'Alert. Mild dehydration, tongue slightly dry. P/A soft, non-tender.',
    dx: 'Acute gastroenteritis',
    icd: 'A09',
    meds: [
      _Med('Electral ORS', 'SOS', 3, instructions: '50–100 ml after every loose stool'),
      _Med('Zinconia Syrup', '1-0-0', 14),
      _Med('Ondem Syrup', 'SOS', 2, instructions: 'If vomiting'),
    ],
    advice: 'ORS after every loose stool. Continue feeds. Watch for less urine or drowsiness — come back at once.',
    followUpDays: 3,
    kind: _Kind.gastro,
  ),
  _Template(
    complaint: 'Fever since 2 days, up to 102 °F, with body ache',
    history: 'No rash, no bleeding. Taking fluids well. Two cases of dengue in the building.',
    exam: 'Febrile, no rash. Throat mildly congested. Chest clear. No hepatosplenomegaly.',
    dx: 'Viral fever',
    icd: 'B34.9',
    meds: [_Med('Calpol 250 Syrup', '1-1-1', 3, instructions: 'Every 6–8 hours if fever')],
    tests: ['Complete blood count (CBC)', 'Dengue NS1 antigen'],
    advice: 'Tepid sponging for fever. Plenty of fluids. Review if fever beyond 3 days or any rash or bleeding.',
    followUpDays: 3,
    kind: _Kind.fever,
  ),
  _Template(
    complaint: 'Right ear pain since 1 day with fever',
    history: 'Cold for the last 4 days. Crying at night.',
    exam: 'Right tympanic membrane congested and bulging. Throat congested.',
    dx: 'Acute otitis media',
    icd: 'H66.9',
    meds: [
      _Med('Augmentin Duo Syrup', '1-0-1', 7, alt: _Med('Azithral Syrup', '1-0-0', 3)),
      _Med('Calpol 250 Syrup', 'SOS', 3, instructions: 'For pain or fever'),
    ],
    advice: 'Keep the ear dry. Complete the antibiotic course.',
    followUpDays: 7,
    kind: _Kind.fever,
  ),
  _Template(
    complaint: 'Cough with noisy breathing since 4 days, worse at night',
    history: 'Similar episodes last winter. No fever now.',
    exam: 'Mild expiratory wheeze on both sides. No chest retractions.',
    dx: 'Acute bronchitis',
    icd: 'J20.9',
    meds: [_Med('Levolin Syrup', '1-1-1', 5), _Med('Montek 4 Granules', '0-0-1', 14, instructions: 'Mix with food')],
    advice: 'Steam inhalation. Avoid cold drinks and dust. Come back at once if breathing becomes difficult.',
    followUpDays: 7,
  ),
];

const _ortho = <_Template>[
  _Template(
    complaint: 'Pain in both knees since 6 months, worse on climbing stairs',
    history: 'Morning stiffness for about 10 minutes. No injury. Uses Indian toilet.',
    exam: 'Crepitus present in both knees. Medial joint line tenderness. Range of movement restricted at the end. No effusion.',
    dx: 'Osteoarthritis of knee',
    icd: 'M17.9',
    meds: [
      _Med('Hifenac P', '1-0-1', 7),
      _Med('Pan 40', '1-0-0', 7, instructions: 'Before breakfast'),
      _Med('Shelcal 500', '0-1-0', 30),
      _Med('Volini Gel', '1-0-1', 14, instructions: 'Apply on both knees'),
    ],
    tests: ['X-ray both knees', 'Vitamin D (25-OH)'],
    advice: 'Quadriceps strengthening exercises daily. Reduce weight. Avoid squatting and the Indian toilet.',
    followUpDays: 14,
  ),
  _Template(
    complaint: 'Low back pain since 1 week after lifting a heavy bag',
    history: 'No radiation to legs. No bladder or bowel complaints. Desk job.',
    exam: 'Paraspinal spasm at L4–L5. SLR negative both sides. No neurological deficit.',
    dx: 'Low back pain',
    icd: 'M54.5',
    meds: [
      _Med('Etoshine 90', '0-0-1', 5),
      _Med('Myoril 4', '1-0-1', 5),
      _Med('Pan 40', '1-0-0', 5, instructions: 'Before breakfast'),
    ],
    tests: ['X-ray LS spine'],
    advice: 'Hot fomentation twice a day. Avoid lifting heavy weights. Sleep on a firm mattress.',
    followUpDays: 7,
  ),
  _Template(
    complaint: 'Neck pain going to the right shoulder since 3 weeks',
    history: 'Works long hours on a laptop. Tingling in right fingers at times.',
    exam: 'Tenderness at C5–C6. Neck movements painful at extremes. Power normal in both arms.',
    dx: 'Cervical spondylosis',
    icd: 'M47.8',
    meds: [
      _Med('Hifenac P', '1-0-1', 7),
      _Med('Pregabid 75', '0-0-1', 14, instructions: 'At bedtime'),
      _Med('Nurokind OD', '1-0-0', 30),
    ],
    tests: ['X-ray cervical spine'],
    advice: 'Neck exercises as shown. Keep the laptop at eye level. Use a thin pillow.',
    followUpDays: 14,
  ),
  _Template(
    complaint: 'Twisted right ankle yesterday while walking, swelling and pain',
    history: 'Able to walk with a limp. No previous injury.',
    exam: 'Swelling over the lateral malleolus with ATFL tenderness. Bears weight with pain. Distal neurovascular status normal.',
    dx: 'Ankle sprain',
    icd: 'S93.4',
    meds: [
      _Med('Combiflam', '1-0-1', 5),
      _Med('Volini Gel', '1-1-1', 7, instructions: 'Apply gently, do not rub'),
      _Med('Pan 40', '1-0-0', 5, instructions: 'Before breakfast'),
    ],
    tests: ['X-ray ankle'],
    advice: 'Rest, ice packs, crepe bandage and keep the foot raised. Crepe bandage for 2 weeks.',
    followUpDays: 7,
  ),
];

/// Sample results for tests, used only when the lab module is not installed.
const _results = <String, (String, bool)>{
  'cbc': ('Hb 12.6 g/dL, TLC 9,800/µL, platelets 2.4 lakh/µL', false),
  'dengue': ('Negative', false),
  'hba1c': ('8.1 %', true),
  'fasting': ('148 mg/dL', true),
  'lipid': ('Total cholesterol 212, LDL 138, HDL 42, TG 176 mg/dL', true),
  'kidney': ('Urea 28, creatinine 0.9 mg/dL', false),
  'electrolytes': ('Na 139, K 4.2 mmol/L', false),
  'urine routine': ('Pus cells 15–20/hpf, nitrite positive', true),
  'culture': ('E. coli, sensitive to nitrofurantoin', true),
  'vitamin d': ('14 ng/mL (low)', true),
  'x-ray': ('Reported — see film', false),
  'usg': ('Normal study', false),
};

String _nurseName = 'Mary Thomas';

int _age(Rec p) {
  final dob = p.date('dob');
  if (dob != null) return ageInYears(dob);
  return p.intOrNull('age_years') ?? 30;
}

List<_Template> _templatesFor(Rec doctor, Rec patient) {
  final s = specialtyOf(doctor.strOrNull('department'));
  final child = _age(patient) < 14;
  if (s == Specialty.orthopaedics) return child ? [_ortho[3]] : _ortho;
  if (child) return _paediatric;
  return _general;
}

Map<String, Object?> _vitalsFor(_Template t, Rec patient, Random rnd) {
  final age = _age(patient);
  final child = age < 14;
  double r(double a, double b) => double.parse((a + rnd.nextDouble() * (b - a)).toStringAsFixed(1));
  int i(int a, int b) => a + rnd.nextInt(b - a + 1);
  final weight = child ? (8 + age * 2.6 + rnd.nextInt(4)).roundToDouble() : r(52, 88);
  final height = child ? (75 + age * 6.0 + rnd.nextInt(6)).roundToDouble() : i(150, 182).toDouble();
  final v = <String, Object?>{
    if (!child || age >= 6) ...{
      VitalKeys.bpSys: t.kind == _Kind.bp ? i(142, 162) : (child ? i(98, 112) : i(112, 134)),
      VitalKeys.bpDia: t.kind == _Kind.bp ? i(88, 98) : (child ? i(60, 72) : i(72, 86)),
    },
    VitalKeys.pulse: t.kind == _Kind.fever ? i(96, 112) : (child ? i(88, 110) : i(70, 92)),
    VitalKeys.tempC: t.kind == _Kind.fever ? r(37.9, 38.8) : r(36.5, 37.2),
    VitalKeys.spo2: i(96, 99),
    if (child) VitalKeys.rr: i(20, 28),
    VitalKeys.weightKg: weight,
    VitalKeys.heightCm: height,
    if (t.kind == _Kind.sugar) VitalKeys.grbs: i(168, 236),
  };
  return Vitals.clean(v);
}

class _Ctx {
  _Ctx({required this.medicines, required this.labServices, required this.labActive});
  final List<Rec> medicines;
  final List<Rec> labServices;
  final bool labActive;

  Map<String, Object?>? item(_Med m, String allergies) {
    final opt = commonMedicines.firstWhere((d) => d.name == m.name);
    if (Allergy.match(allergies, drugName: opt.name, genericName: opt.generic) != null) {
      return m.alt == null ? null : item(m.alt!, allergies);
    }
    final form = Rx.formOf(opt.form, opt.name);
    final master = _matchMedicine(opt);
    final dose = m.dose ?? (opt.defaultDose.isNotEmpty ? opt.defaultDose : Rx.defaultDose(form));
    return {
      'medicine_id': master?.id,
      'drug_name': master?.str('name') ?? opt.name,
      'generic_name': master?.strOrNull('generic_name') ?? opt.generic,
      'strength': master?.strOrNull('strength') ?? (opt.strength.isEmpty ? null : opt.strength),
      'form': form,
      'dose': dose,
      'frequency': m.frequency,
      'duration_days': m.days,
      'route': Rx.defaultRoute(form, opt.name),
      'instructions': m.instructions,
      'quantity': Rx.quantity(frequency: m.frequency, days: m.days, form: form, dose: dose, name: opt.name),
    };
  }

  Rec? _matchMedicine(DrugOption d) {
    if (medicines.isEmpty) return null;
    final name = d.name.toLowerCase();
    final generic = d.generic.toLowerCase();
    final form = Rx.formOf(d.form, d.name);
    for (final m in medicines) {
      if (m.str('name').toLowerCase() == name) return m;
    }
    Rec? loose;
    for (final m in medicines) {
      final g = m.str('generic_name').toLowerCase();
      if (g.isEmpty || generic.isEmpty) continue;
      if (g.contains(generic.split(' ').first) || generic.contains(g.split(' ').first)) {
        if (Rx.formOf(m.strOrNull('form'), m.str('name')) == form) return m;
        loose ??= m;
      }
    }
    return loose;
  }

  Map<String, Object?> order(String testName) {
    final l = testName.toLowerCase();
    final key = l.split(RegExp(r'[ (—-]')).first;
    Rec? svc;
    for (final s in labServices) {
      final n = s.str('name').toLowerCase();
      if (n == l || n.contains(l) || l.contains(n)) {
        svc = s;
        break;
      }
    }
    svc ??= labServices.where((s) => s.str('name').toLowerCase().startsWith(key)).firstOrNull;
    final radiology = l.startsWith('x-ray') || l.startsWith('usg');
    return {
      'service_code': svc?.str('code'),
      'name': svc?.str('name') ?? testName,
      'order_type': svc?.str('category') ?? (radiology ? Vals.radiology : Vals.lab),
      'priority': 'routine',
    };
  }
}

(String, bool)? _resultFor(String name) {
  final l = name.toLowerCase();
  for (final e in _results.entries) {
    if (l.contains(e.key) || (e.key == 'cbc' && l.contains('blood count')) || (e.key == 'kidney' && l.contains('kft'))) {
      return e.value;
    }
  }
  return ('Within normal limits', false);
}

/// Builds the writes for one signed consultation of a closed visit.
List<WriteOp> _signedVisit(Db db, Rec enc, Rec patient, Rec doctor, _Template t, _Ctx ctx, Random rnd, int fee,
    {bool withTests = false}) {
  final started = enc.date('called_at') ?? enc.date('started_at')!;
  final signedAt = enc.date('ended_at') ?? started.add(Duration(minutes: 6 + rnd.nextInt(9)));
  final allergies = patient.str('allergies');
  final rx = [for (final m in t.meds) ctx.item(m, allergies)].whereType<Map<String, Object?>>().toList();
  final orders = withTests ? [for (final name in t.tests) ctx.order(name)] : <Map<String, Object?>>[];
  final cid = db.newId();
  final rxId = rx.isEmpty ? null : db.newId();
  final ops = <WriteOp>[
    InsertOp(
      OpdCol.consultations,
      {
        'encounter_id': enc.id,
        'patient_id': patient.id,
        'doctor_id': doctor.id,
        'started_at': started,
        'vitals': _vitalsFor(t, patient, rnd),
        'vitals_at': started.subtract(Duration(minutes: 4 + rnd.nextInt(10))),
        'vitals_by_name': _nurseName,
        'chief_complaint': t.complaint,
        'history': t.history,
        'examination': t.exam,
        'diagnosis': t.dx,
        'icd_code': t.icd,
        'advice': t.advice,
        'follow_up_date': startOfDay(signedAt).add(Duration(days: t.followUpDays)),
        'rx_draft': rx,
        'orders_draft': orders,
        'status': ConsultStatus.signed,
        'signed_at': signedAt,
        'signed_by': doctor.id,
        'signed_by_name': doctor.str('display_name'),
        'prescription_id': rxId,
      },
      id: cid,
    ),
    if (rxId != null)
      InsertOp(
        Col.prescriptions,
        {
          'patient_id': patient.id,
          'encounter_id': enc.id,
          'doctor_id': doctor.id,
          'items': [
            for (final m in rx)
              {
                'medicine_id': m['medicine_id'],
                'drug_name': m['drug_name'],
                'generic_name': m['generic_name'],
                'dose': m['dose'],
                'frequency': m['frequency'],
                'duration_days': m['duration_days'],
                'route': m['route'],
                'instructions': m['instructions'],
                'quantity': m['quantity'],
              },
          ],
          'status': Vals.active,
          'notes': t.dx,
        },
        id: rxId,
      ),
    for (final o in orders)
      () {
        final old = DateTime.now().difference(signedAt) > const Duration(days: 1);
        final result = !ctx.labActive && old ? _resultFor(o['name'] as String) : null;
        return InsertOp(Col.serviceOrders, {
          'patient_id': patient.id,
          'encounter_id': enc.id,
          'order_type': o['order_type'],
          'service_code': o['service_code'],
          'name': o['name'],
          'status': result == null ? Vals.ordered : Vals.resulted,
          'priority': 'routine',
          'ordered_by': doctor.id,
          'ordered_at': signedAt,
          'clinical_notes': t.dx,
          if (result != null) ...{
            'result_summary': result.$1,
            'abnormal': result.$2,
            'resulted_at': signedAt.add(const Duration(hours: 5)),
          },
        });
      }(),
    InsertOp(Col.charges, {
      'patient_id': patient.id,
      'encounter_id': enc.id,
      'service_code': 'CONSULT',
      'description': 'Consultation — ${doctorLabel(doctor.str('display_name'))}',
      'category': Vals.consultation,
      'quantity': 1,
      'unit_price_paise': fee,
      'amount_paise': fee,
      'status': Vals.pending,
      'source_module': 'opd',
      'source_collection': OpdCol.consultations,
      'source_id': cid,
      'service_date': enc.date('started_at'),
      'ordered_by': doctor.id,
    }),
    if (enc.strOrNull('summary') == null) UpdateOp(Col.encounters, enc.id, {'summary': t.dx}),
  ];
  return ops;
}

DateTime _clampToday(DateTime t, DateTime now) {
  final today = startOfDay(now);
  if (t.isBefore(today)) return today.add(const Duration(minutes: 1));
  if (t.isAfter(now)) return now;
  return t;
}

/// When there is no appointments module, make the visits ourselves: about
/// two months of past OPD, a few seen today and a queue waiting now.
Future<void> _createVisits(Db db, List<Rec> doctors, List<Rec> patients, Random rnd, DateTime now) async {
  final kids = patients.where((p) => _age(p) < 14).toList();
  final adults = patients.where((p) => _age(p) >= 14).toList();
  final paeds = doctors.where((d) => specialtyOf(d.strOrNull('department')) == Specialty.paediatrics).toList();
  // Today's queue is decided first so nobody is both seen and waiting today.
  final waitingKids = [...kids]..sort((a, b) => (b.str('allergies').isEmpty ? 0 : 1).compareTo(a.str('allergies').isEmpty ? 0 : 1));
  final others = doctors.where((d) => !paeds.contains(d)).toList();
  final waiting = <(Rec, Rec)>[
    for (final d in paeds)
      for (final k in waitingKids.take(3)) (d, k),
    for (var i = 0; i < 3 && others.isNotEmpty; i++)
      (others[i % others.length], adults.isEmpty ? patients[i % patients.length] : adults[(i * 5 + 3) % adults.length]),
  ];
  final waitingIds = waiting.map((w) => w.$2.id).toSet();

  Rec pick(Rec doctor, {bool today = false}) {
    var pool = specialtyOf(doctor.strOrNull('department')) == Specialty.paediatrics && kids.isNotEmpty
        ? kids
        : (adults.isEmpty ? patients : adults);
    if (today) {
      final free = pool.where((p) => !waitingIds.contains(p.id)).toList();
      if (free.isNotEmpty) pool = free;
    }
    // Regulars come back: favour the first few of each pool.
    return rnd.nextDouble() < 0.6 ? pool[rnd.nextInt(min(pool.length, 6))] : pool[rnd.nextInt(pool.length)];
  }

  Future<void> visit(Rec doctor, Rec patient, DateTime arrived,
      {required String queue, DateTime? called, DateTime? ended}) async {
    final token = await db.nextSequence(OpdService.tokenSequence(doctor.id, arrived));
    await db.insert(Col.encounters, {
      'patient_id': patient.id,
      'type': Vals.opd,
      'status': queue == Vals.done ? Vals.closed : Vals.open,
      'doctor_id': doctor.id,
      'department': doctor.strOrNull('department'),
      'started_at': arrived,
      'ended_at': ended,
      'source_module': 'opd',
      'token_no': token,
      'queue_status': queue,
      'checked_in_at': arrived,
      'called_at': called,
    });
  }

  // Past visits, oldest first so tokens run in order within a day.
  final past = <(int, int, Rec)>[];
  for (var i = 0; i < 26; i++) {
    var day = 1 + rnd.nextInt(70);
    final d = now.subtract(Duration(days: day));
    if (d.weekday == DateTime.sunday) day += 1;
    past.add((day, 9 * 60 + 30 + rnd.nextInt(240), doctors[i % doctors.length]));
  }
  past.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  final seenOn = <String>{};
  for (final (day, minute, doctor) in past) {
    final date = startOfDay(now.subtract(Duration(days: day)));
    final arrived = date.add(Duration(minutes: minute));
    final called = arrived.add(Duration(minutes: 8 + rnd.nextInt(25)));
    // Nobody comes twice on the same day.
    var patient = pick(doctor);
    for (var tries = 0; tries < 8 && seenOn.contains('${patient.id}|$day'); tries++) {
      patient = pick(doctor);
    }
    if (!seenOn.add('${patient.id}|$day')) continue;
    await visit(doctor, patient, arrived,
        queue: Vals.done, called: called, ended: called.add(Duration(minutes: 5 + rnd.nextInt(10))));
  }

  // Seen earlier today.
  final seenToday = [doctors[0], if (doctors.length > 1) doctors[1], if (doctors.length > 2) doctors[2], ...paeds];
  for (final (i, doctor) in seenToday.indexed) {
    final arrived = _clampToday(now.subtract(Duration(minutes: 170 - i * 30)), now);
    final called = _clampToday(arrived.add(const Duration(minutes: 12)), now);
    await visit(doctor, pick(doctor, today: true), arrived,
        queue: Vals.done, called: called, ended: _clampToday(called.add(Duration(minutes: 7 + i)), now));
  }

  // Waiting now: the paediatrician's queue first (children, one with an allergy).
  for (final (i, (doctor, patient)) in waiting.indexed) {
    await visit(doctor, patient, _clampToday(now.subtract(Duration(minutes: 55 - i * 7)), now), queue: Vals.waiting);
  }
}

/// Signed notes for every finished OPD visit, nurse vitals for today's
/// queue, one forgotten draft from yesterday and one patient with
/// dangerously low oxygen today.
Future<void> seedDemoOpd(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final now = DateTime.now();
  final rnd = Random(23);
  final doctors = await db.query(const Query(Col.users).eq('is_clinician', true).sort('username').take(50));
  final patients = await db.query(const Query(Col.patients).sort('created_at').take(500));
  if (doctors.isEmpty || patients.isEmpty) return;
  final nurse = await db.first(const Query(Col.users).contains('role_ids', '"nurse"'));
  _nurseName = nurse?.str('display_name') ?? 'Nurse';

  var encounters = await db.query(const Query(Col.encounters).eq('type', Vals.opd).sort('started_at').take(3000));
  if (encounters.isEmpty) {
    await _createVisits(db, doctors, patients, rnd, now);
    encounters = await db.query(const Query(Col.encounters).eq('type', Vals.opd).sort('started_at').take(3000));
  }

  final c = _Ctx(
    medicines: (await db.query(const Query(Col.medicines).take(5000))).where((m) => m['active'] != false).toList(),
    labServices: await db.query(const Query(Col.services).isIn('category', [Vals.lab, Vals.radiology]).take(2000)),
    labActive: ctx.services.registry.isActive('lab'),
  );
  final consultFallback = (await db.first(const Query(Col.services).eq('code', 'CONSULT')))?.intOrNull('price_paise') ?? 50000;
  final noted = (await db.query(const Query(OpdCol.consultations).take(5000))).map((r) => r.str('encounter_id')).toSet();
  final patientById = {for (final p in patients) p.id: p};
  final doctorById = {for (final d in doctors) d.id: d};

  // 1. Every finished visit gets a signed note, prescription, tests and charge.
  var ops = <WriteOp>[];
  var n = 0;
  for (final e in encounters.where((e) => e.str('status') == Vals.closed && !noted.contains(e.id))) {
    final patient = patientById[e.str('patient_id')];
    if (patient == null) continue;
    final doctor = doctorById[e.str('doctor_id')] ?? doctors[n % doctors.length];
    final templates = _templatesFor(doctor, patient);
    final t = templates[rnd.nextInt(templates.length)];
    final fee = doctor.intOrNull('consultation_fee_paise') ?? consultFallback;
    ops.addAll(_signedVisit(db, e, patient, doctor, t, c, rnd, fee, withTests: t.tests.isNotEmpty && rnd.nextDouble() < 0.3));
    noted.add(e.id);
    n++;
    if (ops.length > 120) {
      await db.batch(ops);
      ops = <WriteOp>[];
    }
  }
  await db.batch(ops);

  // 2. Today's queue: the nurse has taken vitals for most patients; one
  //    adult's oxygen is dangerously low.
  final today = startOfDay(now);
  final waiting = encounters
      .where((e) => OpdService.isWaiting(e) && !e.date('started_at')!.isBefore(today) && !noted.contains(e.id))
      .toList();
  Rec? lowOxygen;
  for (final e in waiting) {
    final p = patientById[e.str('patient_id')];
    final d = doctorById[e.str('doctor_id')];
    if (p != null && d != null && _age(p) >= 14 && specialtyOf(d.strOrNull('department')) == Specialty.general) {
      lowOxygen = e;
      break;
    }
  }
  if (lowOxygen == null && waiting.isNotEmpty) {
    lowOxygen = waiting.firstWhere((e) => (patientById[e.str('patient_id')] == null ? 0 : _age(patientById[e.str('patient_id')]!)) >= 14,
        orElse: () => waiting.first);
  }
  if (lowOxygen == null) {
    // Nobody is waiting: bring in a breathless walk-in for a physician.
    final doctor = doctors.firstWhere((d) => specialtyOf(d.strOrNull('department')) == Specialty.general, orElse: () => doctors.first);
    final adult = patients.firstWhere((p) => _age(p) >= 30, orElse: () => patients.first);
    lowOxygen = (await OpdService.addWalkIn(db, patientId: adult.id, doctor: doctor, now: now.subtract(const Duration(minutes: 20)))).$1;
    waiting.add(lowOxygen);
  }
  ops = <WriteOp>[];
  for (final (i, e) in waiting.indexed) {
    final p = patientById[e.str('patient_id')];
    if (p == null) continue;
    final critical = e.id == lowOxygen.id;
    if (!critical && i % 3 == 2) continue; // vitals not taken yet
    final arrived = e.date('checked_in_at') ?? e.date('started_at')!;
    final v = critical
        ? Vitals.clean({
            VitalKeys.bpSys: 138, VitalKeys.bpDia: 86, VitalKeys.pulse: 112, VitalKeys.tempC: 38.4, VitalKeys.spo2: 88,
            VitalKeys.rr: 26, VitalKeys.weightKg: 71, VitalKeys.heightCm: 166,
          })
        : _vitalsFor(_age(p) < 14 ? _paediatric.first : _general[i.isEven ? 2 : 0], p, rnd);
    ops.add(InsertOp(OpdCol.consultations, {
      'encounter_id': e.id,
      'patient_id': p.id,
      'doctor_id': e.str('doctor_id'),
      'started_at': arrived,
      'vitals': v,
      'vitals_at': _clampToday(arrived.add(const Duration(minutes: 4)), now),
      'vitals_by_name': _nurseName,
      if (critical) 'chief_complaint': 'Breathlessness since last night, fever and cough for 3 days',
      'status': ConsultStatus.draft,
    }));
    noted.add(e.id);
  }
  await db.batch(ops);

  // 3. A note left unfinished yesterday (the unsigned-notes agent finds it).
  final paed = doctors.firstWhere((d) => specialtyOf(d.strOrNull('department')) == Specialty.paediatrics,
      orElse: () => doctors.first);
  final yesterday = startOfDay(now).subtract(const Duration(days: 1)).add(const Duration(hours: 11, minutes: 20));
  final busy = waiting.map((e) => e.str('patient_id')).toSet();
  final kid = patients.firstWhere((p) => _age(p) < 14 && !busy.contains(p.id),
      orElse: () => patients.firstWhere((p) => !busy.contains(p.id), orElse: () => patients.last));
  final token = await db.nextSequence(OpdService.tokenSequence(paed.id, yesterday));
  final draftEnc = await db.insert(Col.encounters, {
    'patient_id': kid.id,
    'type': Vals.opd,
    'status': Vals.open,
    'doctor_id': paed.id,
    'department': paed.strOrNull('department'),
    'started_at': yesterday,
    'source_module': 'opd',
    'token_no': token,
    'queue_status': Vals.withDoctor,
    'checked_in_at': yesterday,
    'called_at': yesterday.add(const Duration(minutes: 15)),
  });
  await db.insert(OpdCol.consultations, {
    'encounter_id': draftEnc.id,
    'patient_id': kid.id,
    'doctor_id': paed.id,
    'started_at': yesterday.add(const Duration(minutes: 15)),
    'vitals': _vitalsFor(_paediatric.first, kid, rnd),
    'vitals_at': yesterday.add(const Duration(minutes: 5)),
    'vitals_by_name': _nurseName,
    'chief_complaint': 'Fever and cough since 2 days',
    'history': 'Immunisation up to date. Feeding well.',
    'examination': 'Active. Throat congested. Chest clear.',
    'diagnosis': 'Acute upper respiratory tract infection',
    'icd_code': 'J06.9',
    'rx_draft': [c.item(const _Med('Calpol 250 Syrup', 'SOS', 3, instructions: 'If temperature above 100 °F'), kid.str('allergies'))]
        .whereType<Map<String, Object?>>()
        .toList(),
    'orders_draft': const <Object?>[],
    'status': ConsultStatus.draft,
  });

  // 4. One corrected note, so the amendment history has something to show.
  final recent = await db.first(Query(OpdCol.consultations)
      .eq('doctor_id', paed.id)
      .eq('status', ConsultStatus.signed)
      .sort('signed_at', desc: true));
  if (recent != null) {
    final old = recent.str('examination');
    final updated = '$old Ears normal on both sides.';
    await db.batch([
      InsertOp(OpdCol.amendments, {
        'consultation_id': recent.id,
        'patient_id': recent.str('patient_id'),
        'reason': 'Additional findings recorded after review',
        'changes': [
          {'field': 'examination', 'old': old, 'new': updated},
        ],
        'amended_by_name': paed.str('display_name'),
      }),
      UpdateOp(OpdCol.consultations, recent.id, {
        'examination': updated,
        'amended_at': (recent.date('signed_at') ?? now).add(const Duration(minutes: 40)),
      }),
    ]);
  }
}

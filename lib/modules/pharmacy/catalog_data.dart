import 'package:kendra_hms/core/core.dart';

import 'pharmacy_schema.dart';
import 'pharmacy_service.dart';

/// Supplier groups used by the demo to give products a preferred supplier.
enum MedGroup { acute, chronic, hospital, general }

/// One medicine of the starter list: core `medicines` row + pharmacy product.
class SeedMed {
  const SeedMed(
    this.name,
    this.generic,
    this.form,
    this.strength,
    this.unit,
    this.schedule,
    this.dose,
    this.frequency,
    this.mrpPaise,
    this.group, {
    this.reorder = 100,
    this.reorderQty = 300,
    this.gst = 12,
  });
  final String name;
  final String generic;
  final String form;
  final String strength;
  final String unit;
  final String schedule;
  final String dose;
  final String frequency;
  final int mrpPaise; // per dispensing unit
  final MedGroup group;
  final int reorder;
  final int reorderQty;
  final double gst;

  int get costPaise => (mrpPaise * 0.7).round();
}

const _a = MedGroup.acute;
const _c = MedGroup.chronic;
const _h = MedGroup.hospital;
const _g = MedGroup.general;

/// About 60 medicines a small Indian multispeciality hospital stocks.
const starterMedicines = <SeedMed>[
  // Fever and pain
  SeedMed('Dolo 650', 'Paracetamol', 'tablet', '650 mg', 'tablet', 'OTC', '1 tablet', '1-1-1', 206, _a, reorder: 200, reorderQty: 600),
  SeedMed('Calpol 500', 'Paracetamol', 'tablet', '500 mg', 'tablet', 'OTC', '1 tablet', '1-1-1', 120, _a, reorder: 150, reorderQty: 450),
  SeedMed('Calpol 250 Syrup', 'Paracetamol', 'syrup', '250 mg/5 ml, 60 ml', 'bottle', 'OTC', '5 ml', '1-1-1', 5500, _a, reorder: 15, reorderQty: 40),
  SeedMed('Brufen 400', 'Ibuprofen', 'tablet', '400 mg', 'tablet', 'H', '1 tablet', '1-0-1', 150, _a, reorder: 100, reorderQty: 300),
  SeedMed('Combiflam', 'Ibuprofen + Paracetamol', 'tablet', '400/325 mg', 'tablet', 'OTC', '1 tablet', '1-0-1', 250, _a, reorder: 100, reorderQty: 300),
  SeedMed('Zerodol-P', 'Aceclofenac + Paracetamol', 'tablet', '100/325 mg', 'tablet', 'H', '1 tablet', '1-0-1', 550, _a, reorder: 100, reorderQty: 300),
  SeedMed('Voveran 50', 'Diclofenac', 'tablet', '50 mg', 'tablet', 'H', '1 tablet', '1-0-1', 300, _a, reorder: 60, reorderQty: 200),
  SeedMed('Ultracet', 'Tramadol + Paracetamol', 'tablet', '37.5/325 mg', 'tablet', 'H1', '1 tablet', 'SOS', 1200, _a, reorder: 30, reorderQty: 100),
  SeedMed('Meftal-Spas', 'Mefenamic acid + Dicyclomine', 'tablet', '250/10 mg', 'tablet', 'H', '1 tablet', 'SOS', 450, _a, reorder: 60, reorderQty: 200),
  // Antibiotics
  SeedMed('Mox 500', 'Amoxicillin', 'capsule', '500 mg', 'capsule', 'H', '1 capsule', '1-1-1', 650, _a, reorder: 90, reorderQty: 300),
  SeedMed('Augmentin 625 Duo', 'Amoxicillin + Clavulanic acid', 'tablet', '500/125 mg', 'tablet', 'H', '1 tablet', '1-0-1', 2050, _a, reorder: 60, reorderQty: 180),
  SeedMed('Azithral 500', 'Azithromycin', 'tablet', '500 mg', 'tablet', 'H', '1 tablet', '1-0-0', 2400, _a, reorder: 45, reorderQty: 150),
  SeedMed('Azithral 200 Liquid', 'Azithromycin', 'syrup', '200 mg/5 ml, 15 ml', 'bottle', 'H', '5 ml', '1-0-0', 7800, _a, reorder: 10, reorderQty: 30),
  SeedMed('Taxim-O 200', 'Cefixime', 'tablet', '200 mg', 'tablet', 'H1', '1 tablet', '1-0-1', 1100, _a, reorder: 60, reorderQty: 200),
  SeedMed('Monocef 1g Injection', 'Ceftriaxone', 'injection', '1 g', 'vial', 'H1', '1 vial', '1-0-1', 6200, _h, reorder: 20, reorderQty: 60),
  SeedMed('Ciplox 500', 'Ciprofloxacin', 'tablet', '500 mg', 'tablet', 'H', '1 tablet', '1-0-1', 450, _a, reorder: 60, reorderQty: 200),
  SeedMed('Levoflox 500', 'Levofloxacin', 'tablet', '500 mg', 'tablet', 'H1', '1 tablet', '1-0-0', 900, _a, reorder: 30, reorderQty: 100),
  SeedMed('Metrogyl 400', 'Metronidazole', 'tablet', '400 mg', 'tablet', 'H', '1 tablet', '1-1-1', 180, _a, reorder: 90, reorderQty: 300),
  SeedMed('Doxy 100', 'Doxycycline', 'capsule', '100 mg', 'capsule', 'H', '1 capsule', '1-0-1', 400, _a, reorder: 40, reorderQty: 120),
  // Stomach
  SeedMed('Pan 40', 'Pantoprazole', 'tablet', '40 mg', 'tablet', 'H', '1 tablet', '1-0-0', 750, _g, reorder: 150, reorderQty: 450),
  SeedMed('Pan-D', 'Pantoprazole + Domperidone', 'capsule', '40/30 mg', 'capsule', 'H', '1 capsule', '1-0-0', 1250, _g, reorder: 90, reorderQty: 300),
  SeedMed('Omez 20', 'Omeprazole', 'capsule', '20 mg', 'capsule', 'H', '1 capsule', '1-0-0', 550, _g, reorder: 60, reorderQty: 200),
  SeedMed('Ondem 4', 'Ondansetron', 'tablet', '4 mg', 'tablet', 'H', '1 tablet', 'SOS', 550, _g, reorder: 60, reorderQty: 200),
  SeedMed('Gelusil MPS Syrup', 'Antacid (Aluminium + Magnesium hydroxide + Simethicone)', 'syrup', '200 ml', 'bottle', 'OTC', '10 ml', '1-1-1', 14500, _g, reorder: 10, reorderQty: 30),
  SeedMed('Electral ORS', 'Oral rehydration salts', 'other', '21.8 g sachet', 'sachet', 'OTC', '1 sachet in 1 litre water', 'After each loose stool', 2100, _g, reorder: 60, reorderQty: 200),
  SeedMed('Econorm', 'Saccharomyces boulardii', 'other', '250 mg sachet', 'sachet', 'OTC', '1 sachet', '1-0-1', 3200, _g, reorder: 30, reorderQty: 100),
  SeedMed('Dulcolax 5', 'Bisacodyl', 'tablet', '5 mg', 'tablet', 'OTC', '1 tablet', 'HS', 120, _g, reorder: 40, reorderQty: 120),
  // Allergy
  SeedMed('Cetzine 10', 'Cetirizine', 'tablet', '10 mg', 'tablet', 'OTC', '1 tablet', '0-0-1', 190, _g, reorder: 100, reorderQty: 300),
  SeedMed('Allegra 120', 'Fexofenadine', 'tablet', '120 mg', 'tablet', 'H', '1 tablet', '1-0-0', 2000, _g, reorder: 40, reorderQty: 120),
  SeedMed('Montair LC', 'Montelukast + Levocetirizine', 'tablet', '10/5 mg', 'tablet', 'H', '1 tablet', '0-0-1', 1650, _g, reorder: 60, reorderQty: 200),
  SeedMed('Avil 25', 'Pheniramine', 'tablet', '25 mg', 'tablet', 'H', '1 tablet', '1-0-1', 60, _g, reorder: 40, reorderQty: 120),
  // Diabetes
  SeedMed('Glycomet 500', 'Metformin', 'tablet', '500 mg', 'tablet', 'H', '1 tablet', '1-0-1', 190, _c, reorder: 200, reorderQty: 600),
  SeedMed('Glycomet GP 1', 'Metformin + Glimepiride', 'tablet', '500/1 mg', 'tablet', 'H', '1 tablet', '1-0-1', 750, _c, reorder: 150, reorderQty: 450),
  SeedMed('Amaryl 1', 'Glimepiride', 'tablet', '1 mg', 'tablet', 'H', '1 tablet', '1-0-0', 1250, _c, reorder: 60, reorderQty: 200),
  SeedMed('Janumet 50/500', 'Sitagliptin + Metformin', 'tablet', '50/500 mg', 'tablet', 'H', '1 tablet', '1-0-1', 3900, _c, reorder: 60, reorderQty: 150),
  SeedMed('Huminsulin 30/70', 'Human insulin (30/70)', 'injection', '40 IU/ml, 10 ml', 'vial', 'H', 'As advised', '1-0-1', 17500, _h, reorder: 10, reorderQty: 30, gst: 5),
  SeedMed('Lantus SoloStar', 'Insulin glargine', 'injection', '100 IU/ml, 3 ml pen', 'pen', 'H', 'As advised', '0-0-1', 75000, _h, reorder: 5, reorderQty: 15, gst: 5),
  // Heart and blood pressure
  SeedMed('Amlong 5', 'Amlodipine', 'tablet', '5 mg', 'tablet', 'H', '1 tablet', '1-0-0', 300, _c, reorder: 150, reorderQty: 450),
  SeedMed('Telma 40', 'Telmisartan', 'tablet', '40 mg', 'tablet', 'H', '1 tablet', '1-0-0', 800, _c, reorder: 150, reorderQty: 450),
  SeedMed('Telma-H', 'Telmisartan + Hydrochlorothiazide', 'tablet', '40/12.5 mg', 'tablet', 'H', '1 tablet', '1-0-0', 1050, _c, reorder: 60, reorderQty: 200),
  SeedMed('Losar 50', 'Losartan', 'tablet', '50 mg', 'tablet', 'H', '1 tablet', '1-0-0', 450, _c, reorder: 60, reorderQty: 200),
  SeedMed('Met XL 50', 'Metoprolol succinate', 'tablet', '50 mg', 'tablet', 'H', '1 tablet', '1-0-0', 900, _c, reorder: 60, reorderQty: 200),
  SeedMed('Atorva 10', 'Atorvastatin', 'tablet', '10 mg', 'tablet', 'H', '1 tablet', '0-0-1', 950, _c, reorder: 150, reorderQty: 450),
  SeedMed('Rosuvas 10', 'Rosuvastatin', 'tablet', '10 mg', 'tablet', 'H', '1 tablet', '0-0-1', 1700, _c, reorder: 60, reorderQty: 200),
  SeedMed('Ecosprin 75', 'Aspirin', 'tablet', '75 mg', 'tablet', 'OTC', '1 tablet', '0-1-0', 50, _c, reorder: 150, reorderQty: 450),
  SeedMed('Clopilet 75', 'Clopidogrel', 'tablet', '75 mg', 'tablet', 'H', '1 tablet', '0-1-0', 650, _c, reorder: 60, reorderQty: 200),
  SeedMed('Thyronorm 50', 'Levothyroxine', 'tablet', '50 mcg', 'tablet', 'H', '1 tablet', '1-0-0 empty stomach', 160, _c, reorder: 100, reorderQty: 300),
  // Chest
  SeedMed('Asthalin Inhaler', 'Salbutamol', 'inhaler', '100 mcg/dose, 200 doses', 'inhaler', 'H', '2 puffs', 'SOS', 15400, _g, reorder: 8, reorderQty: 24),
  SeedMed('Budecort 200 Inhaler', 'Budesonide', 'inhaler', '200 mcg/dose', 'inhaler', 'H', '2 puffs', '1-0-1', 38000, _g, reorder: 5, reorderQty: 15),
  SeedMed('Foracort 200 Inhaler', 'Formoterol + Budesonide', 'inhaler', '6/200 mcg/dose', 'inhaler', 'H', '2 puffs', '1-0-1', 45000, _g, reorder: 5, reorderQty: 15),
  SeedMed('Ascoril LS Syrup', 'Ambroxol + Levosalbutamol + Guaifenesin', 'syrup', '100 ml', 'bottle', 'H', '5 ml', '1-1-1', 11500, _g, reorder: 15, reorderQty: 40),
  SeedMed('Wysolone 10', 'Prednisolone', 'tablet', '10 mg', 'tablet', 'H', '1 tablet', '1-0-0', 110, _g, reorder: 60, reorderQty: 200),
  // Ward stock: fluids and injections
  SeedMed('Normal Saline 500 ml', 'Sodium chloride 0.9%', 'injection', '500 ml', 'bottle', 'H', '500 ml IV', 'As advised', 3500, _h, reorder: 40, reorderQty: 120),
  SeedMed('Ringer Lactate 500 ml', 'Compound sodium lactate', 'injection', '500 ml', 'bottle', 'H', '500 ml IV', 'As advised', 3800, _h, reorder: 30, reorderQty: 100),
  SeedMed('DNS 500 ml', 'Dextrose 5% + Sodium chloride 0.9%', 'injection', '500 ml', 'bottle', 'H', '500 ml IV', 'As advised', 3600, _h, reorder: 30, reorderQty: 100),
  SeedMed('Pantocid IV 40', 'Pantoprazole', 'injection', '40 mg', 'vial', 'H', '1 vial IV', '1-0-0', 5500, _h, reorder: 20, reorderQty: 60),
  SeedMed('Emeset Injection', 'Ondansetron', 'injection', '2 mg/ml, 2 ml', 'ampoule', 'H', '1 ampoule IV', 'SOS', 1200, _h, reorder: 20, reorderQty: 60),
  // Skin, eye and ear
  SeedMed('Soframycin Cream', 'Framycetin', 'ointment', '1%, 30 g', 'tube', 'OTC', 'Apply thinly', '1-0-1', 5500, _g, reorder: 10, reorderQty: 30),
  SeedMed('Betadine Ointment', 'Povidone iodine', 'ointment', '5%, 20 g', 'tube', 'OTC', 'Apply on wound', '1-0-1', 12000, _g, reorder: 10, reorderQty: 30),
  SeedMed('Candid Cream', 'Clotrimazole', 'ointment', '1%, 20 g', 'tube', 'OTC', 'Apply thinly', '1-0-1', 9500, _g, reorder: 10, reorderQty: 30),
  SeedMed('Volini Gel', 'Diclofenac + Methyl salicylate', 'ointment', '30 g', 'tube', 'OTC', 'Apply on painful area', '1-1-1', 12500, _g, reorder: 10, reorderQty: 30),
  SeedMed('Moxicip Eye Drops', 'Moxifloxacin', 'drops', '0.5%, 5 ml', 'bottle', 'H', '1 drop', '1-1-1-1', 9000, _g, reorder: 10, reorderQty: 30),
  SeedMed('Ciplox Eye/Ear Drops', 'Ciprofloxacin', 'drops', '0.3%, 10 ml', 'bottle', 'H', '2 drops', '1-1-1', 2200, _g, reorder: 10, reorderQty: 30),
  SeedMed('Refresh Tears', 'Carboxymethylcellulose', 'drops', '0.5%, 10 ml', 'bottle', 'OTC', '1 drop', '1-1-1', 15000, _g, reorder: 8, reorderQty: 24),
  // Vitamins and supplements
  SeedMed('Becosules', 'Vitamin B complex + Vitamin C', 'capsule', '—', 'capsule', 'OTC', '1 capsule', '1-0-0', 250, _c, reorder: 100, reorderQty: 300),
  SeedMed('Shelcal 500', 'Calcium + Vitamin D3', 'tablet', '500 mg/250 IU', 'tablet', 'OTC', '1 tablet', '0-1-0', 700, _c, reorder: 100, reorderQty: 300),
  SeedMed('Neurobion Forte', 'Vitamin B1 + B6 + B12', 'tablet', '—', 'tablet', 'OTC', '1 tablet', '1-0-0', 160, _c, reorder: 100, reorderQty: 300),
  SeedMed('Orofer XT', 'Ferrous ascorbate + Folic acid', 'tablet', '100/1.5 mg', 'tablet', 'OTC', '1 tablet', '0-1-0', 1300, _c, reorder: 60, reorderQty: 200),
  SeedMed('Uprise-D3 60K', 'Cholecalciferol', 'capsule', '60000 IU', 'capsule', 'H', '1 capsule', 'Weekly', 3000, _c, reorder: 20, reorderQty: 60),
];

/// "Dolo 650" → "DOLO650"; made unique with a number when needed.
String skuFor(String name, Set<String> taken) {
  var base = name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (base.length > 14) base = base.substring(0, 14);
  if (base.isEmpty) base = 'ITEM';
  var sku = base;
  var n = 2;
  while (taken.contains(sku)) {
    sku = '$base-${n++}';
  }
  taken.add(sku);
  return sku;
}

String rackFor(MedGroup g, int i) => '${switch (g) {
      MedGroup.acute => 'A',
      MedGroup.chronic => 'C',
      MedGroup.hospital => 'F',
      MedGroup.general => 'G',
    }}${(i % 6) + 1}';

SeedMed? seedFor(String name) {
  final n = PharmacyService.norm(name);
  for (final s in starterMedicines) {
    if (PharmacyService.norm(s.name) == n) return s;
  }
  return null;
}

/// Seeds the shared medicine master (core `medicines`) and a pharmacy
/// product for each. Medicines another module already added are reused,
/// never duplicated.
Future<void> seedStarterCatalog(Db db) async {
  final meds = await db.query(const Query(Col.medicines).take(5000).withArchived());
  final byName = {for (final m in meds) PharmacyService.norm(m.str('name')): m};
  final ops = <WriteOp>[];
  for (final s in starterMedicines) {
    if (byName.containsKey(PharmacyService.norm(s.name))) continue;
    ops.add(InsertOp(Col.medicines, {
      'name': s.name,
      'generic_name': s.generic,
      'form': s.form,
      'strength': s.strength,
      'unit': s.unit,
      'schedule': s.schedule,
      'default_dose': s.dose,
      'default_frequency': s.frequency,
      'active': true,
    }));
  }
  await db.batch(ops);
  await ensureProducts(db);
}

/// Every active medicine gets a pharmacy product (with starter prices when
/// it is one of ours, otherwise zero prices for the pharmacist to set).
Future<int> ensureProducts(Db db) async {
  final meds = await db.query(const Query(Col.medicines).eq('active', true).sort('name').take(5000));
  final products = await db.query(const Query(PCol.products).take(5000).withArchived());
  final stocked = {for (final p in products) p.str('medicine_id')};
  final skus = {for (final p in products) p.str('sku')};
  final ops = <WriteOp>[];
  final counters = <MedGroup, int>{};
  for (final m in meds) {
    if (stocked.contains(m.id)) continue;
    final s = seedFor(m.str('name'));
    final g = s?.group ?? MedGroup.general;
    final i = counters[g] = (counters[g] ?? 0) + 1;
    ops.add(InsertOp(PCol.products, {
      'medicine_id': m.id,
      'name': m.str('name'),
      'generic_name': m.strOrNull('generic_name'),
      'sku': skuFor(m.str('name'), skus),
      'unit': m.strOrNull('unit') ?? s?.unit ?? 'unit',
      'mrp_paise': s?.mrpPaise ?? 0,
      'purchase_price_paise': s?.costPaise ?? 0,
      'gst_percent': s?.gst ?? 12.0,
      'reorder_level': s?.reorder ?? 0,
      'reorder_qty': s?.reorderQty ?? 0,
      'rack': rackFor(g, i),
      'active': true,
    }));
  }
  await db.batch(ops);
  return ops.length;
}

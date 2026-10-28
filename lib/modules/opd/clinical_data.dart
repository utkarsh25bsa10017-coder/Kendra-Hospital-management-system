/// Reference lists used when the hospital's own masters are empty, and the
/// one-tap phrases on the consultation screen.
library;

/// A medicine the doctor can pick. From the `medicines` master when it has
/// rows (then [id] is set), otherwise from [commonMedicines].
class DrugOption {
  const DrugOption({
    this.id,
    required this.name,
    this.generic = '',
    this.form = '',
    this.strength = '',
    this.defaultDose = '',
    this.defaultFrequency = '',
  });
  final String? id;
  final String name;
  final String generic;
  final String form;
  final String strength;
  final String defaultDose;
  final String defaultFrequency;

  String get detail => [generic, strength].where((s) => s.isNotEmpty).join(' · ');
}

/// A test the doctor can order: from `services` (lab / radiology) when the
/// price list has them, otherwise from [commonTests] with no code.
class TestOption {
  const TestOption({this.code, required this.name, required this.type});
  final String? code;
  final String name;
  final String type; // lab | radiology
}

class DiagnosisOption {
  const DiagnosisOption(this.name, [this.icd = '']);
  final String name;
  final String icd;
}

const commonMedicines = <DrugOption>[
  DrugOption(name: 'Dolo 650', generic: 'Paracetamol', form: 'tablet', strength: '650 mg', defaultDose: '1 tablet', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Calpol 250 Syrup', generic: 'Paracetamol', form: 'syrup', strength: '250 mg/5 ml', defaultDose: '5 ml', defaultFrequency: 'SOS'),
  DrugOption(name: 'Levocet 5', generic: 'Levocetirizine', form: 'tablet', strength: '5 mg', defaultDose: '1 tablet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Cetzine Syrup', generic: 'Cetirizine', form: 'syrup', strength: '5 mg/5 ml', defaultDose: '2.5 ml', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Allegra 120', generic: 'Fexofenadine', form: 'tablet', strength: '120 mg', defaultDose: '1 tablet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Ascoril LS Syrup', generic: 'Ambroxol + Levosalbutamol + Guaifenesin', form: 'syrup', defaultDose: '5 ml', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Montair LC', generic: 'Montelukast + Levocetirizine', form: 'tablet', strength: '10/5 mg', defaultDose: '1 tablet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Montek 4 Granules', generic: 'Montelukast', form: 'sachet', strength: '4 mg', defaultDose: '1 sachet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Levolin Syrup', generic: 'Levosalbutamol', form: 'syrup', strength: '1 mg/5 ml', defaultDose: '2.5 ml', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Flomist Nasal Spray', generic: 'Fluticasone', form: 'spray', strength: '50 mcg', defaultDose: '2 puffs', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Nasoclear Nasal Drops', generic: 'Sodium chloride (saline)', form: 'drops', strength: '0.65%', defaultDose: '2 drops', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Betadine Gargle', generic: 'Povidone iodine', form: 'gargle', strength: '2%', defaultDose: '10 ml', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Pan 40', generic: 'Pantoprazole', form: 'tablet', strength: '40 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Domstal 10', generic: 'Domperidone', form: 'tablet', strength: '10 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Sucrafil O Gel', generic: 'Sucralfate + Oxetacaine', form: 'syrup', defaultDose: '10 ml', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Electral ORS', generic: 'Oral rehydration salts', form: 'sachet', defaultDose: '1 sachet', defaultFrequency: 'SOS'),
  DrugOption(name: 'O2 Tablet', generic: 'Ofloxacin + Ornidazole', form: 'tablet', strength: '200/500 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Redotil 100', generic: 'Racecadotril', form: 'capsule', strength: '100 mg', defaultDose: '1 capsule', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Zinconia Syrup', generic: 'Zinc sulphate', form: 'syrup', strength: '20 mg/5 ml', defaultDose: '5 ml', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Ondem Syrup', generic: 'Ondansetron', form: 'syrup', strength: '2 mg/5 ml', defaultDose: '2.5 ml', defaultFrequency: 'SOS'),
  DrugOption(name: 'Augmentin 625', generic: 'Amoxicillin + Clavulanic acid', form: 'tablet', strength: '625 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Augmentin Duo Syrup', generic: 'Amoxicillin + Clavulanic acid', form: 'syrup', strength: '228.5 mg/5 ml', defaultDose: '5 ml', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Azithral 500', generic: 'Azithromycin', form: 'tablet', strength: '500 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Azithral Syrup', generic: 'Azithromycin', form: 'syrup', strength: '200 mg/5 ml', defaultDose: '5 ml', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Taxim-O 200', generic: 'Cefixime', form: 'tablet', strength: '200 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Niftran 100', generic: 'Nitrofurantoin', form: 'capsule', strength: '100 mg', defaultDose: '1 capsule', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Bactrim DS', generic: 'Sulfamethoxazole + Trimethoprim', form: 'tablet', strength: '800/160 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Citralka Syrup', generic: 'Disodium hydrogen citrate', form: 'syrup', defaultDose: '10 ml', defaultFrequency: '1-1-1'),
  DrugOption(name: 'Telma 40', generic: 'Telmisartan', form: 'tablet', strength: '40 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Amlong 5', generic: 'Amlodipine', form: 'tablet', strength: '5 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Glycomet 500', generic: 'Metformin', form: 'tablet', strength: '500 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Amaryl 1', generic: 'Glimepiride', form: 'tablet', strength: '1 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Atorva 10', generic: 'Atorvastatin', form: 'tablet', strength: '10 mg', defaultDose: '1 tablet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Ecosprin 75', generic: 'Aspirin', form: 'tablet', strength: '75 mg', defaultDose: '1 tablet', defaultFrequency: '0-1-0'),
  DrugOption(name: 'Thyronorm 50', generic: 'Levothyroxine', form: 'tablet', strength: '50 mcg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Hifenac P', generic: 'Aceclofenac + Paracetamol', form: 'tablet', strength: '100/325 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Combiflam', generic: 'Ibuprofen + Paracetamol', form: 'tablet', strength: '400/325 mg', defaultDose: '1 tablet', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Etoshine 90', generic: 'Etoricoxib', form: 'tablet', strength: '90 mg', defaultDose: '1 tablet', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Myoril 4', generic: 'Thiocolchicoside', form: 'capsule', strength: '4 mg', defaultDose: '1 capsule', defaultFrequency: '1-0-1'),
  DrugOption(name: 'Pregabid 75', generic: 'Pregabalin', form: 'capsule', strength: '75 mg', defaultDose: '1 capsule', defaultFrequency: '0-0-1'),
  DrugOption(name: 'Nurokind OD', generic: 'Methylcobalamin', form: 'tablet', strength: '1500 mcg', defaultDose: '1 tablet', defaultFrequency: '1-0-0'),
  DrugOption(name: 'Shelcal 500', generic: 'Calcium + Vitamin D3', form: 'tablet', strength: '500 mg', defaultDose: '1 tablet', defaultFrequency: '0-1-0'),
  DrugOption(name: 'Volini Gel', generic: 'Diclofenac', form: 'gel', strength: '1%', defaultDose: 'Local application', defaultFrequency: '1-0-1'),
];

const commonTests = <TestOption>[
  TestOption(name: 'Complete blood count (CBC)', type: 'lab'),
  TestOption(name: 'ESR', type: 'lab'),
  TestOption(name: 'C-reactive protein (CRP)', type: 'lab'),
  TestOption(name: 'Blood sugar — fasting', type: 'lab'),
  TestOption(name: 'Blood sugar — post meal', type: 'lab'),
  TestOption(name: 'HbA1c', type: 'lab'),
  TestOption(name: 'Lipid profile', type: 'lab'),
  TestOption(name: 'Liver function test (LFT)', type: 'lab'),
  TestOption(name: 'Kidney function test (KFT)', type: 'lab'),
  TestOption(name: 'Serum electrolytes', type: 'lab'),
  TestOption(name: 'Thyroid profile (T3, T4, TSH)', type: 'lab'),
  TestOption(name: 'Urine routine and microscopy', type: 'lab'),
  TestOption(name: 'Urine culture', type: 'lab'),
  TestOption(name: 'Dengue NS1 antigen', type: 'lab'),
  TestOption(name: 'Widal test', type: 'lab'),
  TestOption(name: 'Malaria antigen', type: 'lab'),
  TestOption(name: 'Vitamin D (25-OH)', type: 'lab'),
  TestOption(name: 'Vitamin B12', type: 'lab'),
  TestOption(name: 'Serum uric acid', type: 'lab'),
  TestOption(name: 'X-ray chest PA view', type: 'radiology'),
  TestOption(name: 'X-ray both knees', type: 'radiology'),
  TestOption(name: 'X-ray LS spine', type: 'radiology'),
  TestOption(name: 'X-ray cervical spine', type: 'radiology'),
  TestOption(name: 'X-ray ankle', type: 'radiology'),
  TestOption(name: 'USG abdomen', type: 'radiology'),
];

/// Shown as one-tap test chips when the price list has nothing better.
const quickTestNames = ['CBC', 'HbA1c', 'Lipid profile', 'LFT', 'KFT', 'Urine routine', 'Thyroid', 'Dengue NS1', 'X-ray chest'];

const commonDiagnoses = <DiagnosisOption>[
  DiagnosisOption('Acute upper respiratory tract infection', 'J06.9'),
  DiagnosisOption('Viral fever', 'B34.9'),
  DiagnosisOption('Acute pharyngitis', 'J02.9'),
  DiagnosisOption('Acute bronchitis', 'J20.9'),
  DiagnosisOption('Allergic rhinitis', 'J30.4'),
  DiagnosisOption('Bronchial asthma', 'J45.9'),
  DiagnosisOption('Acute gastritis', 'K29.1'),
  DiagnosisOption('Gastro-oesophageal reflux disease', 'K21.9'),
  DiagnosisOption('Acute gastroenteritis', 'A09'),
  DiagnosisOption('Essential hypertension', 'I10'),
  DiagnosisOption('Type 2 diabetes mellitus', 'E11.9'),
  DiagnosisOption('Dyslipidaemia', 'E78.5'),
  DiagnosisOption('Hypothyroidism', 'E03.9'),
  DiagnosisOption('Urinary tract infection', 'N39.0'),
  DiagnosisOption('Migraine', 'G43.9'),
  DiagnosisOption('Iron deficiency anaemia', 'D50.9'),
  DiagnosisOption('Dengue fever', 'A90'),
  DiagnosisOption('Typhoid fever', 'A01.0'),
  DiagnosisOption('Acute otitis media', 'H66.9'),
  DiagnosisOption('Osteoarthritis of knee', 'M17.9'),
  DiagnosisOption('Low back pain', 'M54.5'),
  DiagnosisOption('Cervical spondylosis', 'M47.8'),
  DiagnosisOption('Frozen shoulder', 'M75.0'),
  DiagnosisOption('Ankle sprain', 'S93.4'),
  DiagnosisOption('Plantar fasciitis', 'M72.2'),
  DiagnosisOption('Vitamin D deficiency', 'E55.9'),
];

enum Specialty { general, paediatrics, orthopaedics }

Specialty specialtyOf(String? department) {
  final d = (department ?? '').toLowerCase();
  // "Orthopaedics" contains "paed", so check it first.
  if (d.contains('ortho') || d.contains('bone')) return Specialty.orthopaedics;
  if (d.contains('paed') || d.contains('pediat') || d.contains('child')) return Specialty.paediatrics;
  return Specialty.general;
}

abstract final class Phrases {
  static List<String> complaints(Specialty s) => switch (s) {
        Specialty.paediatrics => const [
            'Fever', 'Cough', 'Cold', 'Loose motions', 'Vomiting', 'Not feeding well', 'Ear pain', 'Rash',
            'Noisy breathing', 'since 2 days', 'since 1 week',
          ],
        Specialty.orthopaedics => const [
            'Knee pain', 'Low back pain', 'Neck pain', 'Shoulder pain', 'Swelling', 'Injury / fall', 'Stiffness',
            'since 1 week', 'since 3 months',
          ],
        Specialty.general => const [
            'Fever', 'Cough', 'Cold', 'Headache', 'Body ache', 'Sore throat', 'Acidity', 'Abdominal pain',
            'Loose motions', 'Burning urine', 'Giddiness', 'Breathlessness', 'Routine follow-up', 'since 2 days',
            'since 1 week',
          ],
      };

  static List<String> history(Specialty s) => switch (s) {
        Specialty.paediatrics => const [
            'Immunisation up to date', 'Feeding well', 'Passing urine normally', 'No similar illness in family',
            'No fever', 'Taking paracetamol at home',
          ],
        Specialty.orthopaedics => const [
            'No history of injury', 'Pain worse on climbing stairs', 'Morning stiffness', 'No radiation to legs',
            'No bladder or bowel complaints', 'Known diabetic', 'Known hypertensive',
          ],
        Specialty.general => const [
            'No known comorbidities', 'Known diabetic', 'Known hypertensive', 'On regular medicines',
            'Compliant with medicines', 'No travel history', 'Taking paracetamol at home',
          ],
      };

  static List<String> examination(Specialty s) => switch (s) {
        Specialty.paediatrics => const [
            'Active, playful', 'Throat congested', 'Chest clear', 'No wheeze', 'Ears normal', 'Mild dehydration',
            'No pallor / icterus',
          ],
        Specialty.orthopaedics => const [
            'Tenderness present', 'Crepitus present', 'Range of movement restricted', 'No swelling', 'SLR negative',
            'Distal neurovascular status normal', 'Power normal',
          ],
        Specialty.general => const [
            'Conscious, oriented', 'Afebrile', 'Throat congested', 'Chest clear', 'CVS: S1 S2 normal',
            'P/A soft, non-tender', 'Epigastric tenderness', 'No pallor / icterus', 'No pedal oedema',
          ],
      };

  static List<String> advice(Specialty s) => switch (s) {
        Specialty.paediatrics => const [
            'Plenty of fluids', 'ORS after every loose stool', 'Tepid sponging for fever', 'Steam inhalation',
            'Return at once if breathing fast or not feeding',
          ],
        Specialty.orthopaedics => const [
            'Hot fomentation twice a day', 'Quadriceps exercises', 'Avoid lifting heavy weights', 'Ice and elevation',
            'Reduce weight', 'Physiotherapy',
          ],
        Specialty.general => const [
            'Plenty of oral fluids', 'Rest for 3 days', 'Steam inhalation', 'Salt-restricted diet', 'Diabetic diet',
            'Avoid spicy and oily food', 'Walk 30 minutes daily', 'Review with reports',
          ],
      };
}

/// The standard test list a new hospital starts with: prices (core
/// `services`) and lab_tests with parameters and adult reference ranges.
library;

import 'package:kendra_hms/core/core.dart';

import 'lab_rules.dart';
import 'lab_schema.dart';

class LabTestDef {
  const LabTestDef(this.code, this.name, this.department, this.sampleType, this.container, this.tatMinutes,
      this.rupees, this.params);
  final String code;
  final String name;
  final String department;
  final String sampleType;
  final String container;
  final int tatMinutes;
  final int rupees;
  final List<LabParam> params;
}

const _edta = 'EDTA (lavender top)';
const _sst = 'Plain / SST (yellow top)';
const _fluoride = 'Fluoride (grey top)';
const _citrate = 'Citrate (light blue top)';
const _urine = 'Sterile urine container';

LabParam _n(String key, String name, String unit, double? low, double? high,
        {String short = '', double? fLow, double? fHigh, double? cLow, double? cHigh, int dec = 0, String ref = ''}) =>
    LabParam(
      key: key,
      name: name,
      short: short,
      unit: unit,
      low: low,
      high: high,
      femaleLow: fLow,
      femaleHigh: fHigh,
      criticalLow: cLow,
      criticalHigh: cHigh,
      decimals: dec,
      refText: ref,
    );

LabParam _c(String key, String name, List<String> choices, String normal, {String short = ''}) =>
    LabParam(key: key, name: name, short: short, kind: LabParam.choice, choices: choices, refText: normal);

LabParam _t(String key, String name, String ref) => LabParam(key: key, name: name, kind: LabParam.text, refText: ref);

const _reactive = ['Non-reactive', 'Reactive'];
const _posNeg = ['Negative', 'Positive'];
const _grades = ['Nil', 'Trace', '1+', '2+', '3+'];
const _titres = ['< 1:80', '1:80', '1:160', '1:320', '1:640'];
const _titreNormal = '< 1:80 / 1:80';

final defaultLabTests = <LabTestDef>[
  LabTestDef('LAB-CBC', 'Complete blood count (CBC)', 'haematology', 'Whole blood (EDTA)', _edta, 120, 350, [
    _n('hb', 'Haemoglobin', 'g/dL', 13.0, 17.0, short: 'Hb', fLow: 12.0, fHigh: 15.0, cLow: 7.0, cHigh: 20.0, dec: 1),
    _n('rbc', 'RBC count', 'million/µL', 4.5, 5.5, short: 'RBC', fLow: 3.8, fHigh: 4.8, dec: 2),
    _n('pcv', 'Haematocrit (PCV)', '%', 40, 50, short: 'PCV', fLow: 36, fHigh: 46, dec: 1),
    _n('mcv', 'MCV', 'fL', 83, 101, dec: 1),
    _n('mch', 'MCH', 'pg', 27, 32, dec: 1),
    _n('mchc', 'MCHC', 'g/dL', 31.5, 34.5, dec: 1),
    _n('wbc', 'Total WBC count', '/µL', 4000, 11000, short: 'WBC', cLow: 2000, cHigh: 30000),
    _n('neut', 'Neutrophils', '%', 40, 80),
    _n('lymph', 'Lymphocytes', '%', 20, 40),
    _n('mono', 'Monocytes', '%', 2, 10),
    _n('eos', 'Eosinophils', '%', 1, 6),
    _n('baso', 'Basophils', '%', 0, 2),
    _n('plt', 'Platelet count', '/µL', 150000, 410000, short: 'Platelets', cLow: 20000, cHigh: 1000000),
  ]),
  LabTestDef('LAB-ESR', 'ESR (Westergren)', 'haematology', 'Whole blood (EDTA)', _edta, 90, 150, [
    _n('esr', 'ESR', 'mm/1st hr', 0, 15, fHigh: 20),
  ]),
  LabTestDef('LAB-PTINR', 'Prothrombin time with INR', 'haematology', 'Citrated plasma', _citrate, 120, 450, [
    _n('pt', 'Prothrombin time', 'sec', 11.0, 13.5, short: 'PT', dec: 1),
    _n('inr', 'INR', '', 0.8, 1.2, cHigh: 5.0, dec: 2),
  ]),
  LabTestDef('LAB-BGRP', 'Blood group and Rh type', 'haematology', 'Whole blood (EDTA)', _edta, 60, 150, [
    _c('abo', 'ABO group', ['A', 'B', 'AB', 'O'], ''),
    _c('rh', 'Rh (D) type', ['Positive', 'Negative'], ''),
  ]),
  LabTestDef('LAB-MP', 'Malaria parasite (smear and rapid test)', 'haematology', 'Whole blood (EDTA)', _edta, 90, 250, [
    _c('mp_smear', 'Peripheral smear for MP', ['Not seen', 'P. vivax seen', 'P. falciparum seen', 'Mixed infection'], 'Not seen',
        short: 'MP smear'),
    _c('mp_rapid', 'Malaria antigen (rapid)', ['Negative', 'P. vivax positive', 'P. falciparum positive'], 'Negative',
        short: 'Malaria Ag'),
  ]),
  LabTestDef('LAB-FBS', 'Blood sugar, fasting (FBS)', 'biochemistry', 'Fluoride plasma', _fluoride, 60, 100, [
    _n('glu_f', 'Glucose, fasting', 'mg/dL', 70, 100, short: 'FBS', cLow: 40, cHigh: 450),
  ]),
  LabTestDef('LAB-PPBS', 'Blood sugar, post-prandial (PPBS)', 'biochemistry', 'Fluoride plasma', _fluoride, 60, 100, [
    _n('glu_pp', 'Glucose, 2 h after meal', 'mg/dL', 70, 140, short: 'PPBS', cLow: 40, cHigh: 450),
  ]),
  LabTestDef('LAB-RBS', 'Blood sugar, random (RBS)', 'biochemistry', 'Fluoride plasma', _fluoride, 60, 100, [
    _n('glu_r', 'Glucose, random', 'mg/dL', 70, 140, short: 'RBS', cLow: 40, cHigh: 450),
  ]),
  LabTestDef('LAB-HBA1C', 'Glycated haemoglobin (HbA1c)', 'biochemistry', 'Whole blood (EDTA)', _edta, 240, 550, [
    _n('hba1c', 'HbA1c', '%', 4.0, 5.6, dec: 1),
    _n('eag', 'Estimated average glucose', 'mg/dL', 68, 114, short: 'eAG'),
  ]),
  LabTestDef('LAB-LFT', 'Liver function tests (LFT)', 'biochemistry', 'Serum', _sst, 240, 650, [
    _n('tbil', 'Bilirubin, total', 'mg/dL', 0.3, 1.2, short: 'T. bil', dec: 2),
    _n('dbil', 'Bilirubin, direct', 'mg/dL', 0.0, 0.3, short: 'D. bil', dec: 2),
    _n('ibil', 'Bilirubin, indirect', 'mg/dL', 0.2, 0.9, short: 'I. bil', dec: 2),
    _n('ast', 'AST (SGOT)', 'U/L', 5, 40, short: 'SGOT'),
    _n('alt', 'ALT (SGPT)', 'U/L', 7, 45, short: 'SGPT'),
    _n('alp', 'Alkaline phosphatase', 'U/L', 44, 147, short: 'ALP'),
    _n('tp', 'Total protein', 'g/dL', 6.4, 8.3, short: 'T. protein', dec: 1),
    _n('alb', 'Albumin', 'g/dL', 3.5, 5.2, dec: 1),
    _n('glob', 'Globulin', 'g/dL', 2.0, 3.5, dec: 1),
    _n('ag', 'A/G ratio', '', 1.0, 2.1, dec: 2),
  ]),
  LabTestDef('LAB-KFT', 'Kidney function tests (KFT)', 'biochemistry', 'Serum', _sst, 240, 600, [
    _n('urea', 'Blood urea', 'mg/dL', 17, 43, short: 'Urea'),
    _n('creat', 'Creatinine', 'mg/dL', 0.7, 1.3, short: 'Creat', fLow: 0.6, fHigh: 1.1, dec: 2),
    _n('uric', 'Uric acid', 'mg/dL', 3.5, 7.2, short: 'Uric acid', fLow: 2.6, fHigh: 6.0, dec: 1),
    _n('ca', 'Calcium', 'mg/dL', 8.6, 10.3, short: 'Ca', cLow: 6.0, cHigh: 13.0, dec: 1),
  ]),
  LabTestDef('LAB-ELECTRO', 'Serum electrolytes (Na, K, Cl)', 'biochemistry', 'Serum', _sst, 120, 450, [
    _n('na', 'Sodium', 'mmol/L', 135, 145, short: 'Na+', cLow: 120, cHigh: 160),
    _n('k', 'Potassium', 'mmol/L', 3.5, 5.1, short: 'K+', cLow: 2.8, cHigh: 6.2, dec: 1),
    _n('cl', 'Chloride', 'mmol/L', 98, 107, short: 'Cl−'),
  ]),
  LabTestDef('LAB-LIPID', 'Lipid profile', 'biochemistry', 'Serum (12 h fasting)', _sst, 240, 600, [
    _n('tc', 'Total cholesterol', 'mg/dL', null, 200, short: 'Cholesterol'),
    _n('tg', 'Triglycerides', 'mg/dL', null, 150, short: 'TG'),
    _n('hdl', 'HDL cholesterol', 'mg/dL', 40, null, short: 'HDL'),
    _n('ldl', 'LDL cholesterol', 'mg/dL', null, 130, short: 'LDL', ref: '< 100 optimal, 100–129 near optimal'),
    _n('vldl', 'VLDL cholesterol', 'mg/dL', 5, 40, short: 'VLDL'),
    _n('tc_hdl', 'Total cholesterol / HDL ratio', '', null, 5.0, short: 'TC/HDL', dec: 1),
  ]),
  LabTestDef('LAB-TFT', 'Thyroid function tests (T3, T4, TSH)', 'biochemistry', 'Serum', _sst, 360, 550, [
    _n('t3', 'Total T3', 'ng/dL', 80, 200, short: 'T3'),
    _n('t4', 'Total T4', 'µg/dL', 5.1, 14.1, short: 'T4', dec: 1),
    _n('tsh', 'TSH', 'µIU/mL', 0.27, 4.20, dec: 2),
  ]),
  LabTestDef('LAB-TSH', 'TSH (ultrasensitive)', 'biochemistry', 'Serum', _sst, 360, 350, [
    _n('tsh', 'TSH', 'µIU/mL', 0.27, 4.20, dec: 2),
  ]),
  LabTestDef('LAB-URINE-R', 'Urine routine and microscopy', 'clinical_pathology', 'Urine (midstream)', _urine, 90, 200, [
    _c('colour', 'Colour', ['Pale yellow', 'Yellow', 'Dark yellow', 'Red', 'Brown'], 'Pale yellow / Yellow'),
    _c('appearance', 'Appearance', ['Clear', 'Slightly turbid', 'Turbid'], 'Clear'),
    _n('sg', 'Specific gravity', '', 1.005, 1.030, short: 'Sp. gr.', dec: 3),
    _n('ph', 'pH', '', 5.0, 8.0, dec: 1),
    _c('protein', 'Protein (albumin)', _grades, 'Nil', short: 'Urine protein'),
    _c('sugar', 'Sugar', _grades, 'Nil', short: 'Urine sugar'),
    _c('ketones', 'Ketone bodies', ['Absent', 'Present'], 'Absent', short: 'Ketones'),
    _n('pus', 'Pus cells', '/hpf', 0, 5, short: 'Pus cells'),
    _n('rbc_u', 'Red blood cells', '/hpf', 0, 2, short: 'Urine RBC'),
    _n('epi', 'Epithelial cells', '/hpf', 0, 5, short: 'Epithelial'),
    _t('casts', 'Casts', 'Nil'),
    _t('crystals', 'Crystals', 'Nil'),
  ]),
  LabTestDef('LAB-CRP', 'C-reactive protein (CRP), quantitative', 'biochemistry', 'Serum', _sst, 180, 450, [
    _n('crp', 'C-reactive protein', 'mg/L', null, 6.0, short: 'CRP', dec: 1),
  ]),
  LabTestDef('LAB-DENGUE-NS1', 'Dengue NS1 antigen', 'serology', 'Serum', _sst, 180, 600, [
    _c('ns1', 'Dengue NS1 antigen', _posNeg, 'Negative', short: 'Dengue NS1'),
  ]),
  LabTestDef('LAB-DENGUE-IGM', 'Dengue IgM antibody', 'serology', 'Serum', _sst, 240, 650, [
    _c('dengue_igm', 'Dengue IgM antibody', ['Negative', 'Equivocal', 'Positive'], 'Negative', short: 'Dengue IgM'),
  ]),
  LabTestDef('LAB-WIDAL', 'Widal test (slide)', 'serology', 'Serum', _sst, 240, 250, [
    _c('to', 'S. typhi O', _titres, _titreNormal, short: 'Typhi O'),
    _c('th', 'S. typhi H', _titres, _titreNormal, short: 'Typhi H'),
    _c('ah', 'S. paratyphi AH', _titres, _titreNormal, short: 'Paratyphi AH'),
    _c('bh', 'S. paratyphi BH', _titres, _titreNormal, short: 'Paratyphi BH'),
  ]),
  LabTestDef('LAB-HIV', 'HIV 1 and 2 antibodies', 'serology', 'Serum', _sst, 180, 400, [
    _c('hiv', 'HIV 1 and 2 antibodies', _reactive, 'Non-reactive', short: 'HIV'),
  ]),
  LabTestDef('LAB-HBSAG', 'Hepatitis B surface antigen (HBsAg)', 'serology', 'Serum', _sst, 180, 350, [
    _c('hbsag', 'HBsAg', _reactive, 'Non-reactive'),
  ]),
  LabTestDef('LAB-HCV', 'Hepatitis C antibody (anti-HCV)', 'serology', 'Serum', _sst, 240, 600, [
    _c('hcv', 'Anti-HCV antibody', _reactive, 'Non-reactive', short: 'Anti-HCV'),
  ]),
  LabTestDef('LAB-VITD', 'Vitamin D (25-hydroxy)', 'biochemistry', 'Serum', _sst, 1440, 1400, [
    _n('vitd', '25-OH vitamin D', 'ng/mL', 30, 100, short: 'Vit D', dec: 1,
        ref: '30 – 100 (deficient < 20, insufficient 20–29)'),
  ]),
  LabTestDef('LAB-B12', 'Vitamin B12', 'biochemistry', 'Serum', _sst, 1440, 1000, [
    _n('b12', 'Vitamin B12', 'pg/mL', 211, 911, short: 'B12'),
  ]),
];

/// One-tap groups on the order screen.
const labPanels = <(String, List<String>)>[
  ('Fever panel', ['LAB-CBC', 'LAB-MP', 'LAB-DENGUE-NS1', 'LAB-WIDAL', 'LAB-CRP']),
  ('Diabetes', ['LAB-FBS', 'LAB-PPBS', 'LAB-HBA1C']),
  ('Health check', ['LAB-CBC', 'LAB-LFT', 'LAB-KFT', 'LAB-LIPID', 'LAB-FBS', 'LAB-TSH', 'LAB-URINE-R']),
  ('Pre-op', ['LAB-CBC', 'LAB-PTINR', 'LAB-BGRP', 'LAB-RBS', 'LAB-HIV', 'LAB-HBSAG', 'LAB-HCV']),
  ('Antenatal', ['LAB-CBC', 'LAB-BGRP', 'LAB-TSH', 'LAB-RBS', 'LAB-URINE-R', 'LAB-HIV', 'LAB-HBSAG']),
  ('Kidney', ['LAB-KFT', 'LAB-ELECTRO', 'LAB-URINE-R']),
];

/// Creates the standard tests and their prices. Codes that already exist
/// (in either table) are left alone, so a hospital's own prices survive.
Future<void> seedDefaultLabTests(Db db) async {
  final codes = defaultLabTests.map((t) => t.code).toList();
  final haveServices = {
    for (final s in await db.query(Query(Col.services).isIn('code', codes).withArchived().take(200))) s.str('code'),
  };
  final haveTests = {
    for (final t in await db.query(Query(LabCol.tests).isIn('code', codes).withArchived().take(200))) t.str('code'),
  };
  await db.batch([
    for (final t in defaultLabTests) ...[
      if (!haveServices.contains(t.code))
        InsertOp(Col.services, {
          'code': t.code,
          'name': t.name,
          'category': Vals.lab,
          'price_paise': t.rupees * 100,
          'department': departmentLabel(t.department),
          'active': true,
          'tax_percent': 0.0,
        }),
      if (!haveTests.contains(t.code))
        InsertOp(LabCol.tests, {
          'code': t.code,
          'name': t.name,
          'department': t.department,
          'sample_type': t.sampleType,
          'container': t.container,
          'tat_minutes': t.tatMinutes,
          'parameters': [for (final p in t.params) p.toJson()],
          'active': true,
        }),
    ],
  ]);
}

/// Clinical rules with no Flutter and no database, so they are easy to test:
/// vitals thresholds, BMI, prescription quantities and allergy matching.
library;

import 'dart:math' as math;

enum VitalLevel { normal, abnormal, critical }

/// The vitals keys stored in `consultations.vitals`.
abstract final class VitalKeys {
  static const bpSys = 'bp_sys';
  static const bpDia = 'bp_dia';
  static const pulse = 'pulse';
  static const tempC = 'temp_c';
  static const spo2 = 'spo2';
  static const rr = 'rr';
  static const weightKg = 'weight_kg';
  static const heightCm = 'height_cm';
  static const bmi = 'bmi';
  static const grbs = 'grbs';

  static const all = [bpSys, bpDia, pulse, tempC, spo2, rr, weightKg, heightCm, bmi, grbs];
}

abstract final class Vitals {
  static num? value(Map<String, Object?> v, String key) {
    final x = v[key];
    if (x is num) return x;
    if (x is String) return num.tryParse(x.trim());
    return null;
  }

  /// "37.0" → "37", "37.25" → "37.3".
  static String fmt(num? n) {
    if (n == null) return '';
    if (n == n.roundToDouble()) return n.round().toString();
    return n.toStringAsFixed(1);
  }

  static double? bmi(num? weightKg, num? heightCm) {
    if (weightKg == null || heightCm == null || weightKg <= 0 || heightCm < 30) return null;
    final m = heightCm / 100;
    return double.parse((weightKg / (m * m)).toStringAsFixed(1));
  }

  /// °F typed into a °C box is converted (anything above 45 is °F).
  static double? tempToC(num? typed) {
    if (typed == null) return null;
    if (typed > 45) return double.parse(((typed - 32) * 5 / 9).toStringAsFixed(1));
    return typed.toDouble();
  }

  /// Parses "120/80", "120 / 80" or "120-80".
  static (int, int)? parseBp(String s) {
    final m = RegExp(r'^\s*(\d{2,3})\s*[/\-\\ ]\s*(\d{2,3})\s*$').firstMatch(s);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  /// Drops empty values and fills in BMI.
  static Map<String, Object?> clean(Map<String, Object?> v) {
    final out = <String, Object?>{};
    for (final k in VitalKeys.all) {
      final n = value(v, k);
      if (n != null) out[k] = n;
    }
    final b = bmi(value(out, VitalKeys.weightKg), value(out, VitalKeys.heightCm));
    if (b != null) {
      out[VitalKeys.bmi] = b;
    } else {
      out.remove(VitalKeys.bmi);
    }
    return out;
  }

  /// How worrying one reading is. Critical limits are the ones the
  /// critical-vitals agent uses.
  static VitalLevel level(String key, num? n) {
    if (n == null) return VitalLevel.normal;
    switch (key) {
      case VitalKeys.spo2:
        if (n < 90) return VitalLevel.critical;
        if (n < 95) return VitalLevel.abnormal;
      case VitalKeys.bpSys:
        if (n >= 180 || n <= 90) return VitalLevel.critical;
        if (n >= 140 || n < 100) return VitalLevel.abnormal;
      case VitalKeys.bpDia:
        if (n >= 120) return VitalLevel.critical;
        if (n >= 90 || n < 60) return VitalLevel.abnormal;
      case VitalKeys.pulse:
        if (n > 130 || n < 45) return VitalLevel.critical;
        if (n > 100 || n < 60) return VitalLevel.abnormal;
      case VitalKeys.tempC:
        if (n >= 39.5) return VitalLevel.critical;
        if (n >= 37.8 || n < 35.5) return VitalLevel.abnormal;
      case VitalKeys.rr:
        if (n > 22 || n < 10) return VitalLevel.abnormal;
      case VitalKeys.bmi:
        if (n >= 25 || n < 18.5) return VitalLevel.abnormal;
      case VitalKeys.grbs:
        if (n > 200 || n < 70) return VitalLevel.abnormal;
    }
    return VitalLevel.normal;
  }

  static VitalLevel bpLevel(Map<String, Object?> v) {
    final a = level(VitalKeys.bpSys, value(v, VitalKeys.bpSys));
    final b = level(VitalKeys.bpDia, value(v, VitalKeys.bpDia));
    return a.index >= b.index ? a : b;
  }

  /// Readings at or past the critical limits, e.g. ["SpO2 88%", "BP 184/96"].
  static List<String> critical(Map<String, Object?> v) {
    final out = <String>[];
    final spo2 = value(v, VitalKeys.spo2);
    if (level(VitalKeys.spo2, spo2) == VitalLevel.critical) out.add('SpO2 ${fmt(spo2)}%');
    if (bpLevel(v) == VitalLevel.critical) out.add('BP ${bpText(v)}');
    final pulse = value(v, VitalKeys.pulse);
    if (level(VitalKeys.pulse, pulse) == VitalLevel.critical) out.add('Pulse ${fmt(pulse)}/min');
    final t = value(v, VitalKeys.tempC);
    if (level(VitalKeys.tempC, t) == VitalLevel.critical) out.add('Temp ${fmt(t)} °C');
    return out;
  }

  static String bpText(Map<String, Object?> v) {
    final s = value(v, VitalKeys.bpSys);
    final d = value(v, VitalKeys.bpDia);
    if (s == null && d == null) return '';
    return '${fmt(s ?? 0)}/${fmt(d ?? 0)}';
  }

  /// One line for lists: "BP 120/80 · P 82 · T 37 °C · SpO2 98% · Wt 24 kg".
  static String summary(Map<String, Object?> v, {bool long = false}) {
    final parts = <String>[];
    final bp = bpText(v);
    if (bp.isNotEmpty) parts.add('BP $bp');
    void add(String key, String short, String label, String unit) {
      final n = value(v, key);
      if (n != null) parts.add('${long ? label : short} ${fmt(n)}$unit');
    }

    add(VitalKeys.pulse, 'P', 'Pulse', long ? '/min' : '');
    add(VitalKeys.tempC, 'T', 'Temp', ' °C');
    add(VitalKeys.spo2, 'SpO2', 'SpO2', '%');
    add(VitalKeys.rr, 'RR', 'RR', long ? '/min' : '');
    add(VitalKeys.weightKg, 'Wt', 'Weight', ' kg');
    if (long) add(VitalKeys.heightCm, 'Ht', 'Height', ' cm');
    add(VitalKeys.bmi, 'BMI', 'BMI', '');
    add(VitalKeys.grbs, 'Sugar', 'GRBS', long ? ' mg/dL' : '');
    return parts.join(' · ');
  }
}

/// How a medicine is dispensed: counted units (tablets) or whole packs (a
/// bottle of syrup, a tube of gel).
enum DispenseKind { unit, pack }

abstract final class Rx {
  static const frequencies = ['1-0-1', '1-0-0', '0-0-1', '1-1-1', 'SOS'];
  static const durations = [3, 5, 7, 14, 30];
  static const instructions = ['After food', 'Before food', 'At bedtime', 'Empty stomach'];

  static const _packWords = [
    'syrup', 'syp', 'susp', 'suspension', 'drops', 'drop', 'gel', 'cream', 'ointment', 'oint', 'spray', 'inhaler',
    'lotion', 'gargle', 'solution', 'nebul', 'respules', 'rotacap',
  ];

  /// Form from the medicine master, or guessed from the name.
  static String formOf(String? form, String name) {
    if (form != null && form.trim().isNotEmpty) return form.trim().toLowerCase();
    final n = name.toLowerCase();
    if (RegExp(r'\b(syrup|syp|susp|suspension)\b').hasMatch(n)) return 'syrup';
    if (RegExp(r'\bdrops?\b').hasMatch(n)) return 'drops';
    if (RegExp(r'\b(gel|cream|ointment|oint|lotion)\b').hasMatch(n)) return 'ointment';
    if (RegExp(r'\b(spray)\b').hasMatch(n)) return 'spray';
    if (RegExp(r'\b(inhaler|rotacap)\b').hasMatch(n)) return 'inhaler';
    if (RegExp(r'\b(inj|injection)\b').hasMatch(n)) return 'injection';
    if (RegExp(r'\b(cap|capsule)\b').hasMatch(n)) return 'capsule';
    if (RegExp(r'\b(sachet|ors|granules|powder)\b').hasMatch(n)) return 'sachet';
    return 'tablet';
  }

  static DispenseKind kindOf(String form) =>
      _packWords.any(form.toLowerCase().contains) ? DispenseKind.pack : DispenseKind.unit;

  static String defaultDose(String form) => switch (form) {
        'capsule' => '1 capsule',
        'syrup' => '5 ml',
        'drops' => '2 drops',
        'ointment' || 'gel' || 'cream' => 'Local application',
        'spray' => '2 puffs',
        'inhaler' => '2 puffs',
        'sachet' => '1 sachet',
        'injection' => '1 injection',
        _ => '1 tablet',
      };

  static String defaultRoute(String form, String name) {
    final n = name.toLowerCase();
    if (n.contains('nasal') || n.contains('naso')) return 'Nasal';
    if (n.contains('eye')) return 'Eye';
    if (n.contains('ear')) return 'Ear';
    if (n.contains('gargle')) return 'Gargle';
    return switch (form) {
      'ointment' || 'gel' || 'cream' || 'lotion' => 'Local',
      'spray' => 'Nasal',
      'inhaler' => 'Inhalation',
      'injection' => 'IM',
      _ => 'Oral',
    };
  }

  /// Doses per day: "1-0-1" → 2, "1-1-1" → 3, "½-0-½" → 1, "BD" → 2.
  /// Null for SOS (as needed) or anything we can't read.
  static double? perDay(String frequency) {
    final f = frequency.trim().toUpperCase();
    if (f.isEmpty) return null;
    const named = {'OD': 1, 'HS': 1, 'BD': 2, 'BID': 2, 'TDS': 3, 'TID': 3, 'QID': 4, 'QDS': 4, 'STAT': 1, 'ONCE': 1};
    if (named.containsKey(f)) return named[f]!.toDouble();
    final parts = f.split(RegExp(r'\s*-\s*'));
    if (parts.length < 2) return null;
    var sum = 0.0;
    for (final p in parts) {
      final v = switch (p) { '½' => 0.5, '¼' => 0.25, '¾' => 0.75, _ => double.tryParse(p) };
      if (v == null) return null;
      sum += v;
    }
    return sum;
  }

  static bool isSos(String frequency) {
    final f = frequency.trim().toUpperCase();
    return f.startsWith('SOS') || f == 'PRN' || f.contains('AS NEEDED');
  }

  /// Units per dose from "1 tablet", "2 tabs", "½ tablet".
  static double doseUnits(String? dose) {
    final d = (dose ?? '').trim();
    if (d.startsWith('½')) return 0.5;
    final m = RegExp(r'^(\d+(?:\.\d+)?)').firstMatch(d);
    return m == null ? 1 : double.parse(m.group(1)!);
  }

  /// How many to dispense. Packs (syrups, gels) are 1; tablets are
  /// doses per day × days × units per dose; SOS is one a day (3–10).
  static int? quantity({required String frequency, int? days, String? form, String? dose, String name = ''}) {
    final f = formOf(form, name);
    if (kindOf(f) == DispenseKind.pack) return 1;
    final units = doseUnits(dose);
    if (isSos(frequency)) {
      final d = (days == null || days <= 0) ? 5 : days;
      return (d.clamp(3, 10) * units).ceil();
    }
    final per = perDay(frequency);
    if (per == null || days == null || days <= 0) return null;
    return math.max(1, (per * days * units).ceil());
  }

  /// "1 tablet · 1-0-1 · 5 days · After food".
  static String line(Map<String, Object?> item, {bool withRoute = false}) {
    final days = item['duration_days'];
    return [
      item['dose'],
      item['frequency'],
      if (days is num && days > 0) plural(days.toInt(), 'day'),
      item['instructions'],
      if (withRoute) item['route'],
    ].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ');
  }

  static String plural(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';
}

class _AllergenClass {
  const _AllergenClass(this.keys, this.matches);
  final List<String> keys;
  final List<String> matches;
}

const _allergenClasses = [
  _AllergenClass(['penicillin', 'pencillin', 'amoxicillin', 'amoxycillin'],
      ['penicillin', 'cillin', 'amoxy', 'augmentin', 'clavam', 'moxikind']),
  _AllergenClass(['sulfa', 'sulpha', 'sulfonamide', 'sulphonamide'],
      ['sulfa', 'sulpha', 'sulfon', 'sulphon', 'cotrimoxazole', 'co-trimoxazole', 'bactrim', 'septran']),
  _AllergenClass(['nsaid', 'painkiller'], [
    'ibuprofen', 'diclofenac', 'aceclofenac', 'naproxen', 'aspirin', 'ketorolac', 'mefenamic', 'etoricoxib',
    'piroxicam', 'nimesulide', 'combiflam', 'hifenac', 'voveran', 'ecosprin',
  ]),
  _AllergenClass(['aspirin'], ['aspirin', 'ecosprin', 'acetylsalicylic']),
  _AllergenClass(['cephalosporin', 'cefixime', 'ceftriaxone', 'cefuroxime'], ['cef', 'ceph']),
  _AllergenClass(['quinolone', 'ciprofloxacin', 'ofloxacin', 'levofloxacin'], ['floxacin']),
  _AllergenClass(['macrolide', 'azithromycin', 'erythromycin', 'clarithromycin'], ['thromycin', 'azithral', 'azee']),
  _AllergenClass(['paracetamol', 'acetaminophen'], ['paracetamol', 'acetaminophen', 'dolo', 'calpol', 'crocin']),
];

const _fillerWords = {
  'allergy', 'allergic', 'allergies', 'to', 'drug', 'drugs', 'tablet', 'tablets', 'medicine', 'medicines', 'h/o',
  'history', 'of', 'known', 'group', 'antibiotic', 'antibiotics', 'reaction', 'rash', 'with', 'the', 'a', 'an',
};

/// Reads a free-text allergies field and decides whether a medicine may be
/// one of them. Knows drug classes, so "Penicillin" catches Amoxicillin and
/// "Sulfa drugs" catches Cotrimoxazole.
abstract final class Allergy {
  static bool isNone(String allergies) {
    final a = allergies.trim().toLowerCase();
    return a.isEmpty ||
        RegExp(r'^(no|nil|none|nkda|nka|not known|no known( drug)? allerg(y|ies)|na|n/a|-)\.?$').hasMatch(a);
  }

  /// The allergy (as written) that [drugName] / [genericName] matches, or null.
  static String? match(String? allergies, {required String drugName, String? genericName}) {
    final text = allergies ?? '';
    if (isNone(text)) return null;
    final hay = '$drugName ${genericName ?? ''}'.toLowerCase();
    for (final raw in text.split(RegExp(r'[,;/\n]|\band\b|&'))) {
      final piece = raw.trim();
      if (piece.isEmpty || isNone(piece)) continue;
      final lower = piece.toLowerCase();
      var matched = false;
      for (final cls in _allergenClasses) {
        if (cls.keys.any(lower.contains)) {
          matched = true;
          if (cls.matches.any(hay.contains) || cls.keys.any(hay.contains)) return piece;
        }
      }
      if (matched) continue;
      final words = lower
          .split(RegExp(r'[^a-z0-9\-]+'))
          .where((w) => w.length >= 4 && !_fillerWords.contains(w))
          .toList();
      for (final w in words) {
        if (hay.contains(w)) return piece;
      }
    }
    return null;
  }
}

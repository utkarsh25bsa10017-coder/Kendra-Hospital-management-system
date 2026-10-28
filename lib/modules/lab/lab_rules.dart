/// Lab rules that need no database: reference ranges, flags, report
/// summaries, turnaround targets and sample numbers.
library;

import 'dart:math' as math;

import 'package:kendra_hms/core/core.dart';

import 'lab_schema.dart';

/// Result flags stored in lab_results.values[].flag.
abstract final class LabFlag {
  static const none = '';
  static const low = 'L';
  static const high = 'H';
  static const criticalLow = 'LL';
  static const criticalHigh = 'HH';

  /// A choice result that is not the normal one (Positive, Reactive...).
  static const abnormal = 'A';

  static bool isCritical(String? f) => f == criticalLow || f == criticalHigh;
  static bool isAbnormal(String? f) => f != null && f.isNotEmpty;

  static String label(String? f) => switch (f) {
        low => 'Low',
        high => 'High',
        criticalLow => 'Critical low',
        criticalHigh => 'Critical high',
        abnormal => 'Abnormal',
        _ => '',
      };

  static Tone tone(String? f) => isCritical(f) ? Tone.danger : (isAbnormal(f) ? Tone.warning : Tone.neutral);
}

/// One measured parameter of a test (Haemoglobin in a CBC).
class LabParam {
  const LabParam({
    required this.key,
    required this.name,
    this.short = '',
    this.unit = '',
    this.low,
    this.high,
    this.femaleLow,
    this.femaleHigh,
    this.criticalLow,
    this.criticalHigh,
    this.refText = '',
    this.kind = numeric,
    this.choices = const [],
    this.decimals = 0,
  });

  static const numeric = 'numeric';
  static const choice = 'choice';
  static const text = 'text';
  static const kinds = [numeric, choice, text];

  final String key;
  final String name;

  /// Abbreviation used in summaries ("Hb", "K+").
  final String short;
  final String unit;
  final double? low;
  final double? high;

  /// Optional female range; the adult range applies when absent.
  final double? femaleLow;
  final double? femaleHigh;
  final double? criticalLow;
  final double? criticalHigh;

  /// Shown instead of the numeric range. For choices, the normal answer(s)
  /// separated by "/" (e.g. "Non-reactive"); empty means no choice is abnormal.
  final String refText;
  final String kind;
  final List<String> choices;
  final int decimals;

  bool get isNumeric => kind == numeric;
  bool get isChoice => kind == choice;
  String get label => short.isEmpty ? name : short;
  bool get hasCriticalLimits => criticalLow != null || criticalHigh != null;

  static double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

  factory LabParam.fromJson(Map<String, Object?> j) => LabParam(
        key: (j['key'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        short: (j['short'] as String?) ?? '',
        unit: (j['unit'] as String?) ?? '',
        low: _d(j['low']),
        high: _d(j['high']),
        femaleLow: _d(j['female_low']),
        femaleHigh: _d(j['female_high']),
        criticalLow: _d(j['critical_low']),
        criticalHigh: _d(j['critical_high']),
        refText: (j['ref_text'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? numeric,
        choices: (j['choices'] as List?)?.whereType<String>().toList() ?? const [],
        decimals: (j['decimals'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'name': name,
        if (short.isNotEmpty) 'short': short,
        'unit': unit,
        'low': low,
        'high': high,
        if (femaleLow != null) 'female_low': femaleLow,
        if (femaleHigh != null) 'female_high': femaleHigh,
        'critical_low': criticalLow,
        'critical_high': criticalHigh,
        'ref_text': refText,
        'kind': kind,
        'choices': choices,
        'decimals': decimals,
      };

  /// The normal range for this patient's sex.
  (double?, double?) rangeFor(String? sex) {
    if (sex == 'female' && (femaleLow != null || femaleHigh != null)) {
      return (femaleLow ?? low, femaleHigh ?? high);
    }
    return (low, high);
  }

  List<String> get normalChoices =>
      refText.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  double? parse(String raw) {
    final s = raw.replaceAll(',', '').trim();
    if (s.isEmpty) return null;
    final v = double.tryParse(s);
    return (v == null || v.isNaN || v.isInfinite) ? null : v;
  }

  /// 14200 → "14,200"; 9.8 with one decimal → "9.8".
  String format(num v) => decimals <= 0 ? formatNumber(v.round()) : v.toStringAsFixed(decimals);

  String _n(double v) => format(v);

  /// "13.0 – 17.0", "< 200", "> 40", or the reference text.
  String refLabel([String? sex]) {
    if (refText.isNotEmpty) return refText;
    if (!isNumeric) return '';
    final (lo, hi) = rangeFor(sex);
    if (lo != null && hi != null) return '${_n(lo)} – ${_n(hi)}';
    if (hi != null) return '< ${_n(hi)}';
    if (lo != null) return '> ${_n(lo)}';
    return '';
  }

  String get criticalLabel {
    final parts = [
      if (criticalLow != null) '< ${_n(criticalLow!)}',
      if (criticalHigh != null) '> ${_n(criticalHigh!)}',
    ];
    return parts.join(' or ');
  }

  /// The flag for a value as typed. Empty or unreadable values get no flag.
  String flagFor(String raw, {String? sex}) {
    final s = raw.trim();
    if (s.isEmpty) return LabFlag.none;
    if (isChoice) {
      final normal = normalChoices;
      if (normal.isEmpty) return LabFlag.none;
      return normal.any((n) => n.toLowerCase() == s.toLowerCase()) ? LabFlag.none : LabFlag.abnormal;
    }
    if (!isNumeric) return LabFlag.none;
    final v = parse(s);
    if (v == null) return LabFlag.none;
    if (criticalLow != null && v < criticalLow!) return LabFlag.criticalLow;
    if (criticalHigh != null && v > criticalHigh!) return LabFlag.criticalHigh;
    final (lo, hi) = rangeFor(sex);
    if (lo != null && v < lo) return LabFlag.low;
    if (hi != null && v > hi) return LabFlag.high;
    return LabFlag.none;
  }

  /// Problem with what was typed, or null when it is fine.
  String? problem(String raw) {
    if (!isNumeric || raw.trim().isEmpty) return null;
    return parse(raw) == null ? 'Enter a number' : null;
  }

  /// The stored form of one result value.
  Map<String, Object?> value(String raw, {String? sex}) {
    final s = raw.trim();
    final n = isNumeric ? parse(s) : null;
    return {
      'key': key,
      'name': name,
      'value': n != null ? format(n) : s,
      'numeric': n,
      'unit': unit,
      'flag': flagFor(s, sex: sex),
      'ref': refLabel(sex),
    };
  }
}

List<LabParam> paramsOf(Rec? test) =>
    test == null ? const [] : test.maps('parameters').map(LabParam.fromJson).toList();

/// Builds the values list for everything that was filled in.
List<Map<String, Object?>> buildValues(List<LabParam> params, Map<String, String> raw, {String? sex}) => [
      for (final p in params)
        if ((raw[p.key] ?? '').trim().isNotEmpty) p.value(raw[p.key]!, sex: sex),
    ];

bool anyCritical(List<Map<String, Object?>> values) => values.any((v) => LabFlag.isCritical(v['flag'] as String?));
bool anyAbnormal(List<Map<String, Object?>> values) => values.any((v) => LabFlag.isAbnormal(v['flag'] as String?));

/// "Hb 9.8 L, WBC 14,200 H" — the abnormal values, short enough for a
/// worklist row or the doctor's screen.
String resultSummary(List<LabParam> params, List<Map<String, Object?>> values, {int max = 4}) {
  final byKey = {for (final p in params) p.key: p};
  String label(Map<String, Object?> v) => byKey[v['key']]?.label ?? (v['name'] as String? ?? '');
  String one(Map<String, Object?> v, {bool withUnit = false}) {
    final flag = v['flag'] as String? ?? '';
    final isNum = v['numeric'] != null;
    final unit = withUnit && (v['unit'] as String? ?? '').isNotEmpty ? ' ${v['unit']}' : '';
    final f = (isNum && flag.isNotEmpty) ? ' $flag' : '';
    return '${label(v)} ${v['value']}$unit$f';
  }

  final flagged = values.where((v) => LabFlag.isAbnormal(v['flag'] as String?)).toList()
    ..sort((a, b) => (LabFlag.isCritical(b['flag'] as String?) ? 1 : 0) - (LabFlag.isCritical(a['flag'] as String?) ? 1 : 0));
  if (flagged.isNotEmpty) {
    final parts = flagged.take(max).map((v) => one(v)).toList();
    if (flagged.length > max) parts.add('+${flagged.length - max} more');
    return parts.join(', ');
  }
  if (values.length == 1) return one(values.first, withUnit: true);
  if (values.isEmpty) return '';
  return 'All values normal';
}

/// Short label for a stored value, using the test's parameter abbreviations.
String valueLabel(Map<String, Object?> v, List<LabParam> params) {
  for (final p in params) {
    if (p.key == v['key']) return p.label;
  }
  return v['name'] as String? ?? '';
}

/// "K+ 6.8, Na+ 118" — just the critical values.
String criticalText(List<Map<String, Object?>> values, List<LabParam> params) => values
    .where((v) => LabFlag.isCritical(v['flag'] as String?))
    .map((v) => '${valueLabel(v, params)} ${v['value']}')
    .join(', ');

// ------------------------------------------------------------ turnaround

/// Minutes allowed from order to verified report.
int targetMinutes(String? priority, int tatMinutes) =>
    priority == Priority.stat ? math.min(tatMinutes, 60) : tatMinutes;

DateTime dueAt(DateTime orderedAt, String? priority, int tatMinutes) =>
    orderedAt.add(Duration(minutes: targetMinutes(priority, tatMinutes)));

/// Default when a test has no turnaround set.
const defaultTatMinutes = 240;

// ------------------------------------------------------------ samples

String _two(int n) => n.toString().padLeft(2, '0');

/// Sequence name for one day's sample numbers, e.g. `sample:20261024`.
String sampleSequence(DateTime d) => 'sample:${d.year}${_two(d.month)}${_two(d.day)}';

/// S-261024-0042
String sampleIdFor(DateTime d, int n) => 'S-${_two(d.year % 100)}${_two(d.month)}${_two(d.day)}-${n.toString().padLeft(4, '0')}';

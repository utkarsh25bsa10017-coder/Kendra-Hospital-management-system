/// Formatting helpers (Indian number grouping, dates). No external packages.
library;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _groupIndian(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '${parts.join(',')},$last3';
}

/// ₹1,23,456.50 — money is stored as integer paise.
String formatMoney(int? paise, {bool symbol = true, bool alwaysDecimals = true}) {
  final p = paise ?? 0;
  final neg = p < 0;
  final abs = p.abs();
  final rupees = _groupIndian(abs ~/ 100);
  final frac = abs % 100;
  final dec = (alwaysDecimals || frac != 0) ? '.${frac.toString().padLeft(2, '0')}' : '';
  return '${neg ? '−' : ''}${symbol ? '₹' : ''}$rupees$dec';
}

/// Compact form for tiles: ₹950, ₹12.4K, ₹3.2L, ₹1.1Cr.
String formatMoneyShort(int? paise) {
  final r = (paise ?? 0) / 100;
  final neg = r < 0;
  final a = r.abs();
  String v;
  if (a >= 1e7) {
    v = '${_trim(a / 1e7)}Cr';
  } else if (a >= 1e5) {
    v = '${_trim(a / 1e5)}L';
  } else if (a >= 1e4) {
    v = '${_trim(a / 1e3)}K';
  } else {
    v = _groupIndian(a.round());
  }
  return '${neg ? '−' : ''}₹$v';
}

String _trim(double x) {
  final s = x.toStringAsFixed(x >= 100 ? 0 : 1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Parses "1,234.50", "₹ 1234" or "1234" into paise. Returns null if invalid.
int? parseMoney(String input) {
  final s = input.replaceAll(RegExp(r'[₹,\s]'), '');
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null || v.isNaN || v.isInfinite) return null;
  return (v * 100).round();
}

/// Rupees as a plain editable string ("1234.5" → "1234.50").
String moneyInput(int? paise) {
  if (paise == null) return '';
  final r = paise ~/ 100;
  final p = (paise % 100).abs();
  return p == 0 ? '$r' : '$r.${p.toString().padLeft(2, '0')}';
}

String formatNumber(num n) =>
    n is int || n == n.roundToDouble() ? _groupIndian(n.round()) : n.toStringAsFixed(1);

String formatDate(DateTime? d) => d == null ? '—' : '${d.day} ${_months[d.month - 1]} ${d.year}';

String formatDateShort(DateTime d) => '${d.day} ${_months[d.month - 1]}';

String formatWeekday(DateTime d) => _weekdays[d.weekday - 1];

String formatTime(DateTime? d) {
  if (d == null) return '—';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String formatDateTime(DateTime? d) => d == null ? '—' : '${formatDate(d)}, ${formatTime(d)}';

/// "just now", "5 min ago", "3 h ago", "yesterday", or a date.
String formatRelative(DateTime? d, {DateTime? now}) {
  if (d == null) return '—';
  final n = now ?? DateTime.now();
  final diff = n.difference(d);
  if (diff.isNegative) return formatDateTime(d);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && d.day == n.day) return '${diff.inHours} h ago';
  final yesterday = DateTime(n.year, n.month, n.day).subtract(const Duration(days: 1));
  if (!d.isBefore(yesterday)) return 'yesterday, ${formatTime(d)}';
  return formatDate(d);
}

/// "45 min", "2 h 10 min", "3 days".
String formatDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m min';
  }
  final days = d.inDays;
  return '$days day${days == 1 ? '' : 's'}';
}

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime endOfDay(DateTime d) => DateTime(d.year, d.month, d.day).add(const Duration(days: 1));
DateTime startOfMonth(DateTime d) => DateTime(d.year, d.month);

/// yyyy-MM-dd, matching AggQuery.groupByDay keys.
String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int ageInYears(DateTime dob, {DateTime? now}) {
  final n = now ?? DateTime.now();
  var a = n.year - dob.year;
  if (n.month < dob.month || (n.month == dob.month && n.day < dob.day)) a--;
  return a < 0 ? 0 : a;
}

/// "34 y", "8 mo", "12 d" — from date of birth, or a recorded age.
String ageLabel(DateTime? dob, int? ageYears) {
  if (dob != null) {
    final now = DateTime.now();
    final y = ageInYears(dob, now: now);
    if (y >= 1) return '$y y';
    final months = (now.year - dob.year) * 12 + now.month - dob.month - (now.day < dob.day ? 1 : 0);
    if (months >= 1) return '$months mo';
    return '${now.difference(dob).inDays} d';
  }
  if (ageYears != null) return '$ageYears y';
  return '—';
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && !p.endsWith('.')).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

String titleCase(String s) => s
    .replaceAll('_', ' ')
    .split(' ')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

String genderLabel(String? g) => switch (g) { 'male' => 'Male', 'female' => 'Female', 'other' => 'Other', _ => '—' };

String plural(int n, String word, [String? pluralWord]) => '$n ${n == 1 ? word : (pluralWord ?? '${word}s')}';

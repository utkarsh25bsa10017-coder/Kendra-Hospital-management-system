import 'package:kendra_hms/core/core.dart';

abstract final class DashboardPerms {
  static const view = 'dashboard.view';

  /// Declared by the Patients module. Front-desk staff with it see today's
  /// patient counts (never money) on their home screen.
  static const patientsView = 'patients.view';
}

/// Metric ids used by the drill-down screen.
abstract final class Metrics {
  static const patientsToday = 'patients_today';
  static const opdToday = 'opd_today';
  static const inpatients = 'inpatients';
  static const charges = 'charges';
  static const revenueToday = 'revenue_today';
  static const findings = 'findings';

  /// Metrics that show money need dashboard.view.
  static bool isFinancial(String metric) => metric == charges || metric == revenueToday;
}

/// The home screen's numbers, all computed from core contract tables.
class DashboardKpis {
  const DashboardKpis({
    required this.patientsToday,
    required this.opdToday,
    required this.inpatientsNow,
    required this.revenueTodayPaise,
    required this.chargesToday,
    required this.trend,
    required this.mix,
    required this.openFindings,
  });

  final int patientsToday;
  final int opdToday;
  final int inpatientsNow;

  /// Non-cancelled charges whose service date is today.
  final int revenueTodayPaise;
  final int chargesToday;

  /// Charges per service day for the last 14 days, oldest first.
  final List<(DateTime, int)> trend;

  /// Today's charges by category, largest first.
  final List<(String, int)> mix;

  /// Open findings by severity (empty when not asked for).
  final Map<String, int> openFindings;

  int get openFindingsTotal => openFindings.values.fold(0, (a, b) => a + b);
}

abstract final class DashboardMetrics {
  static const trendDays = 14;

  static Query patientsRegistered(DateTime day) =>
      const Query(Col.patients).between('created_at', startOfDay(day), endOfDay(day));

  static Query opdVisits(DateTime day) => const Query(Col.encounters)
      .eq('type', Vals.opd)
      .neq('status', Vals.cancelled)
      .between('started_at', startOfDay(day), endOfDay(day));

  static Query inpatients() => const Query(Col.encounters).eq('type', Vals.ipd).eq('status', Vals.open);

  /// Charges for services delivered in [from, to), cancelled ones left out.
  static Query charges(DateTime from, DateTime to, {String? category}) {
    var q = const Query(Col.charges).neq('status', Vals.cancelled).between('service_date', from, to);
    if (category != null) q = q.eq('category', category);
    return q;
  }

  static Future<DashboardKpis> load(ReadDb db, {DateTime? now, bool findings = false}) async {
    final n = now ?? DateTime.now();
    final today = startOfDay(n);
    final tomorrow = endOfDay(n);
    final from = today.subtract(const Duration(days: trendDays - 1));

    final todayCharges = charges(today, tomorrow);
    final byDay = await db.aggregate(AggQuery.of(charges(from, tomorrow), groupByDay: 'service_date', sums: ['amount_paise']));
    final dayTotals = {for (final r in byDay) r.key as String?: r.sum('amount_paise').toInt()};
    final byCategory = await db.aggregate(AggQuery.of(todayCharges, groupBy: 'category', sums: ['amount_paise']));
    final mix = [
      for (final r in byCategory)
        if (r.sum('amount_paise') != 0) ('${r.key ?? Vals.other}', r.sum('amount_paise').toInt()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    var open = <String, int>{};
    if (findings) {
      final rows = await db.aggregate(AggQuery.of(const Query(Col.findings).eq('status', 'open'), groupBy: 'severity'));
      open = {for (final r in rows) '${r.key}': r.count};
    }

    return DashboardKpis(
      patientsToday: await db.count(patientsRegistered(n)),
      opdToday: await db.count(opdVisits(n)),
      inpatientsNow: await db.count(inpatients()),
      revenueTodayPaise: (await db.sum(todayCharges, 'amount_paise')).toInt(),
      chargesToday: await db.count(todayCharges),
      trend: [
        for (var i = 0; i < trendDays; i++)
          (from.add(Duration(days: i)), dayTotals[dayKey(from.add(Duration(days: i)))] ?? 0),
      ],
      mix: mix,
      openFindings: open,
    );
  }

  static String categoryLabel(String c) => switch (c) {
        Vals.consultation => 'Consultations',
        Vals.lab => 'Lab tests',
        Vals.radiology => 'Radiology',
        Vals.pharmacy => 'Pharmacy',
        Vals.procedure => 'Procedures',
        Vals.bed => 'Bed charges',
        Vals.nursing => 'Nursing',
        Vals.other => 'Other',
        _ => c.isEmpty ? 'Other' : '${c[0].toUpperCase()}${c.substring(1).replaceAll('_', ' ')}',
      };

  // ------------------------------------------------------------ drill-down

  static const rowLimit = 500;

  /// The records behind a metric. [args] come from the route:
  /// `{metric: 'charges', day: 'yyyy-MM-dd' | days: 14, category: 'lab'}`,
  /// `{metric: 'opd_today'}`, `{metric: 'inpatients'}`, `{metric: 'patients_today'}`.
  static Future<Drilldown> drilldown(
    ReadDb db,
    Map<String, Object?> args, {
    DateTime? now,
    String Function(String moduleId)? moduleName,
  }) async {
    final n = now ?? DateTime.now();
    final metric = (args['metric'] as String?) ?? Metrics.revenueToday;
    return switch (metric) {
      Metrics.patientsToday => _patients(db, n),
      Metrics.opdToday => _opd(db, n),
      Metrics.inpatients => _inpatients(db, n),
      _ => _charges(db, args, n, moduleName ?? _titleCase),
    };
  }

  static String _titleCase(String s) => s.isEmpty ? '—' : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _patientLabel(Rec? p) => p == null ? 'Unknown patient' : p.str('full_name');

  static Future<Drilldown> _charges(ReadDb db, Map<String, Object?> args, DateTime n, String Function(String) moduleName) async {
    final dayArg = DateTime.tryParse((args['day'] as String?) ?? '');
    final days = (args['days'] as num?)?.toInt();
    final category = args['category'] as String?;
    final DateTime from;
    final DateTime to;
    final String when;
    if (days != null && days > 1) {
      from = startOfDay(n).subtract(Duration(days: days - 1));
      to = endOfDay(n);
      when = 'Last $days days';
    } else {
      final d = dayArg ?? n;
      from = startOfDay(d);
      to = endOfDay(d);
      when = startOfDay(d) == startOfDay(n) ? 'Today' : formatDate(d);
    }
    final q = charges(from, to, category: category);
    final count = await db.count(q);
    final total = (await db.sum(q, 'amount_paise')).toInt();
    final rows = await db.query(q.sort('service_date', desc: true).take(rowLimit));
    final patients = await db.byIds(Col.patients, [for (final c in rows) c.strOrNull('patient_id')]);
    final multiDay = to.difference(from).inDays > 1;
    return Drilldown(
      metric: Metrics.charges,
      title: category == null ? 'Services delivered' : categoryLabel(category),
      subtitle: '$when · ${plural(count, 'charge')}, cancelled ones left out',
      columns: const [
        DrillColumn('Patient', flex: 3),
        DrillColumn('Service', flex: 4),
        DrillColumn('Category', flex: 2),
        DrillColumn('From', flex: 2),
        DrillColumn('When', flex: 2),
        DrillColumn('Amount', flex: 2, numeric: true),
      ],
      rows: [
        for (final c in rows)
          () {
            final p = patients[c.strOrNull('patient_id')];
            final at = c.date('service_date');
            final whenText = at == null ? '—' : (multiDay ? formatDateTime(at) : formatTime(at));
            return DrillRow(
              id: c.id,
              title: c.str('description'),
              subtitle: [_patientLabel(p), categoryLabel(c.str('category')), moduleName(c.str('source_module')), whenText]
                  .join(' · '),
              cells: [
                p == null ? 'Unknown patient' : '${p.str('full_name')}\n${p.str('uhid')}',
                c.str('description'),
                categoryLabel(c.str('category')),
                moduleName(c.str('source_module')),
                whenText,
                formatMoney(c.integer('amount_paise')),
              ],
              amountPaise: c.integer('amount_paise'),
              patientId: c.strOrNull('patient_id'),
            );
          }(),
      ],
      count: count,
      totalPaise: total,
      noun: 'charge',
      truncated: count > rows.length,
    );
  }

  static Future<Drilldown> _opd(ReadDb db, DateTime n) async {
    final q = opdVisits(n);
    final count = await db.count(q);
    final rows = await db.query(q.sort('started_at').take(rowLimit));
    final patients = await db.byIds(Col.patients, [for (final e in rows) e.strOrNull('patient_id')]);
    final doctors = await db.byIds(Col.users, [for (final e in rows) e.strOrNull('doctor_id')]);
    String status(Rec e) => switch (e.str('queue_status')) {
          Vals.waiting => 'Waiting',
          Vals.withDoctor => 'With doctor',
          Vals.done => 'Seen',
          Vals.left => 'Left without being seen',
          _ => e.str('status') == Vals.closed ? 'Seen' : 'Open',
        };
    return Drilldown(
      metric: Metrics.opdToday,
      title: 'OPD visits today',
      subtitle: plural(count, 'visit'),
      columns: const [
        DrillColumn('Patient', flex: 3),
        DrillColumn('Doctor', flex: 3),
        DrillColumn('Department', flex: 2),
        DrillColumn('Started', flex: 2),
        DrillColumn('Status', flex: 2),
      ],
      rows: [
        for (final e in rows)
          DrillRow(
            id: e.id,
            title: _patientLabel(patients[e.strOrNull('patient_id')]),
            subtitle: [
              doctors[e.strOrNull('doctor_id')]?.str('display_name') ?? 'No doctor yet',
              formatTime(e.date('started_at')),
              status(e),
            ].join(' · '),
            cells: [
              () {
                final p = patients[e.strOrNull('patient_id')];
                return p == null ? 'Unknown patient' : '${p.str('full_name')}\n${p.str('uhid')}';
              }(),
              doctors[e.strOrNull('doctor_id')]?.str('display_name') ?? '—',
              e.str('department', '—'),
              formatTime(e.date('started_at')),
              status(e),
            ],
            patientId: e.strOrNull('patient_id'),
          ),
      ],
      count: count,
      noun: 'visit',
      truncated: count > rows.length,
    );
  }

  static Future<Drilldown> _inpatients(ReadDb db, DateTime n) async {
    final q = inpatients();
    final count = await db.count(q);
    final rows = await db.query(q.sort('started_at').take(rowLimit));
    final patients = await db.byIds(Col.patients, [for (final e in rows) e.strOrNull('patient_id')]);
    final doctors = await db.byIds(Col.users, [for (final e in rows) e.strOrNull('doctor_id')]);
    String stay(Rec e) {
      final s = e.date('started_at');
      if (s == null) return '—';
      final days = startOfDay(n).difference(startOfDay(s)).inDays;
      return days <= 0 ? 'Admitted today' : plural(days, 'day');
    }

    return Drilldown(
      metric: Metrics.inpatients,
      title: 'Inpatients now',
      subtitle: '${plural(count, 'patient')} admitted and not yet discharged',
      columns: const [
        DrillColumn('Patient', flex: 3),
        DrillColumn('Doctor', flex: 3),
        DrillColumn('Department', flex: 2),
        DrillColumn('Admitted', flex: 2),
        DrillColumn('Stay', flex: 2),
      ],
      rows: [
        for (final e in rows)
          DrillRow(
            id: e.id,
            title: _patientLabel(patients[e.strOrNull('patient_id')]),
            subtitle: [
              doctors[e.strOrNull('doctor_id')]?.str('display_name') ?? 'No doctor',
              'admitted ${formatDate(e.date('started_at'))}',
              stay(e),
            ].join(' · '),
            cells: [
              () {
                final p = patients[e.strOrNull('patient_id')];
                return p == null ? 'Unknown patient' : '${p.str('full_name')}\n${p.str('uhid')}';
              }(),
              doctors[e.strOrNull('doctor_id')]?.str('display_name') ?? '—',
              e.str('department', '—'),
              formatDate(e.date('started_at')),
              stay(e),
            ],
            patientId: e.strOrNull('patient_id'),
          ),
      ],
      count: count,
      noun: 'patient',
      truncated: count > rows.length,
    );
  }

  static Future<Drilldown> _patients(ReadDb db, DateTime n) async {
    final q = patientsRegistered(n);
    final count = await db.count(q);
    final rows = await db.query(q.sort('created_at', desc: true).take(rowLimit));
    return Drilldown(
      metric: Metrics.patientsToday,
      title: 'Registered today',
      subtitle: plural(count, 'new patient'),
      columns: const [
        DrillColumn('Patient', flex: 3),
        DrillColumn('UHID', flex: 2),
        DrillColumn('Age / sex', flex: 2),
        DrillColumn('Mobile', flex: 2),
        DrillColumn('Registered', flex: 2),
      ],
      rows: [
        for (final p in rows)
          DrillRow(
            id: p.id,
            title: p.str('full_name'),
            subtitle: [p.str('uhid'), ageLabel(p.date('dob'), p.intOrNull('age_years')), p.str('phone'), formatTime(p.createdAt)]
                .where((s) => s.isNotEmpty)
                .join(' · '),
            cells: [
              p.str('full_name'),
              p.str('uhid'),
              '${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${genderLabel(p.strOrNull('gender'))}',
              p.str('phone', '—'),
              formatTime(p.createdAt),
            ],
            patientId: p.id,
          ),
      ],
      count: count,
      noun: 'patient',
      truncated: count > rows.length,
    );
  }
}

class DrillColumn {
  const DrillColumn(this.label, {this.flex = 2, this.numeric = false});
  final String label;
  final int flex;
  final bool numeric;
}

class DrillRow {
  const DrillRow({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cells,
    this.amountPaise,
    this.patientId,
  });

  /// Id of the underlying record.
  final String id;
  final String title;
  final String subtitle;

  /// One value per [Drilldown.columns]. A '\n' splits a cell into two lines.
  final List<String> cells;
  final int? amountPaise;
  final String? patientId;
}

/// A metric and the transactions behind it.
class Drilldown {
  const Drilldown({
    required this.metric,
    required this.title,
    required this.subtitle,
    required this.columns,
    required this.rows,
    required this.count,
    required this.noun,
    this.totalPaise,
    this.truncated = false,
  });

  final String metric;
  final String title;
  final String subtitle;
  final List<DrillColumn> columns;
  final List<DrillRow> rows;

  /// Exact number of matching records (rows may be capped at [DashboardMetrics.rowLimit]).
  final int count;
  final String noun;

  /// Exact total of the matching records, for money metrics.
  final int? totalPaise;
  final bool truncated;
}

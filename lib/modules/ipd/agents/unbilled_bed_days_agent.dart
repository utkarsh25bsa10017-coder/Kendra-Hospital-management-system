import 'package:kendra_hms/core/core.dart';

import '../bed_charging.dart';
import '../bed_days.dart';
import '../ipd_schema.dart';

/// Checks every current stay and every discharge of the last 60 days against
/// the bed-day rule (see bed_days.dart). A bed-day with no live bed or
/// nursing charge is revenue walking out of the door. The posting job makes
/// this rare; the agent catches failures and charges that were cancelled or
/// removed by hand.
class UnbilledBedDaysAgent extends HmsAgent {
  @override
  String get id => 'ipd.unbilled_bed_days';
  @override
  String get name => 'Unbilled bed-days';
  @override
  String get description =>
      'Finds inpatient days that have no bed or nursing charge, so no stay leaves the hospital half billed.';
  @override
  Set<String> get watches => const {IpdCol.admissions, IpdCol.transfers, Col.charges};
  @override
  Duration get interval => const Duration(hours: 3);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final db = ctx.db;
    final now = ctx.now;
    final admissions = [
      ...await db.query(Query(IpdCol.admissions).isIn('status', IpdVals.current).take(2000)),
      ...await db.query(Query(IpdCol.admissions)
          .eq('status', IpdVals.discharged)
          .gte('discharged_at', now.subtract(const Duration(days: 60)))
          .take(5000)),
    ];
    if (admissions.isEmpty) return const AgentReport();

    final pricing = await BedPricing.load(db);
    final transfers = <String, List<Rec>>{};
    final ids = [for (final a in admissions) a.id];
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      for (final t in await db.query(Query(IpdCol.transfers).isIn('admission_id', chunk).sort('at').take(20000))) {
        transfers.putIfAbsent(t.str('admission_id'), () => []).add(t);
      }
    }

    // Live (not archived, not cancelled) bed and nursing charges in the window.
    final from = admissions.map((a) => startOfDay(a.date('admitted_at')!)).reduce((a, b) => a.isBefore(b) ? a : b);
    final covered = <String>{}; // '<admissionId>|<day>|<kind>' and '<encounterId>|<day>|<kind>'
    for (final c in await db.query(Query(Col.charges)
        .isIn('category', [Vals.bed, Vals.nursing])
        .gte('service_date', from)
        .take(100000))) {
      if (c.str('status') == Vals.cancelled) continue;
      final kind = c.str('category') == Vals.bed ? BedCharging.bed : BedCharging.nursing;
      final sid = c.str('source_id');
      if (c.str('source_collection') == IpdCol.admissions && sid.contains(':')) {
        final parts = sid.split(':');
        if (parts.length == 3) covered.add('${parts[0]}|${parts[1]}|${parts[2]}');
      }
      final enc = c.strOrNull('encounter_id');
      final day = c.date('service_date');
      if (enc != null && day != null) covered.add('$enc|${dayKey(day)}|$kind');
    }

    final patients = await db.byIds(Col.patients, admissions.map((a) => a.strOrNull('patient_id')));
    final findings = <FindingDraft>[];
    for (final a in admissions) {
      final (admitting, moves) = BedDays.movesFrom(a, transfers[a.id] ?? const []);
      final owed = BedDays.plan(
        admittedAt: a.date('admitted_at')!,
        dischargedAt: a.date('discharged_at'),
        admittingWardId: admitting,
        moves: moves,
        now: now,
      );
      final enc = a.strOrNull('encounter_id');
      final missingDays = <BedDay>[];
      var atRisk = 0;
      var unpriced = false;
      for (final d in owed) {
        var dayMissing = false;
        for (final kind in BedCharging.kinds) {
          final ok = covered.contains('${a.id}|${d.key}|$kind') || (enc != null && covered.contains('$enc|${d.key}|$kind'));
          if (ok) continue;
          dayMissing = true;
          final p = pricing.price(d.wardId, kind);
          if (p == null) {
            unpriced = true;
          } else {
            atRisk += p.$2;
          }
        }
        if (dayMissing) missingDays.add(d);
      }
      if (missingDays.isEmpty) continue;
      final p = patients[a.str('patient_id')];
      final name = p?.str('full_name') ?? 'Patient';
      final dates = missingDays.length <= 3
          ? missingDays.map((d) => formatDateShort(d.day)).join(', ')
          : '${formatDateShort(missingDays.first.day)} – ${formatDateShort(missingDays.last.day)}';
      final wards = missingDays.map((d) => pricing.wardName(d.wardId)).toSet().join(', ');
      findings.add(FindingDraft(
        key: 'admission:${a.id}',
        title: 'Unbilled bed-days: $name',
        summary: '${plural(missingDays.length, 'bed-day')} ($dates, $wards) on ${a.str('number')} '
            'have no bed or nursing charge${atRisk > 0 ? ' — ${formatMoney(atRisk)} at risk' : ''}.'
            '${unpriced ? ' The ward has no bed or nursing price set.' : ''} '
            'Check with billing and raise the missing charges.',
        severity: Severity.high,
        category: 'revenue',
        amountAtRiskPaise: atRisk,
        patientId: p?.id,
        evidence: [
          Evidence('Admission ${a.str('number')}', collection: IpdCol.admissions, id: a.id, routeId: 'ipd.admission', routeArgs: {'id': a.id, 'tab': 'charges'}),
          if (p != null)
            Evidence('$name · ${p.str('uhid')}', collection: Col.patients, id: p.id, routeId: 'patients.profile', routeArgs: {'id': p.id}),
        ],
        data: {'days': [for (final d in missingDays) d.key], 'amount_paise': atRisk},
      ));
    }
    return AgentReport(findings: findings);
  }
}

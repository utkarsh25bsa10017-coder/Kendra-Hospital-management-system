import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../lab_rules.dart';
import '../lab_schema.dart';
import '../lab_service.dart';

/// Tests ordered today and how fast reports went out against the target.
class LabTodayCard extends StatelessWidget {
  const LabTodayCard({super.key});

  Future<(int, int, Duration?, Duration?)> _load(ReadDb db) async {
    final today = startOfDay(DateTime.now());
    final ordered = await db.count(LabService.labOrders().gte('ordered_at', today).neq('status', Vals.cancelled));
    final done = await db.query(LabService.labOrders().eq('status', Vals.verified).gte('verified_at', today).take(500));
    if (done.isEmpty) return (ordered, 0, null, null);
    final tests = await LabService.testsByCode(db);
    var actual = 0;
    var target = 0;
    for (final o in done) {
      actual += o.date('verified_at')!.difference(o.date('ordered_at') ?? o.createdAt).inMinutes;
      target += targetMinutes(o.str('priority'), tests[o.str('service_code')]?.intOrNull('tat_minutes') ?? defaultTatMinutes);
    }
    return (ordered, done.length, Duration(minutes: actual ~/ done.length), Duration(minutes: target ~/ done.length));
  }

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, int, Duration?, Duration?)>(
        watch: const {Col.serviceOrders},
        load: _load,
        builder: (context, d) {
          final (ordered, reported, avg, target) = d;
          final late = avg != null && target != null && avg > target;
          return KpiTile(
            label: 'Lab today',
            value: plural(ordered, 'test'),
            icon: Icons.biotech_outlined,
            tone: late ? Tone.warning : Tone.info,
            caption: avg == null
                ? 'No reports verified yet today'
                : '$reported reported · average ${formatDuration(avg)} (target ${formatDuration(target!)})',
            onTap: () => context.app.nav.open('lab.worklist', {'tab': 'done'}),
          );
        },
      );
}

/// Results entered but not yet signed by a pathologist.
class AwaitingVerificationCard extends StatelessWidget {
  const AwaitingVerificationCard({super.key});

  Future<(int, DateTime?)> _load(ReadDb db) async {
    final q = LabService.labOrders().eq('status', Vals.resulted);
    final n = await db.count(q);
    final oldest = await db.first(q.sort('resulted_at'));
    return (n, oldest?.date('resulted_at'));
  }

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, DateTime?)>(
        watch: const {Col.serviceOrders},
        load: _load,
        builder: (context, d) {
          final (n, oldest) = d;
          final wait = oldest == null ? null : DateTime.now().difference(oldest);
          return KpiTile(
            label: 'Awaiting verification',
            value: '$n',
            icon: Icons.rate_review_outlined,
            tone: n == 0 ? Tone.success : ((wait?.inHours ?? 0) >= 4 ? Tone.warning : Tone.info),
            caption: n == 0 ? 'Every entered result is signed' : 'Oldest waiting ${formatDuration(wait!)}',
            onTap: () => context.app.nav.open('lab.worklist', {'tab': 'verify'}),
          );
        },
      );
}

/// Critical values from the last 48 hours that no doctor has acknowledged.
class CriticalResultsCard extends StatelessWidget {
  const CriticalResultsCard({super.key});

  Future<(int, String, String?)> _load(ReadDb db) async {
    final since = DateTime.now().subtract(const Duration(hours: 48));
    final rows = await db.query(Query(LabCol.results)
        .eq('critical', true)
        .eq('status', ResultStatus.verified)
        .gte('verified_at', since)
        .sort('verified_at', desc: true)
        .take(100));
    final open = rows.where((r) => r.date('acknowledged_at') == null).toList();
    if (open.isEmpty) return (0, '', null);
    final tests = await LabService.testsByCode(db);
    final patient = await db.get(Col.patients, open.first.str('patient_id'));
    final crit = criticalText(open.first.maps('values'), paramsOf(tests[open.first.str('test_code')]));
    return (open.length, '$crit · ${patient?.str('full_name') ?? ''}', open.first.str('order_id'));
  }

  @override
  Widget build(BuildContext context) => LiveBuilder<(int, String, String?)>(
        watch: const {LabCol.results},
        load: _load,
        builder: (context, d) {
          final (n, latest, orderId) = d;
          return KpiTile(
            label: 'Critical results',
            value: n == 0 ? 'None open' : '$n not acknowledged',
            icon: Icons.warning_amber_rounded,
            tone: n == 0 ? Tone.success : Tone.danger,
            caption: n == 0 ? 'All critical values acknowledged by a doctor' : latest,
            onTap: () => orderId == null
                ? context.app.nav.open('lab.worklist', {'tab': 'done'})
                : context.app.nav.open('lab.order', {'id': orderId}),
          );
        },
      );
}

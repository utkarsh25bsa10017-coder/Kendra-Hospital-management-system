import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kendra_hms/core/core.dart';

import 'tower_data.dart';

/// The morning briefing: what the agents found since the previous one, and
/// what is waiting for the board. Stored once per day in `tower_briefings`.
abstract final class Briefings {
  static Future<Rec?> forDay(ReadDb db, String day) =>
      db.first(Query(briefingsCol).eq('briefing_date', day));

  static Future<Rec?> latest(ReadDb db) => db.first(const Query(briefingsCol).sort('briefing_date', desc: true));

  static Future<List<Rec>> recent(ReadDb db, {int limit = 30}) =>
      db.query(const Query(briefingsCol).sort('briefing_date', desc: true).take(limit));

  /// Builds the summary for a briefing sent at [now].
  static Future<Map<String, Object?>> buildSummary(ReadDb db, AppServices app, {required DateTime now}) async {
    final today = dayKey(now);
    final previous = await db.first(Query(briefingsCol).lt('briefing_date', today).sort('briefing_date', desc: true));
    var since = previous?.date('sent_at') ?? now.subtract(const Duration(hours: 24));
    if (since.isAfter(now)) since = now.subtract(const Duration(hours: 24));

    const f = Query(Col.findings);
    final fresh = await db.query(f.between('first_seen_at', since, now).sort('first_seen_at', desc: true).take(2000));
    final bySeverity = <String, int>{for (final s in Severity.values.reversed) s.name: 0};
    final byAgent = <String, int>{};
    for (final r in fresh) {
      bySeverity[r.str('severity')] = (bySeverity[r.str('severity')] ?? 0) + 1;
      byAgent[r.str('agent_id')] = (byAgent[r.str('agent_id')] ?? 0) + 1;
    }
    final names = agentNames(app);
    final agents = byAgent.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = sortForTriage(fresh.where((r) => FindingStatus.unfixed.contains(r.str('status')))).take(8);

    Future<int> decidedSince(String status) =>
        db.count(f.eq('status', status).between('decided_at', since, now.add(const Duration(seconds: 1))));

    final kpis = await TowerKpis.load(db);
    final approvalsAmount =
        (await db.sum(const Query(Col.approvals).eq('status', 'pending'), 'amount_paise')).toInt();
    final summary = <String, Object?>{
      'since': since.toIso8601String(),
      'until': now.toIso8601String(),
      'new_total': fresh.length,
      'new_by_severity': bySeverity,
      'new_by_agent': [
        for (final e in agents) {'agent_id': e.key, 'name': agentLabel(names, e.key), 'count': e.value},
      ],
      'top': [
        for (final r in top)
          {
            'id': r.id,
            'title': r.str('title'),
            'severity': r.str('severity'),
            'agent_id': r.str('agent_id'),
            'agent_name': agentLabel(names, r.str('agent_id')),
            'amount_paise': r.intOrNull('amount_at_risk_paise'),
          },
      ],
      'cleared': await decidedSince(FindingStatus.cleared),
      'resolved': await decidedSince(FindingStatus.resolved),
      'dismissed': await decidedSince(FindingStatus.dismissed),
      'confirmed': await decidedSince(FindingStatus.confirmed),
      'open_total': kpis.openTotal,
      'open_urgent': kpis.openUrgent,
      'amount_at_risk_paise': kpis.atRiskPaise,
      'approvals_waiting': kpis.approvalsWaiting,
      'approvals_amount_paise': approvalsAmount,
      'suggestions_waiting': kpis.suggestionsWaiting,
    };
    summary['headline'] = headline(summary);
    return summary;
  }

  /// One sentence for the notification and the top of the page.
  static String headline(Map<String, Object?> s) {
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    final sev = (s['new_by_severity'] as Map?)?.cast<String, Object?>() ?? const {};
    int sv(String k) => (sev[k] as num?)?.toInt() ?? 0;
    final parts = <String>[];
    final fresh = n('new_total');
    if (fresh == 0) {
      parts.add('No new findings');
    } else {
      final urgent = [
        if (sv('critical') > 0) '${sv('critical')} critical',
        if (sv('high') > 0) '${sv('high')} high',
      ];
      parts.add('${plural(fresh, 'new finding')}${urgent.isEmpty ? '' : ' (${urgent.join(', ')})'}');
    }
    if (n('amount_at_risk_paise') > 0) parts.add('${formatMoneyShort(n('amount_at_risk_paise'))} at risk');
    final waiting = [
      if (n('approvals_waiting') > 0) plural(n('approvals_waiting'), 'approval'),
      if (n('suggestions_waiting') > 0) plural(n('suggestions_waiting'), 'suggestion'),
    ];
    if (waiting.isNotEmpty) parts.add('${waiting.join(' and ')} waiting');
    return parts.join(' · ');
  }

  /// Creates the briefing for [now]'s date and tells everyone who can see
  /// the control tower. Returns null if that day already has one.
  static Future<Rec?> create(AppServices app, Db db, {DateTime? now, String? exceptUserId}) async {
    final at = now ?? DateTime.now();
    final day = dayKey(at);
    if (await forDay(db, day) != null) return null;
    final summary = await buildSummary(db, app, now: at);
    final Rec rec;
    try {
      rec = await db.insert(briefingsCol, {'briefing_date': day, 'summary': summary, 'sent_at': at});
    } on ValidationException {
      // Another device or a person made it a moment ago.
      return null;
    }
    await app.notifications.notifyPermission(
      db,
      permission: CorePerms.towerView,
      title: 'Morning briefing for ${formatDateShort(at)}',
      body: summary['headline'] as String? ?? '',
      severity: 'info',
      kind: 'briefing',
      routeId: 'tower.briefing',
      exceptUserId: exceptUserId,
    );
    return rec;
  }
}

/// Prepares the morning briefing on the data host: checks every 10 minutes
/// (and shortly after start) whether it is past the briefing hour and today
/// has no briefing yet.
class BriefingJob {
  BriefingJob(this.ctx);
  final ModuleContext ctx;

  static const every = Duration(minutes: 10);
  static const firstCheck = Duration(seconds: 5);

  Timer? _timer;
  Timer? _first;
  StreamSubscription<Object?>? _closed;
  bool _busy = false;

  void start() {
    if (!ctx.isDataHost || _timer != null) return;
    _first = Timer(firstCheck, _tick);
    _timer = Timer.periodic(every, (_) => _tick());
    // Stop when the database closes (sign-out of the demo, restore, tests).
    _closed = ctx.services.store.changes.listen((_) {}, onDone: stop);
  }

  void stop() {
    _first?.cancel();
    _timer?.cancel();
    _closed?.cancel();
    _first = null;
    _timer = null;
    _closed = null;
  }

  Future<void> _tick() async {
    try {
      await runIfDue();
    } catch (e) {
      debugPrint('tower briefing failed: $e');
    }
  }

  /// Makes today's briefing if it is time and there isn't one yet.
  /// Returns the new briefing, or null if nothing was due.
  Future<Rec?> runIfDue({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final settings = ctx.services.settings;
    // Not while a new hospital or the demo is still being set up.
    if (!settings.flag(SettingKeys.setupComplete)) return null;
    if (at.hour < settings.briefingHour || _busy) return null;
    _busy = true;
    try {
      return await Briefings.create(ctx.services, ctx.systemDb, now: at);
    } finally {
      _busy = false;
    }
  }
}

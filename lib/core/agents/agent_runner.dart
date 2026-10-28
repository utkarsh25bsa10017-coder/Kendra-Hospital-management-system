import 'dart:async';

import 'package:flutter/foundation.dart';

import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../data/db.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../modules/module.dart';
import '../services/app_services.dart';
import 'agent.dart';

class AgentStatus {
  const AgentStatus({this.lastRun, this.lastDuration, this.lastError, this.findings = 0, this.proposals = 0, this.running = false});
  final DateTime? lastRun;
  final Duration? lastDuration;
  final String? lastError;
  final int findings;
  final int proposals;
  final bool running;
}

/// Runs the agents of every active module on the device that holds the data.
///
/// Agents only read. This runner is the one place their reports are written
/// back: new problems become open findings, problems that disappear are
/// cleared, and dismissed subjects stay quiet. Nothing an agent says
/// changes clinical or financial data by itself.
class AgentRunner {
  AgentRunner(this.services);
  final AppServices services;

  final status = ValueNotifier<Map<String, AgentStatus>>({});
  final _timers = <String, Timer>{};
  final _running = <String>{};
  StreamSubscription<Object?>? _sub;
  Timer? _tick;
  Timer? _first;
  bool _started = false;

  static const _quiet = {Col.findings, Col.proposals, Col.notifications, Col.suppressions, Col.userPrefs};

  Db get _db => services.systemDb;

  bool isEnabled(HmsAgent a) {
    final disabled = services.settings.list(SettingKeys.agentsDisabled);
    if (disabled.contains(a.id)) return false;
    final enabledOverride = services.settings.list('agents.enabled');
    return a.enabledByDefault || enabledOverride.contains(a.id);
  }

  void start() {
    if (_started || !services.isDataHost) return;
    _started = true;
    _sub = services.store.changes.where((c) => !_quiet.contains(c.collection)).listen((c) {
      for (final (_, a) in services.registry.agents) {
        if (a.watches.contains(c.collection)) _schedule(a, const Duration(seconds: 4));
      }
    });
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _periodic());
    _first = Timer(const Duration(seconds: 3), _periodic);
  }

  void _schedule(HmsAgent a, Duration delay) {
    _timers[a.id]?.cancel();
    _timers[a.id] = Timer(delay, () => runAgent(a));
  }

  void _periodic() {
    final now = DateTime.now();
    for (final (_, a) in services.registry.agents) {
      final last = status.value[a.id]?.lastRun;
      if (last == null || now.difference(last) >= a.interval) runAgent(a);
    }
  }

  Future<void> runAll() async {
    for (final (_, a) in services.registry.agents) {
      await runAgent(a, force: true);
    }
  }

  Future<void> runById(String id) async {
    for (final (_, a) in services.registry.agents) {
      if (a.id == id) return runAgent(a, force: true);
    }
  }

  void _setStatus(String id, AgentStatus s) => status.value = {...status.value, id: s};

  Future<void> runAgent(HmsAgent agent, {bool force = false}) async {
    if (!services.isDataHost || _running.contains(agent.id)) return;
    if (!force && !isEnabled(agent)) return;
    final module = services.registry.agents.where((p) => p.$2.id == agent.id).firstOrNull?.$1;
    if (module == null) return;
    _running.add(agent.id);
    final prev = status.value[agent.id];
    _setStatus(agent.id, AgentStatus(lastRun: prev?.lastRun, findings: prev?.findings ?? 0, running: true));
    final started = DateTime.now();
    try {
      final report = await agent.run(AgentContext(db: ReadDb(services.store), settings: services.settings));
      await _reconcile(module, agent, report);
      _setStatus(
          agent.id,
          AgentStatus(
              lastRun: started,
              lastDuration: DateTime.now().difference(started),
              findings: report.findings.length,
              proposals: report.proposals.length));
    } catch (e, st) {
      debugPrint('agent ${agent.id} failed: $e\n$st');
      _setStatus(agent.id, AgentStatus(lastRun: started, lastError: e.toString()));
    } finally {
      _running.remove(agent.id);
    }
  }

  Future<void> _reconcile(HmsModule module, HmsAgent agent, AgentReport report) async {
    final now = DateTime.now();
    final suppressed = {
      for (final s in await _db.query(Query(Col.suppressions).eq('agent_id', agent.id).eq('active', true)))
        s.str('subject_key'),
    };
    final existing = {
      for (final f in await _db.query(Query(Col.findings).eq('agent_id', agent.id).withArchived()))
        f.str('fingerprint'): f,
    };
    final seen = <String>{};
    final ops = <WriteOp>[];
    final alerts = <(Rec?, FindingDraft, String)>[];

    for (final d in report.findings) {
      final subject = d.subjectKey ?? d.key;
      if (suppressed.contains(subject)) continue;
      final fp = '${agent.id}:${d.key}';
      if (!seen.add(fp)) continue;
      final fields = <String, Object?>{
        'title': d.title,
        'summary': d.summary,
        'severity': d.severity.name,
        'category': d.category,
        'amount_at_risk_paise': d.amountAtRiskPaise,
        'patient_id': d.patientId,
        'evidence': [for (final e in d.evidence) e.toJson()],
        'subject_key': subject,
        'data': d.data,
      };
      final cur = existing[fp];
      if (cur == null) {
        final id = _db.newId();
        ops.add(InsertOp(Col.findings, {
          ...fields,
          'agent_id': agent.id,
          'module_id': module.id,
          'fingerprint': fp,
          'status': 'open',
          'first_seen_at': now,
          'last_seen_at': now,
          'occurrences': 1,
        }, id: id));
        if (d.severity.index >= Severity.high.index) alerts.add((null, d, id));
      } else {
        final st = cur.str('status');
        if (st == 'dismissed') continue;
        final reopen = st == 'cleared' || st == 'resolved';
        ops.add(UpdateOp(Col.findings, cur.id, {
          ...fields,
          'last_seen_at': now,
          if (reopen) 'status': 'open',
          if (reopen) 'decision_note': st == 'resolved' ? 'Seen again after it was marked fixed' : null,
          if (reopen) 'occurrences': cur.integer('occurrences', 1) + 1,
        }));
        if (reopen && d.severity.index >= Severity.high.index) alerts.add((cur, d, cur.id));
      }
    }

    // Problems the agent no longer sees clear themselves.
    for (final f in existing.values) {
      if (!seen.contains(f.str('fingerprint')) && f.str('status') == 'open') {
        ops.add(UpdateOp(Col.findings, f.id, {
          'status': 'cleared',
          'decision_note': 'The agent no longer sees this problem',
          'decided_at': now,
        }));
      }
    }

    // Proposals
    final existingP = {
      for (final p in await _db.query(Query(Col.proposals).eq('agent_id', agent.id).withArchived()))
        p.str('fingerprint'): p,
    };
    final seenP = <String>{};
    final newProposals = <ProposalDraft>[];
    for (final p in report.proposals) {
      final fp = '${agent.id}:${p.key}';
      if (!seenP.add(fp)) continue;
      final cur = existingP[fp];
      final fields = {
        'title': p.title,
        'summary': p.summary,
        'handler': p.handler,
        'payload': p.payload,
        'severity': p.severity.name,
        'required_permission': p.requiredPermission,
      };
      if (cur == null) {
        ops.add(InsertOp(Col.proposals,
            {...fields, 'agent_id': agent.id, 'module_id': module.id, 'fingerprint': fp, 'status': 'pending'}));
        newProposals.add(p);
      } else if (cur.str('status') == 'pending') {
        ops.add(UpdateOp(Col.proposals, cur.id, fields));
      } else if (cur.str('status') == 'expired') {
        ops.add(UpdateOp(Col.proposals, cur.id, {...fields, 'status': 'pending'}));
        newProposals.add(p);
      }
    }
    for (final p in existingP.values) {
      if (!seenP.contains(p.str('fingerprint')) && p.str('status') == 'pending') {
        ops.add(UpdateOp(Col.proposals, p.id, {'status': 'expired', 'result': 'No longer needed'}));
      }
    }

    await _db.batch(ops);

    // Critical and high findings alert the board straight away; everything
    // else waits for the morning briefing.
    for (final (_, d, id) in alerts) {
      await services.notifications.notifyPermission(_db,
          permission: CorePerms.towerView,
          title: '${d.severity.label}: ${d.title}',
          body: d.summary,
          severity: d.severity.name,
          kind: 'finding',
          routeId: 'tower.findings',
          routeArgs: {'id': id});
    }
    if (newProposals.isNotEmpty) {
      await services.notifications.notifyPermission(_db,
          permission: CorePerms.approvalsDecide,
          title: newProposals.length == 1
              ? 'Suggestion: ${newProposals.first.title}'
              : '${newProposals.length} new suggestions from ${agent.name}',
          body: 'Review and approve in the control tower',
          kind: 'proposal',
          routeId: 'tower.proposals');
    }
  }

  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _first?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
  }
}

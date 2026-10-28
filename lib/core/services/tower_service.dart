import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../data/record.dart';
import '../modules/module.dart';
import 'app_services.dart';

/// Decisions people make on agent findings and proposals. The control
/// tower screens call these; the rules live here so they apply everywhere.
class TowerService {
  TowerService(this.services);
  final AppServices services;

  void _need(String permission) {
    if (!services.auth.can(permission)) throw PermissionDeniedException('You do not have permission to do this');
  }

  Map<String, Object?> _decided(String status, String? note) => {
        'status': status,
        'decided_by': services.auth.session!.userId,
        'decided_at': DateTime.now(),
        'decision_note': note,
      };

  Future<Rec> confirm(Rec finding, {String? note}) {
    _need(CorePerms.towerDecide);
    return services.db.update(Col.findings, finding.id, _decided('confirmed', note), expectedVersion: finding.version);
  }

  /// [suppress] adds a rule so the agent stops flagging this subject.
  Future<Rec> dismiss(Rec finding, {required String reason, bool suppress = false}) async {
    _need(CorePerms.towerDecide);
    if (reason.trim().isEmpty) throw ValidationException('Give a reason so the agents can learn from it');
    final rec = await services.db
        .update(Col.findings, finding.id, _decided('dismissed', reason), expectedVersion: finding.version);
    if (suppress) {
      await services.db.insert(Col.suppressions, {
        'agent_id': finding.str('agent_id'),
        'subject_key': finding.strOrNull('subject_key') ?? finding.str('fingerprint'),
        'reason': reason,
        'active': true,
        'created_by_name': services.auth.session!.displayName,
      });
    }
    return rec;
  }

  Future<Rec> assign(Rec finding, String userId, {String? note}) async {
    _need(CorePerms.towerDecide);
    final rec = await services.db.update(
      Col.findings,
      finding.id,
      {..._decided('assigned', note), 'assigned_to': userId},
      expectedVersion: finding.version,
    );
    await services.notifications.notifyUser(services.db, userId,
        title: 'Assigned to you: ${finding.str('title')}',
        body: note ?? finding.str('summary'),
        severity: finding.str('severity'),
        kind: 'finding',
        routeId: 'tower.findings',
        routeArgs: {'id': finding.id});
    return rec;
  }

  /// The board, or the person it was assigned to, marks it fixed.
  Future<Rec> resolve(Rec finding, {String? note}) {
    final s = services.auth.session!;
    if (!s.can(CorePerms.towerDecide) && finding.str('assigned_to') != s.userId) {
      throw PermissionDeniedException('Only the board or the assignee can resolve this');
    }
    return services.db.update(Col.findings, finding.id, _decided('resolved', note), expectedVersion: finding.version);
  }

  Future<Rec> reopen(Rec finding) {
    _need(CorePerms.towerDecide);
    return services.db.update(Col.findings, finding.id, _decided('open', 'Reopened'), expectedVersion: finding.version);
  }

  Future<Rec> approveProposal(Rec p, {String? note}) async {
    final perm = p.strOrNull('required_permission') ?? CorePerms.approvalsDecide;
    _need(perm);
    if (p.str('status') != 'pending') throw ValidationException('This suggestion was already decided');
    final handler = services.registry.proposalHandler(p.str('handler'));
    if (handler == null) throw ValidationException('The module that handles this suggestion is switched off');
    // Claim it first so two people approving at once can't run it twice.
    final claimed = await services.db
        .update(Col.proposals, p.id, _decided('approved', note), expectedVersion: p.version);
    final module = services.registry.active.firstWhere((m) => m.proposalHandlers.containsKey(p.str('handler')));
    try {
      final result = await handler(ModuleContext(services, module), claimed, services.db);
      return await services.db.update(Col.proposals, p.id, {'result': result});
    } catch (e) {
      return services.db.update(Col.proposals, p.id, {'status': 'failed', 'result': 'Could not carry out: $e'});
    }
  }

  Future<Rec> rejectProposal(Rec p, {String? note}) {
    _need(p.strOrNull('required_permission') ?? CorePerms.approvalsDecide);
    return services.db.update(Col.proposals, p.id, _decided('rejected', note), expectedVersion: p.version);
  }

  Future<void> liftSuppression(Rec suppression) {
    _need(CorePerms.towerDecide);
    return services.db.update(Col.suppressions, suppression.id, {'active': false});
  }
}

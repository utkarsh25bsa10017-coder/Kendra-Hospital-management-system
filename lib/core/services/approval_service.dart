import '../contracts/collections.dart';
import '../contracts/permissions.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../modules/module.dart';
import 'app_services.dart';

class ApprovalOutcome {
  const ApprovalOutcome(this.approval, {required this.applied, this.result = ''});
  final Rec approval;

  /// True when the change has already been made (it was within the
  /// requester's own limit).
  final bool applied;
  final String result;
}

/// Discounts, refunds and other exceptions.
///
/// * Within the requester's own limit: applied straight away, and logged.
/// * Above it: goes to the board. The requester can never approve it.
/// * Above the hospital's high-value limit: two different board members.
class ApprovalService {
  ApprovalService(this.services);
  final AppServices services;

  Future<ApprovalOutcome> request({
    required String type,
    required String title,
    required int amountPaise,
    String? reason,
    String? subjectCollection,
    String? subjectId,
    String? patientId,
    Map<String, Object?> payload = const {},
  }) async {
    final session = services.auth.session;
    if (session == null) throw PermissionDeniedException('Please sign in again');
    final db = services.db;
    final withinLimit = amountPaise <= session.discountLimitPaise;
    final required = withinLimit ? 0 : (amountPaise > services.settings.highValueLimitPaise ? 2 : 1);
    final rec = await db.insert(Col.approvals, {
      'type': type,
      'status': withinLimit ? 'approved' : 'pending',
      'title': title,
      'amount_paise': amountPaise,
      'requested_by': session.userId,
      'requested_by_name': session.displayName,
      'reason': reason,
      'subject_collection': subjectCollection,
      'subject_id': subjectId,
      'patient_id': patientId,
      'payload': payload,
      'required_approvals': required,
      'approvers': <Object?>[],
      'auto_approved': withinLimit,
      if (withinLimit) 'decided_at': DateTime.now(),
    });
    if (withinLimit) {
      final applied = await _apply(rec);
      return ApprovalOutcome(applied, applied: applied['status'] == 'applied', result: applied.str('result'));
    }
    await services.notifications.notifyPermission(
      db,
      permission: CorePerms.approvalsDecide,
      title: 'Approval needed: $title',
      body: '${session.displayName} asked${required == 2 ? ' (needs 2 approvals)' : ''}. ${reason ?? ''}'.trim(),
      severity: 'medium',
      kind: 'approval',
      routeId: 'tower.approvals',
      routeArgs: {'id': rec.id},
      exceptUserId: session.userId,
    );
    return ApprovalOutcome(rec, applied: false);
  }

  /// Returns null if [user] may approve, otherwise the reason they can't.
  String? whyCannotApprove(Rec approval, String userId, bool hasPermission) {
    if (!hasPermission) return 'You do not have permission to approve requests';
    if (approval.str('status') != 'pending') return 'This request is no longer pending';
    if (approval.str('requested_by') == userId) return 'You cannot approve your own request';
    if (approval.maps('approvers').any((a) => a['user_id'] == userId)) return 'You have already approved this';
    return null;
  }

  Future<Rec> approve(Rec approval, {String? note}) async {
    final s = services.auth.session!;
    final problem = whyCannotApprove(approval, s.userId, s.can(CorePerms.approvalsDecide));
    if (problem != null) throw PermissionDeniedException(problem);
    final approvers = [
      ...approval.maps('approvers'),
      {'user_id': s.userId, 'name': s.displayName, 'at': DateTime.now().toIso8601String(), 'note': note},
    ];
    final done = approvers.length >= approval.integer('required_approvals', 1);
    final updated = await services.db.update(
      Col.approvals,
      approval.id,
      {'approvers': approvers, if (done) 'status': 'approved', if (done) 'decided_at': DateTime.now()},
      expectedVersion: approval.version,
    );
    if (!done) return updated;
    final applied = await _apply(updated);
    await services.notifications.notifyUser(services.db, approval.str('requested_by'),
        title: 'Approved: ${approval.str('title')}', body: applied.str('result'), kind: 'approval');
    return applied;
  }

  Future<Rec> reject(Rec approval, {required String note}) async {
    final s = services.auth.session!;
    if (!s.can(CorePerms.approvalsDecide)) throw PermissionDeniedException('You cannot decide approvals');
    if (approval.str('requested_by') == s.userId) {
      throw PermissionDeniedException('You cannot decide your own request; cancel it instead');
    }
    final rec = await services.db.update(
      Col.approvals,
      approval.id,
      {'status': 'rejected', 'rejected_by': s.userId, 'decision_note': note, 'decided_at': DateTime.now()},
      expectedVersion: approval.version,
    );
    await services.notifications.notifyUser(services.db, approval.str('requested_by'),
        title: 'Not approved: ${approval.str('title')}', body: note, kind: 'approval', severity: 'low');
    return rec;
  }

  Future<Rec> cancel(Rec approval) async {
    final s = services.auth.session!;
    if (approval.str('requested_by') != s.userId) throw PermissionDeniedException('Only the requester can cancel');
    return services.db.update(Col.approvals, approval.id, {'status': 'cancelled'}, expectedVersion: approval.version);
  }

  Future<Rec> _apply(Rec approval) async {
    final handler = services.registry.approvalHandler(approval.str('type'));
    final module = services.registry.active.firstWhere(
      (m) => m.approvalHandlers.containsKey(approval.str('type')),
      orElse: () => services.registry.all.first,
    );
    if (handler == null) {
      return services.db.update(
          Col.approvals, approval.id, {'result': 'Approved. No installed module applies this type automatically.'});
    }
    try {
      final result = await handler(ModuleContext(services, module), approval, services.db);
      return await services.db.update(Col.approvals, approval.id, {'status': 'applied', 'result': result});
    } catch (e) {
      return services.db.update(Col.approvals, approval.id, {'status': 'failed', 'result': 'Could not apply: $e'});
    }
  }

  Query get pendingQuery => const Query(Col.approvals).eq('status', 'pending').sort('created_at');
}

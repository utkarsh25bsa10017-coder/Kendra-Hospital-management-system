import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';

import '../helpers.dart';

/// A tiny module used only by these tests.
class _TestModule extends HmsModule {
  _TestModule(this.agent);
  final HmsAgent agent;
  final applied = <String>[];
  @override
  String get id => 'testmod';
  @override
  String get name => 'Test';
  @override
  String get description => '';
  @override
  IconData get icon => Icons.bug_report;
  @override
  List<HmsAgent> get agents => [agent];
  @override
  Map<String, ApprovalHandler> get approvalHandlers => {
        'test.discount': (ctx, a, db) async {
          applied.add(a.id);
          return 'Discount of ${formatMoney(a.integer('amount_paise'))} applied';
        },
      };
  @override
  Map<String, ProposalHandler> get proposalHandlers => {
        'test.fix': (ctx, p, db) async => 'Fixed ${p.map('payload')['what']}',
      };
}

class _FakeAgent extends HmsAgent {
  List<FindingDraft> next = [];
  List<ProposalDraft> proposals = [];
  @override
  String get id => 'testmod.fake';
  @override
  String get name => 'Fake';
  @override
  String get description => '';
  @override
  Future<AgentReport> run(AgentContext ctx) async => AgentReport(findings: next, proposals: proposals);
}

void main() {
  test('sign-in, wrong password and lockout', () async {
    final app = await bootTestHospital([PatientsModule()]);
    await app.auth.login('owner', 'Passw0rd!');
    expect(app.auth.session!.can('anything'), isTrue, reason: 'owner has *');
    await app.auth.logout();

    for (var i = 0; i < 4; i++) {
      await expectLater(app.auth.login('owner', 'wrong'), throwsA(isA<AuthException>()));
    }
    await expectLater(
      app.auth.login('owner', 'wrong'),
      throwsA(predicate((e) => e is AuthException && e.message.contains('locked'))),
    );
    // Even the right password is refused while locked.
    await expectLater(app.auth.login('owner', 'Passw0rd!'), throwsA(isA<AuthException>()));
    await app.close();
  });

  test('built-in roles get module permissions', () async {
    final app = await bootTestHospital([PatientsModule()]);
    await addUser(app, 'reception1', [Roles.receptionist]);
    await signIn(app, 'reception1');
    expect(app.auth.can('patients.edit'), isTrue);
    expect(app.auth.can('admin.users'), isFalse);
    await app.close();
  });

  test('approvals: own limit, board approval, two-person rule', () async {
    final mod = _TestModule(_FakeAgent());
    final app = await bootTestHospital([PatientsModule(), mod]);
    await app.settings.set(app.systemDb, SettingKeys.highValueLimitPaise, 500000);
    await addUser(app, 'cashier', [Roles.billing], extra: {'discount_limit_paise': 20000});
    await addUser(app, 'board1', [Roles.board]);
    await addUser(app, 'board2', [Roles.board]);

    await signIn(app, 'cashier');
    // Within the cashier's ₹200 limit: applied at once, but still recorded.
    final small = await app.approvals.request(type: 'test.discount', title: 'Small', amountPaise: 15000);
    expect(small.applied, isTrue);
    expect(mod.applied, hasLength(1));

    // Above the limit: waits for the board.
    final mid = await app.approvals.request(type: 'test.discount', title: 'Mid', amountPaise: 100000, reason: 'Staff family');
    expect(mid.applied, isFalse);
    expect(mid.approval.integer('required_approvals'), 1);
    await expectLater(app.approvals.approve(mid.approval), throwsA(isA<PermissionDeniedException>()),
        reason: 'requester cannot approve own request');

    await signIn(app, 'board1');
    final done = await app.approvals.approve(mid.approval);
    expect(done.str('status'), 'applied');
    expect(mod.applied, hasLength(2));

    // High value needs two different board members.
    await signIn(app, 'cashier');
    final big = await app.approvals.request(type: 'test.discount', title: 'Big', amountPaise: 900000);
    expect(big.approval.integer('required_approvals'), 2);
    await signIn(app, 'board1');
    final once = await app.approvals.approve(big.approval);
    expect(once.str('status'), 'pending');
    await expectLater(app.approvals.approve(once), throwsA(isA<PermissionDeniedException>()),
        reason: 'same person cannot approve twice');
    await signIn(app, 'board2');
    final twice = await app.approvals.approve(once);
    expect(twice.str('status'), 'applied');
    expect(mod.applied, hasLength(3));
    await app.close();
  });

  test('agent findings open, clear themselves, and stay dismissed', () async {
    final agent = _FakeAgent();
    final app = await bootTestHospital([PatientsModule(), _TestModule(agent)]);
    await addUser(app, 'board1', [Roles.board]);
    final runner = app.agents!;

    agent.next = [
      const FindingDraft(key: 'a', title: 'Problem A', summary: '', severity: Severity.medium, subjectKey: 'user:1'),
      const FindingDraft(key: 'b', title: 'Problem B', summary: '', severity: Severity.critical),
    ];
    await runner.runById(agent.id);
    var open = await app.store.query(const Query(Col.findings).eq('status', 'open'));
    expect(open, hasLength(2));
    // The critical one alerted the board immediately.
    final notes = await app.store.query(const Query(Col.notifications).eq('kind', 'finding'));
    expect(notes.where((n) => n.str('title').contains('Problem B')), isNotEmpty);

    // B is fixed; the agent stops reporting it.
    agent.next = [agent.next.first];
    await runner.runById(agent.id);
    final b = (await app.store.query(const Query(Col.findings).eq('title', 'Problem B'))).single;
    expect(b.str('status'), 'cleared');

    // The board dismisses A and asks not to be told again.
    await signIn(app, 'board1');
    final a = (await app.store.query(const Query(Col.findings).eq('title', 'Problem A'))).single;
    await app.tower.dismiss(a, reason: 'Approved package rate', suppress: true);
    agent.next = [
      const FindingDraft(key: 'a2', title: 'Problem A again', summary: '', severity: Severity.medium, subjectKey: 'user:1'),
    ];
    await runner.runById(agent.id);
    open = await app.store.query(const Query(Col.findings).eq('status', 'open'));
    expect(open, isEmpty, reason: 'suppressed subject is not flagged again');
    await app.close();
  });

  test('agent proposals wait for a person', () async {
    final agent = _FakeAgent();
    final app = await bootTestHospital([PatientsModule(), _TestModule(agent)]);
    await addUser(app, 'board1', [Roles.board]);
    agent.proposals = [
      const ProposalDraft(key: 'p1', title: 'Reorder paracetamol', summary: '', handler: 'test.fix', payload: {'what': 'stock'}),
    ];
    await app.agents!.runById(agent.id);
    final p = (await app.store.query(const Query(Col.proposals))).single;
    expect(p.str('status'), 'pending');
    await signIn(app, 'board1');
    final done = await app.tower.approveProposal(p);
    expect(done.str('status'), 'approved');
    expect(done.str('result'), 'Fixed stock');
    await app.close();
  });
}

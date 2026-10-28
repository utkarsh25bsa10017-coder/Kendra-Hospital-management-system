import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kendra_hms/app/app.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/modules/patients/patients_module.dart';
import 'package:kendra_hms/modules/tower/briefing.dart';
import 'package:kendra_hms/modules/tower/tower_data.dart';
import 'package:kendra_hms/modules/tower/tower_module.dart';

import '../../helpers.dart';
import '../../screens/shots.dart';
import 'fake_checks_module.dart';

Future<(AppServices, TowerModule, FakeChecksModule)> _boot() async {
  final tower = TowerModule();
  final checks = FakeChecksModule();
  final app = await bootTestHospital([PatientsModule(), tower, checks], demo: true);
  // The tests drive the job themselves.
  tower.briefingJob?.stop();
  return (app, tower, checks);
}

Future<Rec> _finding(AppServices app, String title) async =>
    (await app.store.query(Query(Col.findings).eq('title', title).take(1))).single;

void main() {
  setUpAll(loadFonts);

  test('briefing job makes one briefing per day and notifies the board', () async {
    final (app, tower, _) = await _boot();
    await app.agents!.runAll();
    final job = BriefingJob(ModuleContext(app, tower));
    final day = DateTime(2030, 1, 15);

    expect(await job.runIfDue(now: day.add(const Duration(hours: 7, minutes: 50))), isNull,
        reason: 'not before the briefing hour (8 AM)');

    final first = await job.runIfDue(now: day.add(const Duration(hours: 8, minutes: 5)));
    expect(first, isNotNull);
    expect(first!.str('briefing_date'), '2030-01-15');
    final s = first.map('summary');
    final open = await app.store.count(const Query(Col.findings).eq('status', 'open'));
    expect(s['open_total'], open);
    expect(s['new_total'], greaterThanOrEqualTo(7), reason: 'the fake agents raised 7 findings since yesterday');
    expect((s['new_by_severity'] as Map)['critical'], 1);
    expect(s['approvals_waiting'], 3);
    expect(s['suggestions_waiting'], 2);
    expect(s['headline'] as String, contains('1 critical'));

    // Ten minutes later: nothing new.
    expect(await job.runIfDue(now: day.add(const Duration(hours: 8, minutes: 15))), isNull);
    expect(await job.runIfDue(now: day.add(const Duration(hours: 21))), isNull);
    expect(await app.store.count(const Query(briefingsCol).eq('briefing_date', '2030-01-15')), 1);

    // Everyone who can see the control tower was told, with a link.
    final notes = await app.store.query(const Query(Col.notifications).eq('kind', 'briefing'));
    final board = (await app.store.query(const Query(Col.users).eq('username', 'board'))).single;
    final reception = (await app.store.query(const Query(Col.users).eq('username', 'reception'))).single;
    expect(notes.where((n) => n.str('user_id') == board.id && n.str('route_id') == 'tower.briefing'), hasLength(1));
    expect(notes.where((n) => n.str('user_id') == reception.id), isEmpty);

    // The next morning there is a new one, covering only what changed since.
    final second = await job.runIfDue(now: day.add(const Duration(days: 1, hours: 9)));
    expect(second, isNotNull);
    expect(second!.str('briefing_date'), '2030-01-16');
    expect(DateTime.parse(second.map('summary')['since'] as String), first.date('sent_at'));
    expect(second.map('summary')['new_total'], 0);
    await app.close();
  });

  test('the job waits until setup is complete', () async {
    final (app, tower, _) = await _boot();
    await app.settings.set(app.systemDb, SettingKeys.setupComplete, false);
    final job = BriefingJob(ModuleContext(app, tower));
    expect(await job.runIfDue(now: DateTime(2030, 2, 1, 9)), isNull);
    await app.close();
  });

  test('decision helpers go through TowerService', () async {
    final (app, _, _) = await _boot();
    await app.agents!.runAll();
    await signInDemo(app, 'board');

    final critical = await _finding(app, 'Discount above the cashier\'s limit on INV-2026-0142');
    expect(findingActions(app.auth.session, critical),
        {FindingAction.confirm, FindingAction.dismiss, FindingAction.assign, FindingAction.fix});

    // A reason is required, so the agents can learn.
    await expectLater(TowerDecisions.dismiss(app, critical, reason: '   '), throwsA(isA<ValidationException>()));
    expect((await _finding(app, critical.str('title'))).str('status'), 'open');

    // Dismiss without "don't flag again": no rule.
    final stock = await _finding(app, 'Stock count mismatch: Pantoprazole 40 mg');
    await TowerDecisions.dismiss(app, stock, reason: 'Data entry already corrected');
    expect(await app.store.count(Query(Col.suppressions).eq('agent_id', 'checks.stock').eq('active', true)), 0);

    // Dismiss with it ticked: a suppression for this subject.
    final d = await TowerDecisions.dismiss(app, critical, reason: 'Approved package rate', dontFlagAgain: true);
    expect(d.str('status'), 'dismissed');
    expect(d.str('decision_note'), 'Approved package rate');
    expect(d.str('decided_by'), app.auth.session!.userId);
    final rules = await app.store.query(const Query(Col.suppressions).eq('agent_id', 'checks.bill_matching'));
    expect(rules, hasLength(1));
    expect(rules.single.str('subject_key'), 'user:billing');
    expect(rules.single.flag('active'), isTrue);
    expect(rules.single.str('created_by_name'), 'Dr. Suresh Iyer');

    // The agent runs again: the dismissed subject stays quiet.
    await app.agents!.runAll();
    expect((await _finding(app, critical.str('title'))).str('status'), 'dismissed');
    expect(findingActions(app.auth.session, d), {FindingAction.reopen});

    // Confirm, assign (notifies the assignee), mark fixed, reopen.
    final lipid = await _finding(app, 'Lab test done but never billed: Lipid profile');
    final confirmed = await TowerDecisions.confirm(app, lipid, note: '  ');
    expect(confirmed.str('status'), 'confirmed');
    expect(confirmed.strOrNull('decision_note'), isNull);
    final lab = (await app.store.query(const Query(Col.users).eq('username', 'lab'))).single;
    final assigned = await TowerDecisions.assign(app, confirmed, lab.id);
    expect(assigned.str('status'), 'assigned');
    expect(assigned.str('assigned_to'), lab.id);
    expect(
      await app.store.count(Query(Col.notifications).eq('user_id', lab.id).eq('route_id', 'tower.findings')),
      1,
    );
    final fixed = await TowerDecisions.markFixed(app, assigned, note: 'Charge added');
    expect(fixed.str('status'), 'resolved');
    final reopened = await TowerDecisions.reopen(app, fixed);
    expect(reopened.str('status'), 'open');

    // Lifting the rule lets the agent flag the subject again.
    await app.tower.liftSuppression(rules.single);
    expect((await app.store.get(Col.suppressions, rules.single.id))!.flag('active'), isFalse);

    // Someone who can only look gets no buttons, and the service refuses anyway.
    await signInDemo(app, 'accounts');
    final medium = await _finding(app, 'Consultation billed below the tariff');
    expect(findingActions(app.auth.session, medium), isEmpty);
    await expectLater(TowerDecisions.confirm(app, medium), throwsA(isA<PermissionDeniedException>()));
    await app.close();
  });

  test('approvals: the requester can never approve their own', () async {
    final (app, _, checks) = await _boot();
    await signInDemo(app, 'billing');
    final out = await app.approvals.request(
        type: 'billing.discount', title: 'Discount on INV-9', amountPaise: 80000, reason: 'Long-time patient');
    expect(out.applied, isFalse);
    final req = out.approval;
    expect(TowerDecisions.whyCannotApprove(app, req), 'You do not have permission to approve requests');

    await signInDemo(app, 'board');
    expect(TowerDecisions.whyCannotApprove(app, req), isNull);
    await expectLater(TowerDecisions.reject(app, req, reason: ''), throwsA(isA<ValidationException>()));

    // A board member's own request.
    final own = await app.approvals.request(type: 'billing.discount', title: 'Own', amountPaise: 90000);
    expect(TowerDecisions.whyCannotApprove(app, own.approval), 'You cannot approve your own request');
    expect(TowerDecisions.whyCannotReject(app, own.approval), 'You cannot decide your own request');
    await expectLater(TowerDecisions.approve(app, own.approval), throwsA(isA<PermissionDeniedException>()));

    // Two approvals above the high-value limit: the same person can't give both.
    final big = (await app.store.query(const Query(Col.approvals).eq('type', 'billing.refund').eq('status', 'pending'))).single;
    await signInDemo(app, 'admin');
    expect(TowerDecisions.whyCannotApprove(app, big), isNotNull, reason: 'admin cannot approve');
    await signInDemo(app, 'board');
    final after = await TowerDecisions.approve(app, big, note: 'OK');
    expect(after.str('status'), 'applied', reason: 'owner approved first; board is the second person');
    expect(checks.appliedApprovals, contains(big.id));
    expect(approvalProgress(after), '2 of 2 approvals');

    final approved = await TowerDecisions.approve(app, req);
    expect(approved.str('status'), 'applied');
    expect(TowerDecisions.whyCannotApprove(app, approved), 'This request is no longer pending');
    await app.close();
  });

  testWidgets('approvals screen disables Approve for the requester and says why', (tester) async {
    final (app, _, _) = (await tester.runAsync(_boot))!;
    await tester.runAsync(() async {
      await signInDemo(app, 'board');
      await app.savePrefs({
        'seen_tour_steps': app.tourSteps().map((s) => s.id).toList(),
        'last_route': 'tower.approvals',
      });
    });
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(KendraApp(modules: app.registry.all, services: app));
    await tester.pump(const Duration(milliseconds: 300));
    app.nav.select('tower.approvals');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Board's own request: disabled, with the reason.
    expect(find.text('You cannot approve your own request'), findsOneWidget);
    final buttons = tester.widgetList<FilledButton>(find.ancestor(of: find.text('Approve'), matching: find.byType(FilledButton))).toList();
    expect(buttons, hasLength(3));
    expect(buttons.where((b) => b.onPressed == null), hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.close);
  });
}

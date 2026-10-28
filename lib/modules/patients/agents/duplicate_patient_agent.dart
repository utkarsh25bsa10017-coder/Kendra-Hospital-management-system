import 'package:kendra_hms/core/core.dart';

/// Looks for people registered twice (same mobile and similar name, or same
/// name and date of birth). Two UHIDs for one person splits their medical
/// history and their bills.
class DuplicatePatientAgent extends HmsAgent {
  @override
  String get id => 'patients.duplicates';
  @override
  String get name => 'Duplicate patients';
  @override
  String get description =>
      'Flags patients who seem to be registered more than once, so their history and bills stay in one record.';
  @override
  Set<String> get watches => const {Col.patients};
  @override
  Duration get interval => const Duration(hours: 6);

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final patients = await ctx.db.query(const Query(Col.patients).sort('created_at').take(20000));
    final byPhone = <String, List<Rec>>{};
    final byNameDob = <String, List<Rec>>{};
    for (final p in patients) {
      final phone = p.str('phone');
      if (phone.length >= 10) byPhone.putIfAbsent(phone, () => []).add(p);
      final dob = p.date('dob');
      if (dob != null) byNameDob.putIfAbsent('${_norm(p.str('full_name'))}|${dayKey(dob)}', () => []).add(p);
    }

    final findings = <FindingDraft>[];
    final seenPairs = <String>{};
    void pair(Rec a, Rec b, String why) {
      final ids = [a.id, b.id]..sort();
      final key = 'pair:${ids.join(':')}';
      if (!seenPairs.add(key)) return;
      findings.add(FindingDraft(
        key: key,
        title: 'Possible duplicate: ${a.str('full_name')}',
        summary: '${a.str('uhid')} and ${b.str('uhid')} $why. Check with the patient and keep one record.',
        severity: Severity.low,
        category: 'data quality',
        patientId: a.id,
        evidence: [
          Evidence('${a.str('full_name')} · ${a.str('uhid')}', collection: Col.patients, id: a.id, routeId: 'patients.profile', routeArgs: {'id': a.id}),
          Evidence('${b.str('full_name')} · ${b.str('uhid')}', collection: Col.patients, id: b.id, routeId: 'patients.profile', routeArgs: {'id': b.id}),
        ],
      ));
    }

    for (final group in byPhone.values.where((g) => g.length > 1)) {
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          final a = _norm(group[i].str('first_name'));
          final b = _norm(group[j].str('first_name'));
          // Same phone is normal for family members; only flag similar names.
          if (a.isNotEmpty && b.isNotEmpty && (a.startsWith(b) || b.startsWith(a))) {
            pair(group[i], group[j], 'share the mobile number ${group[i].str('phone')} and have similar names');
          }
        }
      }
    }
    for (final group in byNameDob.values.where((g) => g.length > 1)) {
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          pair(group[i], group[j], 'have the same name and date of birth');
        }
      }
    }
    return AgentReport(findings: findings);
  }
}

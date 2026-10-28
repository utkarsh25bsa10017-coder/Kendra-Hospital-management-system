import 'package:kendra_hms/core/core.dart';

import '../ipd_schema.dart';

/// Beds left in "cleaning" for more than four hours. A bed that is clean but
/// never marked ready looks full on the board and turns patients away.
class BedTurnaroundAgent extends HmsAgent {
  static const limit = Duration(hours: 4);

  @override
  String get id => 'ipd.bed_turnaround';
  @override
  String get name => 'Bed turnaround';
  @override
  String get description => 'Flags beds waiting for cleaning for more than 4 hours, so free beds are not hidden.';
  @override
  Set<String> get watches => const {IpdCol.beds};
  @override
  Duration get interval => const Duration(minutes: 30);

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    final beds = await ctx.db.query(Query(IpdCol.beds).eq('status', IpdVals.cleaning).take(1000));
    final wards = await ctx.db.byIds(IpdCol.wards, beds.map((b) => b.strOrNull('ward_id')));
    final findings = <FindingDraft>[];
    for (final b in beds) {
      if (b['active'] == false) continue;
      final since = b.date('status_since') ?? b.updatedAt;
      final waited = ctx.now.difference(since);
      if (waited < limit) continue;
      final ward = wards[b.str('ward_id')]?.str('name') ?? 'Ward';
      findings.add(FindingDraft(
        key: 'bed:${b.id}',
        title: 'Bed ${b.str('label')} waiting for cleaning for ${formatDuration(waited)}',
        summary: '${b.str('label')} in $ward has been in cleaning since ${formatDateTime(since)}. '
            'If it is ready, mark it ready on the bed board so it can be used.',
        severity: Severity.low,
        category: 'bed management',
        evidence: [Evidence('Bed ${b.str('label')} · $ward', collection: IpdCol.beds, id: b.id, routeId: 'ipd.beds')],
      ));
    }
    return AgentReport(findings: findings);
  }
}

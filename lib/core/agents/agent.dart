import 'dart:math' as math;

import '../data/db.dart';
import '../services/settings_service.dart';

enum Severity {
  info('Info'),
  low('Low'),
  medium('Medium'),
  high('High'),
  critical('Critical');

  const Severity(this.label);
  final String label;

  static Severity parse(String? s) =>
      Severity.values.firstWhere((v) => v.name == s, orElse: () => Severity.info);
}

/// A link from a finding to the record that proves it.
class Evidence {
  const Evidence(this.label, {this.collection, this.id, this.routeId, this.routeArgs = const {}});
  final String label;
  final String? collection;
  final String? id;

  /// Screen that shows this record, e.g. `billing.invoice` with {'id': ...}.
  final String? routeId;
  final Map<String, Object?> routeArgs;

  Map<String, Object?> toJson() => {
        'label': label,
        'collection': collection,
        'id': id,
        'route_id': routeId,
        'route_args': routeArgs,
      };
}

/// A problem the agent found. Reported again on every run while the problem
/// exists; when it stops being reported it is cleared automatically.
class FindingDraft {
  const FindingDraft({
    required this.key,
    required this.title,
    required this.summary,
    required this.severity,
    this.subjectKey,
    this.category,
    this.amountAtRiskPaise,
    this.patientId,
    this.evidence = const [],
    this.data = const {},
  });

  /// Unique within this agent and stable between runs, e.g. `invoice:<id>:line:<n>`.
  final String key;
  final String title;
  final String summary;
  final Severity severity;

  /// What the finding is about, for "don't flag this again" rules,
  /// e.g. `user:<id>` or `service:CONSULT`. Defaults to [key].
  final String? subjectKey;
  final String? category;
  final int? amountAtRiskPaise;
  final String? patientId;
  final List<Evidence> evidence;
  final Map<String, Object?> data;
}

/// An action the agent suggests. A person must approve it; the module's
/// [handler] then carries it out.
class ProposalDraft {
  const ProposalDraft({
    required this.key,
    required this.title,
    required this.summary,
    required this.handler,
    this.payload = const {},
    this.severity = Severity.low,
    this.requiredPermission = 'approvals.decide',
  });
  final String key;
  final String title;
  final String summary;

  /// Key in some module's `proposalHandlers`.
  final String handler;
  final Map<String, Object?> payload;
  final Severity severity;
  final String requiredPermission;
}

class AgentReport {
  const AgentReport({this.findings = const [], this.proposals = const []});
  final List<FindingDraft> findings;
  final List<ProposalDraft> proposals;
}

class AgentContext {
  AgentContext({required this.db, required this.settings, DateTime? now}) : now = now ?? DateTime.now();

  /// Agents can read everything and change nothing.
  final ReadDb db;
  final SettingsService settings;
  final DateTime now;

  DateTime get startOfToday => DateTime(now.year, now.month, now.day);
}

/// A monitoring agent. Agents run on the device that holds the data:
/// when a watched collection changes (debounced) and every [interval].
abstract class HmsAgent {
  /// `<module>.<agent>`, e.g. `billing.bill_matching`.
  String get id;
  String get name;

  /// One or two sentences, shown on the Agents screen.
  String get description;

  Set<String> get watches => const {};
  Duration get interval => const Duration(hours: 1);
  bool get enabledByDefault => true;

  Future<AgentReport> run(AgentContext ctx);
}

/// Simple statistics for anomaly checks ("vs. the 90-day normal").
abstract final class Stats {
  static double mean(Iterable<num> xs) => xs.isEmpty ? 0 : xs.fold<double>(0, (a, b) => a + b) / xs.length;

  static double stdDev(Iterable<num> xs) {
    if (xs.length < 2) return 0;
    final m = mean(xs);
    final v = xs.fold<double>(0, (a, b) => a + (b - m) * (b - m)) / (xs.length - 1);
    return math.sqrt(v);
  }

  /// How unusual [value] is compared with [history]. Returns 0 when there is
  /// not enough history to judge.
  static double zScore(num value, Iterable<num> history, {int minSamples = 7}) {
    if (history.length < minSamples) return 0;
    final sd = stdDev(history);
    if (sd == 0) return value > mean(history) ? 3 : 0;
    return (value - mean(history)) / sd;
  }
}

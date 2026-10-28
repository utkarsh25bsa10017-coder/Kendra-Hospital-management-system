import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';

enum _Filter { all, today, partial }

class _Queue {
  _Queue(this.waiting, this.patients, this.doctors, this.encounters, this.dispensedToday);
  final List<Rec> waiting;
  final Map<String, Rec> patients;
  final Map<String, Rec> doctors;
  final Map<String, Rec> encounters;
  final List<Rec> dispensedToday;

  /// When the prescription reached the pharmacy: the end of the visit when
  /// that is known, otherwise when it was saved.
  DateTime prescribedAt(Rec rx) {
    final e = encounters[rx.str('encounter_id')];
    final t = e?.date('ended_at');
    return t != null && t.isBefore(rx.createdAt) ? t : rx.createdAt;
  }
}

/// The pharmacy counter: prescriptions waiting (today first, longest wait
/// at the top) and what has been handed out today.
class DispenseQueueScreen extends StatefulWidget {
  const DispenseQueueScreen({super.key});

  @override
  State<DispenseQueueScreen> createState() => _DispenseQueueScreenState();
}

class _DispenseQueueScreenState extends State<DispenseQueueScreen> {
  String _search = '';
  _Filter _filter = _Filter.all;

  Future<_Queue> _load(ReadDb db) async {
    final today = startOfDay(DateTime.now());
    final rx = await db.query(const Query(Col.prescriptions)
        .isIn('status', [Vals.active, Vals.partiallyDispensed])
        .sort('created_at')
        .take(300));
    final dispensed = await db.query(
        Query(PCol.dispenses).gte('dispensed_at', today).sort('dispensed_at', desc: true).take(100));
    final patients = await db.byIds(Col.patients, [...rx.map((r) => r.strOrNull('patient_id')), ...dispensed.map((d) => d.strOrNull('patient_id'))]);
    final doctors = await db.byIds(Col.users, rx.map((r) => r.strOrNull('doctor_id')));
    final encounters = await db.byIds(Col.encounters, rx.map((r) => r.strOrNull('encounter_id')));
    return _Queue(rx, patients, doctors, encounters, dispensed);
  }

  bool _matches(_Queue q, Rec rx) {
    if (_search.isEmpty) return true;
    final p = q.patients[rx.str('patient_id')];
    final d = q.doctors[rx.str('doctor_id')];
    final text = '${p?.str('full_name')} ${p?.str('uhid')} ${p?.str('phone')} ${d?.str('display_name')}'.toLowerCase();
    return _search.toLowerCase().split(RegExp(r'\s+')).every(text.contains);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canDispense = context.can(PharmacyPerms.dispense);
    return PageScaffold(
      title: 'Pharmacy',
      subtitle: 'Prescriptions from doctors, waiting to be dispensed',
      primaryAction: canDispense
          ? PageAction('Counter sale', Icons.point_of_sale_outlined, () => app.nav.open('pharmacy.sale'),
              tourAnchor: 'pharmacy.counter_sale')
          : null,
      headerBottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchField(hint: 'Patient name, UHID or doctor', onChanged: (v) => setState(() => _search = v)),
          Gap.v12,
          FilterChips<_Filter>(
            options: const [(_Filter.all, 'All waiting'), (_Filter.today, 'Prescribed today'), (_Filter.partial, 'Part dispensed')],
            value: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),
        ],
      ),
      body: LiveBuilder<_Queue>(
        watch: const {Col.prescriptions, PCol.dispenses},
        load: _load,
        builder: (context, q) {
          final now = DateTime.now();
          final today = startOfDay(now);
          final list = q.waiting.where((r) => _matches(q, r)).where((r) => switch (_filter) {
                _Filter.all => true,
                _Filter.today => !q.prescribedAt(r).isBefore(today),
                _Filter.partial => r.str('status') == Vals.partiallyDispensed,
              });
          final todays = list.where((r) => !q.prescribedAt(r).isBefore(today)).toList()
            ..sort((a, b) => q.prescribedAt(a).compareTo(q.prescribedAt(b)));
          final earlier = list.where((r) => q.prescribedAt(r).isBefore(today)).toList()
            ..sort((a, b) => q.prescribedAt(b).compareTo(q.prescribedAt(a)));
          final first = todays.isNotEmpty ? todays.first : (earlier.isNotEmpty ? earlier.first : null);
          final sales = q.dispensedToday.fold<int>(0, (a, d) => a + d.integer('total_paise'));
          final oldestWait = todays.isEmpty ? null : now.difference(q.prescribedAt(todays.first));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Stats(stats: [
                ('${q.waiting.length}', 'Waiting'),
                (oldestWait == null ? '—' : formatDuration(oldestWait), 'Longest wait today'),
                ('${q.dispensedToday.where((d) => d.str('kind') != DispenseKind.returned).length}', 'Dispensed today'),
                (formatMoneyShort(sales), 'Sales today'),
              ]),
              Gap.v16,
              if (todays.isEmpty && earlier.isEmpty)
                Card(
                  child: EmptyState(
                    icon: Icons.task_alt,
                    title: _search.isEmpty ? 'No prescriptions waiting' : 'No waiting prescription matches "$_search"',
                    message: 'New prescriptions appear here as soon as the doctor saves them.',
                  ),
                ),
              if (todays.isNotEmpty) ...[
                const SubHeading('Today'),
                _RxList(items: todays, q: q, first: first, canDispense: canDispense, today: true),
              ],
              if (earlier.isNotEmpty) ...[
                Gap.v8,
                const SubHeading('Earlier'),
                _RxList(items: earlier, q: q, first: first, canDispense: canDispense, today: false),
              ],
              Gap.v24,
              SectionCard(
                title: 'Handed out today',
                subtitle: q.dispensedToday.isEmpty
                    ? 'Nothing yet'
                    : '${plural(q.dispensedToday.length, 'dispense')} · ${formatMoney(sales)}',
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
                child: q.dispensedToday.isEmpty
                    ? const SizedBox.shrink()
                    : _DispensedList(items: q.dispensedToday.take(30).toList(), patients: q.patients),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.stats});
  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell((String, String) s) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              Text(s.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        );
    return Card(
      child: LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth < 520 ? 2 : stats.length;
        final w = c.maxWidth / cols;
        return Wrap(children: [for (final s in stats) SizedBox(width: w, child: cell(s))]);
      }),
    );
  }
}

class _RxList extends StatelessWidget {
  const _RxList({required this.items, required this.q, required this.first, required this.canDispense, required this.today});
  final List<Rec> items;
  final _Queue q;
  final Rec? first;
  final bool canDispense;
  final bool today;

  String _medicines(Rec rx) {
    final names = rx.maps('items').map((i) => '${i['drug_name'] ?? ''}').where((s) => s.isNotEmpty).toList();
    return names.join(', ');
  }

  String _wait(Rec rx) {
    final t = q.prescribedAt(rx);
    final d = DateTime.now().difference(t);
    return today ? 'waiting ${formatDuration(d)}' : formatRelative(t);
  }

  Widget _status(Rec rx) => rx.str('status') == Vals.partiallyDispensed
      ? const StatusChip('Part dispensed', tone: Tone.warning)
      : (today && DateTime.now().difference(q.prescribedAt(rx)).inMinutes >= 30)
          ? const StatusChip('Waiting long', tone: Tone.danger)
          : const StatusChip('New', tone: Tone.info);

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    void open(Rec rx) => canDispense
        ? app.nav.open('pharmacy.dispense_rx', {'prescriptionId': rx.id})
        : app.nav.open('patients.profile', {'id': rx.str('patient_id')});
    Widget button(Rec rx) {
      final b = FilledButton.tonal(onPressed: () => open(rx), child: const Text('Dispense'));
      return identical(rx, first) ? TourAnchor(id: 'pharmacy.dispense_button', child: b) : b;
    }

    return DataList<Rec>(
      items: items,
      onTap: open,
      title: (rx) => q.patients[rx.str('patient_id')]?.str('full_name') ?? 'Patient',
      subtitle: (rx) => [
        q.doctors[rx.str('doctor_id')]?.str('display_name') ?? '',
        plural(rx.maps('items').length, 'medicine'),
        _wait(rx),
      ].where((s) => s.isNotEmpty).join(' · '),
      trailing: (rx) => identical(rx, first) && canDispense
          ? TourAnchor(id: 'pharmacy.dispense_button', child: _status(rx))
          : _status(rx),
      columns: [
        ListColumn('Patient', (rx) {
          final p = q.patients[rx.str('patient_id')];
          return Row(children: [
            Avatar(p?.str('full_name') ?? '?', size: 32),
            Gap.h12,
            Expanded(
                child: TwoLine(p?.str('full_name') ?? 'Patient',
                    [p?.str('uhid') ?? '', ageLabel(p?.date('dob'), p?.intOrNull('age_years'))].where((s) => s.isNotEmpty && s != '—').join(' · '))),
          ]);
        }, flex: 4),
        ListColumn('Doctor', (rx) {
          final d = q.doctors[rx.str('doctor_id')];
          return TwoLine(d?.str('display_name') ?? '—', d?.str('department'));
        }, flex: 3),
        ListColumn('Medicines', (rx) => TwoLine(plural(rx.maps('items').length, 'medicine'), _medicines(rx)), flex: 4),
        ListColumn('Prescribed', (rx) => TwoLine(today ? formatTime(q.prescribedAt(rx)) : formatDateShort(q.prescribedAt(rx)), _wait(rx)),
            flex: 3),
        ListColumn('Status', _status, width: 130),
        if (canDispense) ListColumn('', button, width: 124),
      ],
    );
  }
}

class _DispensedList extends StatelessWidget {
  const _DispensedList({required this.items, required this.patients});
  final List<Rec> items;
  final Map<String, Rec> patients;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (i, d) in items.indexed) ...[
          if (i > 0) const Divider(height: 1),
          InkWell(
            onTap: () => context.app.nav.open('pharmacy.dispense_summary', {'id': d.id}),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm + 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(formatTime(d.date('dispensed_at')),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: TwoLine(
                      patients[d.str('patient_id')]?.str('full_name') ?? 'Patient',
                      '${d.str('number')} · ${d.maps('items').map((x) => x['name']).toSet().join(', ')}',
                    ),
                  ),
                  Gap.h8,
                  if (!context.isCompact) ...[
                    switch (d.str('kind')) {
                      DispenseKind.returned => const StatusChip('Return', tone: Tone.info),
                      DispenseKind.counter => const StatusChip('Counter'),
                      _ => const StatusChip('Prescription', tone: Tone.success),
                    },
                    Gap.h12,
                  ],
                  SizedBox(
                    width: 96,
                    child: Align(alignment: Alignment.centerRight, child: MoneyText(d.integer('total_paise'))),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

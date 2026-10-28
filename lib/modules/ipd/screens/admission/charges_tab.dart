import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../../ipd_schema.dart';
import '../admission_screen.dart';

/// Everything charged to this stay so far (bed-days and whatever other
/// departments have added), read from core `charges`.
class ChargesTab extends StatelessWidget {
  const ChargesTab({super.key, required this.view});
  final AdmissionView view;

  Future<List<Rec>> _load(ReadDb db) async {
    final a = view.admission;
    final enc = a.strOrNull('encounter_id');
    final byId = <String, Rec>{
      if (enc != null)
        for (final c in await db.query(Query(Col.charges).eq('encounter_id', enc).sort('service_date', desc: true).take(1000))) c.id: c,
      for (final c in await db.query(Query(Col.charges)
          .eq('source_collection', IpdCol.admissions)
          .startsWith('source_id', '${a.id}:')
          .sort('service_date', desc: true)
          .take(1000)))
        c.id: c,
    };
    final list = byId.values.toList()
      ..sort((x, y) {
        final d = (y.date('service_date') ?? y.createdAt).compareTo(x.date('service_date') ?? x.createdAt);
        return d != 0 ? d : x.str('category').compareTo(y.str('category'));
      });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final patientId = view.admission.str('patient_id');
    return LiveBuilder<List<Rec>>(
      watch: const {Col.charges},
      deps: [view.admission.id],
      load: _load,
      builder: (context, charges) {
        final live = charges.where((c) => c.str('status') != Vals.cancelled).toList();
        final total = live.fold<int>(0, (a, c) => a + c.integer('amount_paise'));
        final pending = live.where((c) => c.str('status') == Vals.pending).fold<int>(0, (a, c) => a + c.integer('amount_paise'));
        final bedDays = {
          for (final c in live)
            if (c.str('category') == Vals.bed && c.date('service_date') != null) dayKey(c.date('service_date')!),
        };
        final lastBedDay = live
            .where((c) => c.str('category') == Vals.bed)
            .map((c) => c.date('service_date'))
            .whereType<DateTime>()
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg, horizontal: Gap.sm),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      _Stat(label: 'Charges so far', value: formatMoney(total, alwaysDecimals: false), caption: plural(live.length, 'item')),
                      const VerticalDivider(width: 1),
                      _Stat(
                        label: 'Bed-days charged',
                        value: '${bedDays.length}',
                        caption: lastBedDay == null ? 'None yet' : 'Up to ${formatDateShort(lastBedDay)}',
                      ),
                      const VerticalDivider(width: 1),
                      _Stat(
                        label: 'Not yet billed',
                        value: formatMoney(pending, alwaysDecimals: false),
                        caption: pending > 0 ? 'Waiting for a bill' : 'All on a bill',
                        tone: pending > 0 ? Tone.warning : Tone.success,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Gap.v16,
            Wrap(
              spacing: Gap.md,
              runSpacing: Gap.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.app.nav.open('billing.invoice', {'patientId': patientId}),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Open bill'),
                ),
                Text(
                  view.discharged
                      ? 'All bed-days of this stay have been charged.'
                      : 'Bed and nursing charges are added for each day automatically; today is added after midnight.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            Gap.v16,
            DataList<Rec>(
              items: charges,
              empty: const SectionCard(
                child: EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No charges yet',
                  message: 'The admission day is charged within the hour.',
                ),
              ),
              title: (c) => c.str('description'),
              subtitle: (c) => [
                formatDate(c.date('service_date') ?? c.createdAt),
                titleCase(c.str('category')),
                if (c.integer('quantity', 1) != 1) 'Qty ${c.integer('quantity')}',
              ].join(' · '),
              trailing: (c) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [MoneyText(c.integer('amount_paise'), style: theme.textTheme.titleSmall), Gap.v4, _statusChip(c)],
              ),
              columns: [
                ListColumn('Date', (c) => Text(formatDate(c.date('service_date') ?? c.createdAt)), flex: 2),
                ListColumn('Item', (c) => Text(c.str('description'), overflow: TextOverflow.ellipsis), flex: 5),
                ListColumn('Type', (c) => Text(titleCase(c.str('category')))),
                ListColumn('Qty', (c) => Text('${c.integer('quantity', 1)}'), width: 56, numeric: true),
                ListColumn('Amount', (c) => MoneyText(c.integer('amount_paise')), numeric: true),
                ListColumn('Status', _statusChip, width: 110),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _statusChip(Rec c) => switch (c.str('status')) {
        Vals.billed => const StatusChip('Billed', tone: Tone.success),
        Vals.cancelled => const StatusChip('Cancelled', tone: Tone.danger),
        _ => const StatusChip('Pending', tone: Tone.warning),
      };
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.caption, this.tone});
  final String label;
  final String value;
  final String caption;
  final Tone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            Gap.v4,
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: theme.textTheme.titleLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: tone == null ? null : ToneColors.of(context, tone!).foreground)),
            ),
            Gap.v4,
            Text(caption, style: theme.textTheme.bodySmall?.copyWith(color: muted), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

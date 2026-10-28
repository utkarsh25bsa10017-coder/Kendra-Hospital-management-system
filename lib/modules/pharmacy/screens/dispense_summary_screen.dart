import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';
import '../pharmacy_service.dart';
import 'pharmacy_widgets.dart';

class _Slip {
  _Slip(this.d, this.patient, this.doctor, this.returns, this.returned, this.original, this.charges);
  final Rec d;
  final Rec? patient;
  final Rec? doctor;
  final List<Rec> returns;
  final Map<int, int> returned;
  final Rec? original;
  final List<Rec> charges;
}

/// The dispense slip: what was given from which batch, at what price. Laid
/// out like a printed pharmacy bill so it can be handed over or shared.
class DispenseSummaryScreen extends StatelessWidget {
  const DispenseSummaryScreen({super.key, required this.dispenseId});
  final String dispenseId;

  Future<_Slip?> _load(ReadDb db) async {
    final d = await db.get(PCol.dispenses, dispenseId);
    if (d == null) return null;
    final returns = await db.query(Query(PCol.dispenses).eq('return_of', d.id).sort('dispensed_at').take(50));
    final charges = await db.query(Query(Col.charges).startsWith('source_id', '${d.id}:').take(200));
    return _Slip(
      d,
      await db.get(Col.patients, d.strOrNull('patient_id')),
      await db.get(Col.users, d.strOrNull('doctor_id')),
      returns,
      await PharmacyService.returnedSoFar(db, d.id),
      await db.get(PCol.dispenses, d.strOrNull('return_of')),
      charges,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LiveBuilder<_Slip?>(
      watch: const {PCol.dispenses, Col.charges},
      deps: [dispenseId],
      load: _load,
      builder: (context, s) {
        if (s == null) {
          return const PageScaffold(title: 'Dispense', body: EmptyState(icon: Icons.search_off, title: 'Not found'));
        }
        return _SlipPage(slip: s);
      },
    );
  }
}

class _SlipPage extends StatelessWidget {
  const _SlipPage({required this.slip});
  final _Slip slip;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final d = slip.d;
    final isReturn = d.str('kind') == DispenseKind.returned;
    final canReturn = !isReturn && context.can(PharmacyPerms.dispense) &&
        d.maps('items').indexed.any((e) => ((e.$2['qty'] as num?)?.toInt() ?? 0) > (slip.returned[e.$1] ?? 0));
    final hospital = app.settings.hospitalName;
    final text = PharmacyService.dispenseText(d,
        patient: '${slip.patient?.str('full_name') ?? ''} · ${slip.patient?.str('uhid') ?? ''}', hospital: hospital);

    return PageScaffold(
      title: isReturn ? 'Return ${d.str('number')}' : 'Dispensed ${d.str('number')}',
      subtitle: '${slip.patient?.str('full_name') ?? 'Patient'} · ${formatDateTime(d.date('dispensed_at'))}',
      maxWidth: 820,
      actions: [
        IconButton(
            tooltip: 'Copy slip as text',
            onPressed: () => copyText(context, text, 'Slip'),
            icon: const Icon(Icons.copy_all_outlined)),
        if (slip.patient != null && !context.isCompact)
          IconButton(
              tooltip: 'Open patient',
              onPressed: () => app.nav.open('patients.profile', {'id': slip.patient!.id}),
              icon: const Icon(Icons.person_outline)),
      ],
      primaryAction: context.can(PharmacyPerms.dispense)
          ? PageAction('Next patient', Icons.arrow_forward, () => app.nav.select('pharmacy.dispense'))
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SlipCard(slip: slip, hospital: hospital),
          Gap.v16,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              if (canReturn)
                OutlinedButton.icon(
                  onPressed: () => _return(context),
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: const Text('Return items'),
                ),
              OutlinedButton.icon(
                onPressed: () => copyText(context, text, 'Slip'),
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copy for WhatsApp'),
              ),
              if (slip.original != null)
                OutlinedButton.icon(
                  onPressed: () => app.nav.open('pharmacy.dispense_summary', {'id': slip.original!.id}),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text('Original ${slip.original!.str('number')}'),
                ),
              for (final r in slip.returns)
                OutlinedButton.icon(
                  onPressed: () => app.nav.open('pharmacy.dispense_summary', {'id': r.id}),
                  icon: const Icon(Icons.assignment_return_outlined),
                  label: Text('Return ${r.str('number')}'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _return(BuildContext context) async {
    final app = context.app;
    final d = slip.d;
    final result = await showFormSheet<(Map<int, int>, String)>(
      context,
      title: 'Return medicines',
      builder: (c) => _ReturnForm(items: d.maps('items'), returned: slip.returned),
    );
    if (result == null || !context.mounted) return;
    Rec? saved;
    final ok = await runGuarded(context, () async {
      saved = await PharmacyService.returnItems(app.db,
          dispense: d, qtyByLine: result.$1, reason: result.$2, byName: app.auth.session?.displayName ?? 'Pharmacist');
    });
    if (ok && saved != null) {
      app.nav.toast('Returned to stock · ${formatMoney(-saved!.integer('total_paise'))} credited to the bill');
    }
  }
}

class _SlipCard extends StatelessWidget {
  const _SlipCard({required this.slip, required this.hospital});
  final _Slip slip;
  final String hospital;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.app;
    final d = slip.d;
    final p = slip.patient;
    final isReturn = d.str('kind') == DispenseKind.returned;
    final compact = context.isCompact;
    final items = d.maps('items');
    final pending = slip.charges.where((c) => c.str('status') == Vals.pending).length;
    final billed = slip.charges.where((c) => c.str('status') == Vals.billed).length;
    final label = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? Gap.lg : Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(hospital, style: theme.textTheme.titleMedium),
                    Muted([app.settings.str(SettingKeys.hospitalAddress), app.settings.str(SettingKeys.hospitalPhone)]
                        .where((s) => s.isNotEmpty)
                        .join(' · ')),
                  ]),
                ),
                Gap.h12,
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(isReturn ? 'Medicine return' : 'Pharmacy bill', style: theme.textTheme.titleSmall),
                  Muted(d.str('number')),
                ]),
              ],
            ),
            const Divider(height: Gap.xl),
            InfoGrid([
              ('Patient', p == null ? '—' : '${p.str('full_name')} · ${p.str('uhid')}'),
              ('Date', formatDateTime(d.date('dispensed_at'))),
              ('Doctor', slip.doctor?.str('display_name') ?? (d.str('kind') == DispenseKind.counter ? 'Counter sale' : '—')),
              (isReturn ? 'Received back by' : 'Dispensed by', d.str('dispensed_by_name')),
              if (isReturn) ('Reason', d.str('reason')),
            ], minItemWidth: 180),
            Gap.v16,
            if (!compact)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Row(children: [
                  Expanded(flex: 5, child: Text('Medicine', style: label)),
                  Expanded(flex: 3, child: Text('Batch · expiry', style: label)),
                  SizedBox(width: 120, child: Text('Qty × MRP', style: label, textAlign: TextAlign.right)),
                  SizedBox(width: 110, child: Text('Amount', style: label, textAlign: TextAlign.right)),
                ]),
              ),
            const Divider(height: 1),
            for (final (i, it) in items.indexed) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm + 2),
                child: _ItemRow(item: it, returned: isReturn ? 0 : (slip.returned[i] ?? 0), compact: compact),
              ),
              const Divider(height: 1),
            ],
            Gap.v12,
            Row(children: [
              Expanded(child: Text(isReturn ? 'Credit' : 'Total', style: theme.textTheme.titleMedium)),
              MoneyText(d.integer('total_paise'), style: theme.textTheme.titleLarge),
            ]),
            Gap.v12,
            NoticeBox(
              tone: billed > 0 ? Tone.success : Tone.info,
              icon: Icons.receipt_long_outlined,
              title: isReturn
                  ? 'The credit is with billing'
                  : billed > 0
                      ? 'Billed'
                      : 'Charges sent to billing',
              lines: [
                isReturn
                    ? 'Pending charges were cancelled; billed ones get a credit line on the bill.'
                    : '${plural(slip.charges.length, 'charge')}: $pending pending, $billed billed. The patient pays at the billing counter.',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.returned, required this.compact});
  final Map<String, Object?> item;
  final int returned;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qty = (item['qty'] as num?)?.toInt() ?? 0;
    final mrp = (item['mrp_paise'] as num?)?.toInt() ?? 0;
    final exp = DateTime.tryParse('${item['expiry']}');
    final batch = 'Batch ${item['batch_no']} · exp ${PharmacyService.expiryLabel(exp)}';
    final name = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${item['name']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      if (compact) Muted(batch),
      if (returned > 0) Text('$returned returned', style: theme.textTheme.bodySmall?.copyWith(color: ToneColors.of(context, Tone.info).foreground)),
    ]);
    final amount = MoneyText((item['amount_paise'] as num?)?.toInt());
    if (compact) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: name),
        Gap.h8,
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [amount, Muted('$qty × ${formatMoney(mrp)}')]),
      ]);
    }
    return Row(children: [
      Expanded(flex: 5, child: name),
      Expanded(flex: 3, child: Muted(batch)),
      SizedBox(width: 120, child: Text('$qty × ${formatMoney(mrp)}', textAlign: TextAlign.right)),
      SizedBox(width: 110, child: Align(alignment: Alignment.centerRight, child: amount)),
    ]);
  }
}

class _ReturnForm extends StatefulWidget {
  const _ReturnForm({required this.items, required this.returned});
  final List<Map<String, Object?>> items;
  final Map<int, int> returned;

  @override
  State<_ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends State<_ReturnForm> {
  final _qty = <int, int>{};
  final _reason = TextEditingController();
  static const _presets = ['Unopened, bought extra', 'Doctor changed the medicine', 'Patient discharged / stopped', 'Wrong medicine given'];

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = [
      for (final e in _qty.entries) e.value * ((widget.items[e.key]['mrp_paise'] as num?)?.toInt() ?? 0)
    ].fold<int>(0, (a, b) => a + b);
    final ok = _qty.values.any((v) => v > 0) && _reason.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Muted('Returned medicines go back to the same batch. Only take back sealed strips and bottles.'),
        Gap.v12,
        for (final (i, it) in widget.items.indexed)
          Builder(builder: (context) {
            final left = ((it['qty'] as num?)?.toInt() ?? 0) - (widget.returned[i] ?? 0);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Gap.md,
                runSpacing: Gap.sm,
                children: [
                  SizedBox(
                    width: 240,
                    child: TwoLine('${it['name']}', 'Batch ${it['batch_no']} · $left can come back'),
                  ),
                  QtyStepper(value: _qty[i] ?? 0, max: left < 0 ? 0 : left, onChanged: (v) => setState(() => _qty[i] = v)),
                ],
              ),
            );
          }),
        Gap.v12,
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final p in _presets) ActionChip(label: Text(p), onPressed: () => setState(() => _reason.text = p)),
        ]),
        Gap.v12,
        AppTextField(label: 'Reason', controller: _reason, maxLines: 2, onChanged: (_) => setState(() {})),
        Gap.v16,
        Row(children: [
          Expanded(child: Muted('Credit ${formatMoney(total)}')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton(
            onPressed: ok ? () => Navigator.pop(context, (_qty, _reason.text.trim())) : null,
            child: const Text('Take back'),
          ),
        ]),
      ],
    );
  }
}

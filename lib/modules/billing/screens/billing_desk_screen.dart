import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'billing_widgets.dart';
import 'invoice_sheets.dart';

class _DeskData {
  _DeskData(this.ready, this.drafts, this.today, this.waitingApproval, this.collectedToday, this.myCollected);
  final List<ReadyToBill> ready;
  final List<Rec> drafts;
  final List<Rec> today;
  final Set<String> waitingApproval;
  final int collectedToday;
  final int myCollected;

  static Future<_DeskData> load(ReadDb db, String search, String? me) async {
    final now = DateTime.now();
    var ready = await BillingService.readyToBill(db);
    final s = search.trim().toLowerCase();
    if (s.isNotEmpty) {
      ready = ready.where((r) {
        final p = r.patient;
        return [p.str('full_name'), p.str('uhid'), p.str('phone')].any((v) => v.toLowerCase().contains(s));
      }).toList();
    }
    final drafts = await db.query(
        Query(BillCol.invoices).eq('status', InvoiceStatus.draft).matching(search).sort('created_at', desc: true).take(50));
    final today = await db.query(Query(BillCol.invoices)
        .eq('kind', InvoiceKind.invoice)
        .gte('finalised_at', startOfDay(now))
        .matching(search)
        .sort('finalised_at', desc: true)
        .take(60));
    final waiting = {
      for (final a in await db.query(const Query(Col.approvals)
          .eq('type', BillingApprovals.discount)
          .eq('status', 'pending')
          .take(200)))
        a.str('subject_id'),
    };
    final payments = await db.query(Query(BillCol.payments).gte('received_at', startOfDay(now)).take(3000));
    var all = 0;
    var mine = 0;
    for (final p in payments) {
      final v = (p.str('kind') == PaymentKind.refund ? -1 : 1) * p.integer('amount_paise');
      all += v;
      if (p.str('received_by') == me) mine += v;
    }
    return _DeskData(ready, drafts, today, waiting, all, mine);
  }
}

/// The counter: who is waiting to be billed, open drafts and today's bills.
class BillingDeskScreen extends StatefulWidget {
  const BillingDeskScreen({super.key});

  @override
  State<BillingDeskScreen> createState() => _BillingDeskScreenState();
}

class _BillingDeskScreenState extends State<BillingDeskScreen> {
  String _search = '';

  Future<void> _newBill(BuildContext context) async {
    final p = await pickPatient(context, title: 'Bill which patient?');
    if (p == null || !context.mounted) return;
    await openBillForPatient(context, p.id);
  }

  @override
  Widget build(BuildContext context) {
    final canBill = context.can(BillingPerms.invoice);
    final canPay = context.can(BillingPerms.payment);
    final me = context.session?.userId;
    return PageScaffold(
      title: 'Billing',
      subtitle: 'Bills put themselves together from what the departments charged. Check, take payment, done.',
      primaryAction: canBill ? PageAction('New bill', Icons.add, () => _newBill(context), tourAnchor: 'billing.new') : null,
      headerBottom: SearchField(hint: 'Find a patient by name, UHID or mobile', onChanged: (v) => setState(() => _search = v)),
      body: LiveBuilder<_DeskData>(
        watch: const {Col.charges, BillCol.invoices, BillCol.payments, Col.approvals},
        deps: [_search, me],
        load: (db) => _DeskData.load(db, _search, me),
        builder: (context, d) {
          final waitingTotal = d.ready.fold<int>(0, (a, r) => a + r.total);
          final billedToday = d.today.where((b) => b.str('status') != InvoiceStatus.draft).toList();
          final billedNet = billedToday.fold<int>(0, (a, b) => a + b.integer('net_paise'));
          String whole(int p) => formatMoney(p, alwaysDecimals: false);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minWidth: 170, spacing: Gap.md, children: [
              KpiTile(
                label: 'To be billed',
                value: whole(waitingTotal),
                caption: plural(d.ready.length, 'patient'),
                icon: Icons.pending_actions_outlined,
                tone: d.ready.isEmpty ? Tone.success : Tone.warning,
              ),
              KpiTile(
                label: 'Open drafts',
                value: '${d.drafts.length}',
                caption: d.drafts.isEmpty
                    ? 'None open'
                    : '${whole(d.drafts.fold<int>(0, (a, b) => a + b.integer('net_paise')))} not finalised',
                icon: Icons.edit_note,
              ),
              KpiTile(
                label: 'Billed today',
                value: whole(billedNet),
                caption: plural(billedToday.length, 'bill'),
                icon: Icons.receipt_long_outlined,
                tone: Tone.info,
              ),
              KpiTile(
                label: 'Collected today',
                value: whole(d.collectedToday),
                caption: canPay ? 'You took ${whole(d.myCollected)}' : 'All counters',
                icon: Icons.payments_outlined,
                tone: Tone.success,
              ),
            ]),
            Gap.v24,
            TourAnchor(id: 'billing.ready', child: _ReadyList(ready: d.ready, canBill: canBill, search: _search)),
            if (d.drafts.isNotEmpty) ...[
              Gap.v24,
              TourAnchor(id: 'billing.drafts', child: _DraftList(drafts: d.drafts, waiting: d.waitingApproval)),
            ],
            Gap.v24,
            TourAnchor(id: 'billing.today', child: _TodayList(bills: d.today, canPay: canPay)),
          ]);
        },
      ),
    );
  }
}

class _ReadyList extends StatelessWidget {
  const _ReadyList({required this.ready, required this.canBill, required this.search});
  final List<ReadyToBill> ready;
  final bool canBill;
  final String search;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = ToneColors.of(context, Tone.warning).foreground;
    void bill(ReadyToBill r) => openBillForPatient(context, r.patient.id);
    String who(Rec p) => [
          p.str('uhid'),
          [ageLabel(p.date('dob'), p.intOrNull('age_years')), genderLabel(p.strOrNull('gender')).characters.first]
              .where((s) => s.isNotEmpty && s != '—')
              .join(' '),
        ].where((s) => s.isNotEmpty).join(' · ');
    Widget waited(ReadyToBill r) {
      if (r.inWard) return const StatusChip('In ward', icon: Icons.hotel_outlined, tone: Tone.info);
      final old = DateTime.now().difference(r.oldest) > const Duration(hours: 24);
      return StatusChip(waitingLabel(r.oldest), icon: Icons.schedule, tone: old ? Tone.warning : Tone.neutral);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BillSectionHeader(
        'Ready to bill',
        subtitle: canBill
            ? 'Patients whose charges are not on a bill yet. One tap makes the bill from all of them.'
            : 'Patients whose charges are not on a bill yet.',
      ),
      DataList<ReadyToBill>(
        items: ready,
        empty: Card(
          child: EmptyState(
            icon: Icons.task_alt,
            title: search.isEmpty ? 'All caught up' : 'Nobody waiting matches "$search"',
            message: 'Charges from OPD, lab, pharmacy and the wards show up here as soon as they are posted.',
          ),
        ),
        onTap: canBill ? bill : null,
        leading: (r) => Avatar(r.patient.str('full_name'), size: 36),
        title: (r) => r.patient.str('full_name'),
        subtitle: (r) => '${who(r.patient)}\n${plural(r.charges.length, 'item')} · ${r.categories.join(', ')} · '
            '${r.inWard ? 'in ward' : 'waiting ${waitingLabel(r.oldest)}'}',
        trailing: (r) => Row(mainAxisSize: MainAxisSize.min, children: [
          MoneyText(r.total, style: theme.textTheme.titleSmall),
          if (canBill) Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ]),
        columns: [
          ListColumn('Patient', (r) => Row(children: [
                Avatar(r.patient.str('full_name'), size: 32),
                Gap.h12,
                Expanded(child: TwoLine(r.patient.str('full_name'), who(r.patient))),
              ]), flex: 5),
          ListColumn('Items', (r) => TwoLine(plural(r.charges.length, 'item'), r.categories.join(', ')), flex: 4),
          ListColumn('Waiting', waited, width: 124),
          ListColumn('Amount', (r) => MoneyText(r.total, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              width: 120, numeric: true),
          if (canBill)
            ListColumn('', (r) => RowAction('Create bill', onPressed: () => bill(r)), width: 140, numeric: true),
        ],
      ),
      if (ready.any((r) => !r.inWard && DateTime.now().difference(r.oldest) > const Duration(days: 1)))
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Row(children: [
            Icon(Icons.info_outline, size: 16, color: warn),
            Gap.h8,
            const Expanded(child: MutedText('Charges waiting more than a day after a visit closes are flagged to the board as possible leakage.')),
          ]),
        ),
    ]);
  }
}

class _DraftList extends StatelessWidget {
  const _DraftList({required this.drafts, required this.waiting});
  final List<Rec> drafts;
  final Set<String> waiting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open(Rec b) => context.app.nav.open('billing.invoice', {'id': b.id});
    Widget state(Rec b) => waiting.contains(b.id)
        ? const StatusChip('Waiting for approval', icon: Icons.hourglass_top, tone: Tone.warning)
        : const StatusChip('Draft', icon: Icons.edit_note);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const BillSectionHeader('Drafts', subtitle: 'Bills started but not finalised. Finalise them before the patient leaves.'),
      DataList<Rec>(
        items: drafts,
        onTap: open,
        title: (b) => b.str('patient_name'),
        subtitle: (b) => '${b.str('number')} · started ${formatRelative(b.createdAt)}'
            '${waiting.contains(b.id) ? ' · discount waiting for approval' : ''}',
        trailing: (b) => MoneyText(b.integer('net_paise'), style: theme.textTheme.titleSmall),
        columns: [
          ListColumn('Draft', (b) => TwoLine(b.str('number'), 'Started ${formatRelative(b.createdAt)}'), flex: 3),
          ListColumn('Patient', (b) => TwoLine(b.str('patient_name'), b.str('patient_uhid')), flex: 4),
          ListColumn('Status', state, width: 200),
          ListColumn('Amount', (b) => MoneyText(b.integer('net_paise')), width: 120, numeric: true),
          ListColumn('', (b) => OutlinedButton(onPressed: () => open(b), child: const Text('Open')), width: 150, numeric: true),
        ],
      ),
    ]);
  }
}

class _TodayList extends StatelessWidget {
  const _TodayList({required this.bills, required this.canPay});
  final List<Rec> bills;
  final bool canPay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open(Rec b) => context.app.nav.open('billing.invoice', {'id': b.id});
    bool due(Rec b) => canPay && b.str('status') == InvoiceStatus.finalised && b.integer('balance_paise') > 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BillSectionHeader('Billed today',
          subtitle: bills.isEmpty ? null : '${plural(bills.length, 'bill')}. Bills with money due can be paid from here.',
          trailing: TextButton(onPressed: () => context.app.nav.open('billing.invoices'), child: const Text('All bills'))),
      DataList<Rec>(
        items: bills,
        empty: const Card(
          child: EmptyState(icon: Icons.receipt_long_outlined, title: 'No bills yet today', message: 'Finalised bills appear here.'),
        ),
        onTap: open,
        title: (b) => b.str('patient_name'),
        subtitle: (b) => '${b.str('number')} · ${formatTime(b.date('finalised_at'))} · ${formatMoney(b.integer('net_paise'))}',
        trailing: (b) => InvoiceStatusChip(b),
        columns: [
          ListColumn('Bill', (b) => TwoLine(b.str('number'), formatTime(b.date('finalised_at'))), flex: 3),
          ListColumn('Patient', (b) => TwoLine(b.str('patient_name'), b.str('patient_uhid')), flex: 4),
          ListColumn('Payer', (b) => Text(payerLabel(b.strOrNull('payer_type'))), flex: 2),
          ListColumn('Net', (b) => MoneyText(b.integer('net_paise'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              width: 110, numeric: true),
          ListColumn('Status', (b) => InvoiceStatusChip(b), width: 130),
          if (canPay)
            ListColumn(
              '',
              (b) => due(b)
                  ? RowAction('Take payment', onPressed: () => takePaymentFlow(context, b))
                  : const SizedBox.shrink(),
              width: 150,
              numeric: true,
            ),
        ],
      ),
    ]);
  }
}

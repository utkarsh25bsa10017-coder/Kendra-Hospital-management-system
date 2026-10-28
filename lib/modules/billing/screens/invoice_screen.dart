import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import '../billing_service.dart';
import 'billing_widgets.dart';
import 'invoice_sheets.dart';

/// One bill: its lines, totals, payments and everything you can do with it.
/// Opened with {id}, or with {patientId} to start (or reopen) that
/// patient's draft.
class InvoiceScreen extends StatefulWidget {
  const InvoiceScreen({super.key, this.invoiceId, this.patientId});
  final String? invoiceId;
  final String? patientId;

  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen> {
  String? _id;
  String? _error;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _id = widget.invoiceId;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_id == null && !_started && widget.patientId != null) {
      _started = true;
      _openForPatient(widget.patientId!);
    }
  }

  Future<void> _openForPatient(String patientId) async {
    final app = context.app;
    if (!app.auth.can(BillingPerms.invoice)) {
      setState(() => _error = 'You do not have permission to create bills');
      return;
    }
    try {
      var draft = await app.readDb.first(Query(BillCol.invoices)
          .eq('patient_id', patientId)
          .eq('status', InvoiceStatus.draft)
          .sort('created_at', desc: true));
      if (draft == null) {
        draft = await BillingService.createDraft(app.db, patientId);
      } else {
        final more = await BillingService.unbilledFor(app.readDb, patientId);
        if (more.isNotEmpty) await BillingService.addCharges(app.db, draft.id, more);
      }
      if (mounted) setState(() => _id = draft!.id);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return PageScaffold(title: 'Bill', body: EmptyState(icon: Icons.error_outline, title: 'Could not open the bill', message: _error));
    }
    final id = _id;
    if (id == null) return const PageScaffold(title: 'Bill', body: LoadingView());
    return LiveBuilder<BillData?>(
      watch: const {BillCol.invoices, BillCol.lines, BillCol.payments, Col.approvals, Col.charges},
      deps: [id],
      load: (db) => BillData.load(db, id),
      builder: (context, data) => data == null
          ? const PageScaffold(
              title: 'Bill',
              body: EmptyState(icon: Icons.receipt_long_outlined, title: 'Bill not found', message: 'It may have been discarded.'))
          : _InvoiceView(data: data),
    );
  }
}

/// Everything the bill screen shows, loaded in one go.
class BillData {
  BillData({
    required this.invoice,
    required this.patient,
    required this.lines,
    required this.payments,
    required this.approvals,
    required this.unbilled,
    required this.stale,
    required this.related,
  });

  final Rec invoice;
  final Rec? patient;
  final List<Rec> lines;
  final List<Rec> payments;
  final List<Rec> approvals;
  final List<Rec> unbilled;
  final List<(Rec, Rec?)> stale;

  /// The credit note of a cancelled bill, or the bill a credit note cancels.
  final Rec? related;

  bool get isDraft => invoice.str('status') == InvoiceStatus.draft;
  bool get isCreditNote => invoice.str('kind') == InvoiceKind.creditNote;
  bool get isFinalBill => invoice.str('status') == InvoiceStatus.finalised && !isCreditNote;
  List<Rec> get pending => approvals.where((a) => a.str('status') == 'pending').toList();
  Rec? pendingOf(String type) => pending.where((a) => a.str('type') == type).firstOrNull;

  static Future<BillData?> load(ReadDb db, String id) async {
    final inv = await db.get(BillCol.invoices, id);
    if (inv == null || inv.archived) return null;
    final draft = inv.str('status') == InvoiceStatus.draft;
    final lines = await BillingService.linesOf(db, id);
    final related = inv.str('kind') == InvoiceKind.creditNote
        ? await db.get(BillCol.invoices, inv.strOrNull('credit_note_for'))
        : inv.str('status') == InvoiceStatus.cancelled
            ? await db.first(Query(BillCol.invoices).eq('credit_note_for', id))
            : null;
    return BillData(
      invoice: inv,
      patient: await db.get(Col.patients, inv.str('patient_id')),
      lines: lines,
      payments: await BillingService.paymentsOf(db, id),
      approvals: await db.query(Query(Col.approvals).eq('subject_id', id).sort('created_at', desc: true).take(20)),
      unbilled: draft ? await BillingService.unbilledFor(db, inv.str('patient_id')) : const [],
      stale: draft ? await BillingService.staleLines(db, lines) : const [],
      related: related,
    );
  }
}

class _InvoiceView extends StatelessWidget {
  const _InvoiceView({required this.data});
  final BillData data;

  Rec get inv => data.invoice;

  // ------------------------------------------------------------------ actions

  Future<void> _addItem(BuildContext context) async {
    final pick = await showAddItemDialog(context);
    if (pick == null || !context.mounted) return;
    await runGuarded(
      context,
      () => BillingService.addManualLine(context.db, inv.id,
          service: pick.service, quantity: pick.quantity, unitPricePaise: pick.unitPricePaise),
      success: 'Added ${pick.service.str('name')}',
    );
  }

  Future<void> _removeLine(BuildContext context, Rec line) async {
    final charge = line.strOrNull('charge_id') != null;
    final ok = await confirmDialog(
      context,
      title: 'Remove ${line.str('description')}?',
      message: charge
          ? 'It goes back to "Ready to bill" for this patient, so it can be billed later.'
          : 'It was added at the counter and will be dropped from this draft.',
      confirmLabel: 'Remove',
    );
    if (!ok || !context.mounted) return;
    await runGuarded(context, () => BillingService.removeLine(context.db, inv.id, line.id), success: 'Removed');
  }

  Future<void> _addUnbilled(BuildContext context) => runGuarded(
        context,
        () => BillingService.addCharges(context.db, inv.id, data.unbilled),
        success: 'Added ${plural(data.unbilled.length, 'charge')}',
      );

  Future<void> _sync(BuildContext context) =>
      runGuarded(context, () => BillingService.syncWithCharges(context.db, inv.id), success: 'Bill updated');

  Future<void> _discount(BuildContext context) async {
    final gross = data.lines.fold<int>(0, (a, l) => a + (l.integer('amount_paise') > 0 ? l.integer('amount_paise') : 0));
    if (gross <= 0) {
      context.toast('Add items before giving a discount', error: true);
      return;
    }
    final amount = await showDiscountSheet(context, grossPaise: gross, currentPaise: inv.integer('discount_paise'));
    if (amount == null || !context.mounted) return;
    final limit = context.session?.discountLimitPaise ?? 0;
    final reason = await reasonDialog(
      context,
      title: 'Why the discount?',
      message: amount <= limit
          ? '${formatMoney(amount)} is within your limit and applies straight away. It is logged.'
          : '${formatMoney(amount)} is above your limit of ${formatMoney(limit)}, so the board approves it first.',
      presets: discountReasons,
      confirmLabel: amount <= limit ? 'Apply discount' : 'Send for approval',
    );
    if (reason == null || !context.mounted) return;
    final app = context.app;
    await runGuarded(context, () async {
      final out = await BillingService.requestDiscount(app, inv.id, amount, reason);
      _announce(app, out, applied: 'Discount of ${formatMoney(amount)} applied', waiting: 'Sent to the board for approval');
    });
  }

  Future<void> _withdraw(BuildContext context, Rec approval) async {
    final ok = await confirmDialog(context,
        title: 'Withdraw this request?', message: approval.str('title'), confirmLabel: 'Withdraw');
    if (!ok || !context.mounted) return;
    final app = context.app;
    await runGuarded(context, () => app.approvals.cancel(approval), success: 'Request withdrawn');
  }

  static void _announce(AppServices app, ApprovalResult out, {required String applied, required String waiting}) {
    final status = out.approval.str('status');
    if (out.applied) {
      app.nav.toast(applied);
    } else if (status == 'failed') {
      app.nav.toast(out.approval.str('result', 'Could not apply it'), error: true);
    } else {
      app.nav.toast(waiting);
    }
  }

  Future<void> _finalise(BuildContext context) async {
    final canPay = context.can(BillingPerms.payment);
    final choice = await showFinaliseDialog(context, inv, canPay: canPay);
    if (choice == null || !context.mounted) return;
    final app = context.app;
    Rec? done;
    final ok = await runGuarded(context, () async {
      done = await BillingService.finalise(app.db, inv.id);
    });
    if (!ok || done == null) return;
    app.nav.toast('Bill ${done!.str('number')} is final');
    if (choice == FinaliseChoice.andPay && context.mounted && done!.integer('balance_paise') > 0) {
      await _pay(context, done!);
    }
  }

  Future<void> _pay(BuildContext context, [Rec? fresh]) => takePaymentFlow(context, fresh ?? inv);

  Future<void> _refund(BuildContext context) async {
    final max = BillingService.refundable(inv);
    if (max <= 0) {
      context.toast('There is nothing to refund on this bill', error: true);
      return;
    }
    final lastMode = data.payments.where((p) => p.str('kind') == PaymentKind.payment).lastOrNull?.str('mode') ?? 'cash';
    final pick = await showRefundSheet(context, maxPaise: max, defaultMode: lastMode);
    if (pick == null || !context.mounted) return;
    final limit = context.session?.discountLimitPaise ?? 0;
    final reason = await reasonDialog(
      context,
      title: 'Why the refund?',
      message: pick.$1 <= limit
          ? '${formatMoney(pick.$1)} is within your limit and is recorded straight away.'
          : '${formatMoney(pick.$1)} is above your limit of ${formatMoney(limit)}. Hand over the money after the board approves.',
      presets: refundReasons,
      confirmLabel: pick.$1 <= limit ? 'Refund now' : 'Send for approval',
    );
    if (reason == null || !context.mounted) return;
    final app = context.app;
    await runGuarded(context, () async {
      final out = await BillingService.requestRefund(app, inv.id, pick.$1, pick.$2, reason);
      _announce(app, out,
          applied: 'Refund of ${formatMoney(pick.$1)} recorded. Hand it to the patient.', waiting: 'Refund sent to the board for approval');
    });
  }

  Future<void> _cancel(BuildContext context) async {
    final held = inv.integer('paid_paise');
    final limit = context.session?.discountLimitPaise ?? 0;
    final net = inv.integer('net_paise');
    final reason = await reasonDialog(
      context,
      title: 'Cancel ${inv.str('number')}?',
      message: 'A credit note will reverse this bill; the bill itself is kept as it is. '
          '${held > 0 ? '${formatMoney(held)} received will be refunded. ' : ''}'
          'Its charges go back to "Ready to bill" so they can be billed again.'
          '${net > limit ? ' The board approves this first.' : ''}',
      presets: cancelReasons,
      confirmLabel: net > limit ? 'Ask to cancel' : 'Cancel bill',
      destructive: true,
    );
    if (reason == null || !context.mounted) return;
    final app = context.app;
    await runGuarded(context, () async {
      final out = await BillingService.requestCancel(app, inv.id, reason);
      _announce(app, out, applied: 'Bill cancelled and credit note issued', waiting: 'Cancellation sent to the board for approval');
    });
  }

  Future<void> _discard(BuildContext context) async {
    final ok = await confirmDialog(context,
        title: 'Discard this draft?',
        message: 'Its charges go back to "Ready to bill". Nothing has been billed yet.',
        confirmLabel: 'Discard',
        destructive: true);
    if (!ok || !context.mounted) return;
    final nav = Navigator.of(context);
    final done = await runGuarded(context, () => BillingService.discardDraft(context.db, inv.id), success: 'Draft discarded');
    if (done && nav.canPop()) nav.pop();
  }

  void _receipt(BuildContext context) => context.app.nav.open('billing.receipt', {'id': inv.id});

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final canEdit = context.can(BillingPerms.invoice);
    final canPay = context.can(BillingPerms.payment);
    final balance = inv.integer('balance_paise');
    final draft = data.isDraft;
    final waitingDiscount = data.pendingOf(BillingApprovals.discount);

    PageAction? primary;
    VoidCallback? primaryRun;
    if (draft && canEdit) {
      primaryRun = data.lines.isEmpty || waitingDiscount != null ? null : () => _finalise(context);
      primary = PageAction('Finalise', Icons.check, primaryRun, tourAnchor: 'billing.finalise');
    } else if (data.isFinalBill && balance > 0 && canPay) {
      primaryRun = () => _pay(context);
      primary = PageAction('Take payment', Icons.payments_outlined, primaryRun, tourAnchor: 'billing.take_payment');
    } else if (data.isFinalBill && balance < 0 && canPay && data.pendingOf(BillingApprovals.refund) == null) {
      primaryRun = () => _refund(context);
      primary = PageAction('Refund ${formatMoney(-balance)}', Icons.undo, primaryRun);
    } else if (!draft) {
      primaryRun = () => _receipt(context);
      primary = PageAction(data.isCreditNote ? 'View credit note' : 'Receipt', Icons.receipt_long_outlined, primaryRun);
    }

    final acts = <_Act>[
      if (draft && canEdit) ...[
        _Act('Add item', Icons.add, () => _addItem(context), prominent: true),
        _Act(inv.integer('discount_paise') > 0 ? 'Change discount' : 'Request discount', Icons.percent,
            waitingDiscount != null ? null : () => _discount(context),
            prominent: true, anchor: 'billing.request_discount'),
      ],
      if (!draft && primary?.label != 'Receipt' && primary?.label != 'View credit note')
        _Act('Receipt', Icons.receipt_long_outlined, () => _receipt(context), prominent: true),
      if (data.isFinalBill && canPay && BillingService.refundable(inv) > 0 && balance >= 0 && data.pendingOf(BillingApprovals.refund) == null)
        _Act('Refund', Icons.undo, () => _refund(context), prominent: true),
      if (data.isFinalBill && canEdit && data.pendingOf(BillingApprovals.cancel) == null)
        _Act('Cancel bill', Icons.block, () => _cancel(context), prominent: true),
      _Act('Patient', Icons.person_outline, () => context.app.nav.open('patients.profile', {'id': inv.str('patient_id')})),
      if (draft && canEdit) _Act('Discard draft', Icons.delete_outline, () => _discard(context)),
    ];
    final compact = context.isCompact;
    // On phones only the draft's own buttons stay visible; the rest go in a menu.
    final shown = compact ? acts.where((a) => a.prominent && draft).toList() : acts;
    final menu = compact ? acts.where((a) => !shown.contains(a)).toList() : const <_Act>[];
    final secondary = [
      for (final a in shown)
        a.wrap(a.prominent
            ? OutlinedButton.icon(onPressed: a.run, icon: Icon(a.icon, size: 18), label: Text(a.label))
            : TextButton.icon(onPressed: a.run, icon: Icon(a.icon, size: 18), label: Text(a.label))),
    ];

    final title = draft ? 'Draft bill' : (data.isCreditNote ? 'Credit note ${inv.str('number')}' : 'Bill ${inv.str('number')}');
    final p = data.patient;
    final subtitle = [
      inv.str('patient_name'),
      inv.str('patient_uhid'),
      if (p != null) ageLabel(p.date('dob'), p.intOrNull('age_years')),
      payerLabel(inv.strOrNull('payer_type')),
    ].where((s) => s.isNotEmpty && s != '—').join(' · ');

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter, control: true): ?primaryRun,
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): ?primaryRun,
      if (draft && canEdit) const SingleActivator(LogicalKeyboardKey.keyI, control: true): () => _addItem(context),
      if (draft && canEdit) const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () => _addItem(context),
      if (draft && canEdit && waitingDiscount == null)
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): () => _discount(context),
      if (draft && canEdit && waitingDiscount == null)
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): () => _discount(context),
    };

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: PageScaffold(
          title: title,
          subtitle: subtitle,
          primaryAction: primary,
          actions: [
            if (menu.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: 'More actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (i) => menu[i].run?.call(),
                itemBuilder: (c) => [
                  for (final (i, a) in menu.indexed)
                    PopupMenuItem(
                      value: i,
                      enabled: a.run != null,
                      child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(a.icon), title: Text(a.label)),
                    ),
                ],
              ),
          ],
          headerBottom: Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InvoiceStatusChip(inv),
              if (draft) StatusChip(inv.str('number'), icon: Icons.tag),
              if (inv.integer('discount_paise') > 0 && !data.isCreditNote)
                StatusChip('${formatMoney(inv.integer('discount_paise'))} discount', icon: Icons.percent, tone: Tone.info),
              if (secondary.isNotEmpty) const SizedBox(width: Gap.xs),
              ...secondary,
            ],
          ),
          body: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 960;
            final main = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ..._banners(context, canEdit),
              _LinesPanel(data: data, onRemove: draft && canEdit ? (l) => _removeLine(context, l) : null, onAdd: draft && canEdit ? () => _addItem(context) : null),
            ]);
            final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _TotalsCard(data: data),
              if (!draft) ...[Gap.v16, _PaymentsCard(data: data, onPay: data.isFinalBill && balance > 0 && canPay ? () => _pay(context) : null)],
              Gap.v16,
              _DetailsCard(data: data),
            ]);
            if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, Gap.v16, side]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: main),
              Gap.h24,
              SizedBox(width: box.maxWidth >= 1200 ? 380 : 340, child: side),
            ]);
          }),
        ),
      ),
    );
  }

  List<Widget> _banners(BuildContext context, bool canEdit) {
    final me = context.session?.userId;
    final out = <Widget>[];
    for (final a in data.pending) {
      final mine = a.str('requested_by') == me;
      final need = a.integer('required_approvals', 1);
      final got = a.maps('approvers').length;
      final what = switch (a.str('type')) {
        BillingApprovals.discount => 'Discount of ${formatMoney(a.integer('amount_paise'))}',
        BillingApprovals.refund => 'Refund of ${formatMoney(a.integer('amount_paise'))}',
        BillingApprovals.cancel => 'Cancelling this bill',
        _ => a.str('title'),
      };
      out.add(NoticeBanner(
        tone: Tone.warning,
        icon: Icons.hourglass_top,
        title: '$what is waiting for approval',
        message: 'Asked by ${mine ? 'you' : a.str('requested_by_name')} ${formatRelative(a.createdAt)}'
            '${need > 1 ? ' · needs two board members ($got of $need so far)' : ''}. '
            'Reason: ${a.str('reason', '—')}.'
            '${a.str('type') == BillingApprovals.discount && data.isDraft ? ' The bill can be finalised once it is decided.' : ''}',
        actions: [
          if (mine) OutlinedButton(onPressed: () => _withdraw(context, a), child: const Text('Withdraw')),
        ],
      ));
    }
    if (data.isDraft && canEdit) {
      for (final (line, charge) in data.stale) {
        final cancelled = charge == null || charge.str('status') == Vals.cancelled;
        out.add(NoticeBanner(
          tone: Tone.danger,
          icon: Icons.sync_problem_outlined,
          title: cancelled
              ? '${sourceLabel(line.strOrNull('source_module'))} cancelled ${line.str('description')}'
              : '${line.str('description')} changed after this draft was made',
          message: cancelled
              ? 'Take it off the bill before finalising.'
              : 'Now ${formatMoney(charge.integer('amount_paise'))} instead of ${formatMoney(line.integer('amount_paise'))}.',
          actions: [RowAction('Update bill', onPressed: () => _sync(context))],
        ));
      }
      if (data.unbilled.isNotEmpty) {
        final total = data.unbilled.fold<int>(0, (a, c) => a + c.integer('amount_paise'));
        final names = data.unbilled.take(3).map((c) => c.str('description')).join(', ');
        out.add(NoticeBanner(
          tone: Tone.info,
          icon: Icons.playlist_add,
          title: '${plural(data.unbilled.length, 'more charge')} for this patient (${formatMoney(total)})',
          message: '$names${data.unbilled.length > 3 ? '…' : ''}',
          actions: [RowAction('Add to bill', onPressed: () => _addUnbilled(context))],
        ));
      }
    }
    final inv = data.invoice;
    if (inv.str('status') == InvoiceStatus.cancelled) {
      out.add(NoticeBanner(
        tone: Tone.danger,
        icon: Icons.block,
        title: 'Cancelled ${formatRelative(inv.date('cancelled_at'))}',
        message: [
          if (inv.str('cancel_reason').isNotEmpty) 'Reason: ${inv.str('cancel_reason')}.',
          if (data.related != null) 'Reversed by credit note ${data.related!.str('number')}.',
        ].join(' '),
        actions: [
          if (data.related != null)
            OutlinedButton(
                onPressed: () => context.app.nav.open('billing.invoice', {'id': data.related!.id}),
                child: const Text('Open credit note')),
        ],
      ));
    }
    if (data.isCreditNote && data.related != null) {
      out.add(NoticeBanner(
        tone: Tone.info,
        icon: Icons.undo,
        title: 'Reverses ${data.related!.str('number')}',
        message: inv.str('cancel_reason').isEmpty ? null : 'Reason: ${inv.str('cancel_reason')}.',
        actions: [
          OutlinedButton(
              onPressed: () => context.app.nav.open('billing.invoice', {'id': data.related!.id}),
              child: const Text('Open original')),
        ],
      ));
    }
    return out;
  }
}

class _LinesPanel extends StatelessWidget {
  const _LinesPanel({required this.data, this.onRemove, this.onAdd});
  final BillData data;
  final void Function(Rec line)? onRemove;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = data.lines;
    final sources = {for (final l in lines) sourceLabel(l.strOrNull('source_module'))};
    final staleIds = {for (final (l, _) in data.stale) l.id};
    final indexOf = {for (final (i, l) in lines.indexed) l.id: i + 1};

    Widget rate(Rec l) {
      final list = l.intOrNull('list_price_paise');
      final unit = l.integer('unit_price_paise');
      return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        MoneyText(unit),
        if (list != null && list != unit)
          Text('List ${formatMoney(list)}',
              style: theme.textTheme.labelSmall?.copyWith(color: ToneColors.of(context, Tone.warning).foreground)),
      ]);
    }

    String detail(Rec l) => [
          if (l.str('service_code').isNotEmpty) l.str('service_code'),
          sourceLabel(l.strOrNull('source_module')),
          if (l.date('service_date') != null) formatDate(l.date('service_date')),
        ].join(' · ');

    Widget? remove(Rec l) => onRemove == null
        ? null
        : IconButton(
            tooltip: 'Remove from bill',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => onRemove!(l),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BillSectionHeader(
          'Items',
          subtitle: lines.isEmpty ? null : '${plural(lines.length, 'item')} · from ${sources.join(', ')}',
          trailing: onAdd == null
              ? null
              : TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('Add item')),
        ),
        DataList<Rec>(
          items: lines,
          empty: Card(
            child: EmptyState(
              icon: Icons.playlist_add,
              title: 'No items on this bill yet',
              message: 'Charges posted by OPD, lab, pharmacy and wards are added automatically. '
                  'Add anything done at the counter from the price list.',
              action: onAdd == null
                  ? null
                  : FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add item')),
            ),
          ),
          selected: (l) => staleIds.contains(l.id),
          title: (l) => l.str('description'),
          subtitle: (l) =>
              '${categoryLabel(l.strOrNull('category'))} · ${l.integer('quantity', 1)} × ${formatMoney(l.integer('unit_price_paise'))}'
              '${l.intOrNull('list_price_paise') != null && l.intOrNull('list_price_paise') != l.integer('unit_price_paise') ? ' (list ${formatMoney(l.intOrNull('list_price_paise'))})' : ''}'
              ' · ${sourceLabel(l.strOrNull('source_module'))}',
          trailing: (l) => Row(mainAxisSize: MainAxisSize.min, children: [
            MoneyText(l.integer('amount_paise'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ?remove(l),
          ]),
          columns: [
            ListColumn('#', (l) => Text('${indexOf[l.id]}', style: theme.textTheme.bodySmall), width: 32),
            ListColumn('Item', (l) => TwoLine(l.str('description'), detail(l)), flex: 6),
            ListColumn('Category', (l) => Text(categoryLabel(l.strOrNull('category')), overflow: TextOverflow.ellipsis), width: 116),
            ListColumn('Qty', (l) => Text('${l.integer('quantity', 1)}'), width: 48, numeric: true),
            ListColumn('Rate', rate, width: 112, numeric: true),
            ListColumn('Amount', (l) => MoneyText(l.integer('amount_paise'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                width: 116, numeric: true),
            if (onRemove != null) ListColumn('', (l) => remove(l)!, width: 44),
          ],
        ),
      ],
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.data});
  final BillData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inv = data.invoice;
    final discount = inv.integer('discount_paise');
    final balance = inv.integer('balance_paise');
    final refunded = inv.integer('refunded_paise');
    final received = BillingService.received(inv);
    final success = ToneColors.of(context, Tone.success).foreground;
    final warning = ToneColors.of(context, Tone.warning).foreground;
    final approval = data.approvals
        .where((a) => a.id == inv.strOrNull('discount_approval_id'))
        .firstOrNull;
    String? discountNote;
    if (discount != 0) {
      final by = inv.str('discount_by_name');
      final how = approval == null
          ? null
          : approval.flag('auto_approved')
              ? 'within ${by.isEmpty ? 'the cashier' : by}\'s limit'
              : 'approved by ${approval.maps('approvers').map((a) => a['name']).join(' and ')}';
      discountNote = [inv.str('discount_reason'), ?how].where((s) => s.isNotEmpty).join(' · ');
    }

    return SectionCard(
      title: data.isDraft ? 'To pay' : 'Totals',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AmountLine('Items (${data.lines.length})', inv.integer('gross_paise')),
        if (discount != 0)
          AmountLine('Discount', discount, negative: true, caption: discountNote?.isEmpty ?? true ? null : discountNote),
        const Divider(height: Gap.lg),
        AmountLine(data.isCreditNote ? 'Credit' : 'Net payable', inv.integer('net_paise'), large: true),
        if (!data.isDraft && !data.isCreditNote) ...[
          AmountLine('Received', received),
          if (refunded > 0) AmountLine('Refunded', refunded, negative: true),
          const Divider(height: Gap.lg),
          if (inv.str('status') == InvoiceStatus.cancelled)
            AmountLine('Balance', 0, caption: 'Cancelled — nothing is due', strong: true)
          else if (balance > 0)
            AmountLine('Balance due', balance, large: true, color: warning)
          else if (balance < 0)
            AmountLine('To refund', -balance, large: true, color: theme.colorScheme.error, caption: 'Returns exceed the charges')
          else
            AmountLine('Balance', 0, strong: true, color: success, caption: 'Paid in full'),
        ],
        if (data.isDraft)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: MutedText('Finalise to give it a bill number and take payment.', maxLines: 3),
          ),
      ]),
    );
  }
}

class _PaymentsCard extends StatelessWidget {
  const _PaymentsCard({required this.data, this.onPay});
  final BillData data;
  final VoidCallback? onPay;

  @override
  Widget build(BuildContext context) {
    final payments = data.payments;
    return SectionCard(
      title: 'Payments',
      trailing: onPay == null ? null : TextButton.icon(onPressed: onPay, icon: const Icon(Icons.add, size: 18), label: const Text('Take payment')),
      child: payments.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(vertical: Gap.sm), child: MutedText('No payments yet'))
          : Column(children: [
              for (final (i, p) in payments.indexed) ...[if (i > 0) const Divider(height: 1), PaymentTile(p)],
            ]),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.data});
  final BillData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inv = data.invoice;
    final p = data.patient;
    final insurer = p?.str('insurer') ?? '';
    final history = data.approvals.where((a) => a.str('status') != 'pending').toList();
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 96,
              child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            Expanded(child: Text(value.isEmpty ? '—' : value, style: theme.textTheme.bodyMedium)),
          ]),
        );
    return SectionCard(
      title: 'Details',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row('Number', inv.str('number')),
        row('Payer', [payerLabel(inv.strOrNull('payer_type')), if (insurer.isNotEmpty && inv.str('payer_type') != 'self') insurer].join(' · ')),
        if (p != null && inv.str('payer_type') != 'self' && p.str('policy_no').isNotEmpty) row('Policy / ID', p.str('policy_no')),
        if (data.isDraft) row('Started', formatDateTime(inv.date('bill_date') ?? inv.createdAt)),
        if (inv.date('finalised_at') != null) row('Finalised', '${formatDateTime(inv.date('finalised_at'))}\n${inv.str('finalised_by_name')}'),
        if (inv.date('cancelled_at') != null) row('Cancelled', formatDateTime(inv.date('cancelled_at'))),
        if (inv.str('notes').isNotEmpty) row('Notes', inv.str('notes')),
        if (history.isNotEmpty) ...[
          Gap.v12,
          const SubHeading('Approvals'),
          for (final a in history) _ApprovalLine(a),
        ],
      ]),
    );
  }
}

/// A button or menu entry on the bill screen.
class _Act {
  const _Act(this.label, this.icon, this.run, {this.prominent = false, this.anchor});
  final String label;
  final IconData icon;
  final VoidCallback? run;
  final bool prominent;
  final String? anchor;

  Widget wrap(Widget child) => anchor == null ? child : TourAnchor(id: anchor!, child: child);
}

class _ApprovalLine extends StatelessWidget {
  const _ApprovalLine(this.approval);
  final Rec approval;

  @override
  Widget build(BuildContext context) {
    final a = approval;
    final status = a.str('status');
    final (label, tone) = switch (status) {
      'applied' || 'approved' => (a.flag('auto_approved') ? 'Within limit' : 'Approved', Tone.success),
      'rejected' => ('Not approved', Tone.danger),
      'failed' => ('Could not apply', Tone.danger),
      'cancelled' => ('Withdrawn', Tone.neutral),
      _ => (titleCase(status), Tone.neutral),
    };
    final who = a.flag('auto_approved')
        ? a.str('requested_by_name')
        : [a.str('requested_by_name'), ...a.maps('approvers').map((x) => '${x['name']}')].join(' → ');
    final note = status == 'rejected' || status == 'failed' ? (a.str('decision_note', a.str('result'))) : a.str('reason');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(switch (a.str('type')) {
              BillingApprovals.discount => 'Discount ${formatMoney(a.integer('amount_paise'))}',
              BillingApprovals.refund => 'Refund ${formatMoney(a.integer('amount_paise'))}',
              BillingApprovals.cancel => 'Cancellation',
              _ => a.str('title'),
            }, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            MutedText([who, if (note.isNotEmpty) note].join(' · '), maxLines: 3),
          ]),
        ),
        Gap.h8,
        StatusChip(label, tone: tone),
      ]),
    );
  }
}

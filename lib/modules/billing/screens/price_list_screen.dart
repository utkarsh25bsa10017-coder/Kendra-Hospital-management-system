import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../billing_schema.dart';
import 'billing_widgets.dart';
import 'invoice_sheets.dart';

/// The hospital's price list (core `services`). Items are switched off,
/// never deleted, because old bills refer to them.
class PriceListScreen extends StatefulWidget {
  const PriceListScreen({super.key});

  @override
  State<PriceListScreen> createState() => _PriceListScreenState();
}

class _PriceListScreenState extends State<PriceListScreen> {
  String _search = '';
  String _category = 'all';
  bool _showInactive = false;

  Query _query() {
    var q = const Query(Col.services).matching(_search).sort('name').take(300);
    if (_category != 'all') q = q.eq('category', _category);
    if (!_showInactive) q = q.eq('active', true);
    return q;
  }

  Future<void> _edit(BuildContext context, [Rec? service]) async {
    final saved = await showFormSheet<Rec>(
      context,
      title: service == null ? 'Add a service' : 'Edit ${service.str('name')}',
      width: 640,
      builder: (c) => _ServiceForm(service: service),
    );
    if (saved != null && context.mounted) context.toast('Saved ${saved.str('name')}');
  }

  Future<void> _toggle(BuildContext context, Rec s, bool on) => runGuarded(
        context,
        () => context.db.update(Col.services, s.id, {'active': on}, expectedVersion: s.version),
        success: on ? '${s.str('name')} is back on the price list' : '${s.str('name')} switched off',
      );

  @override
  Widget build(BuildContext context) {
    final canEdit = context.can(CorePerms.pricesEdit) || context.can(CorePerms.adminSettings);
    final theme = Theme.of(context);
    return PageScaffold(
      title: 'Price list',
      subtitle: 'What each service costs. Every bill line is checked against it.',
      primaryAction: canEdit ? PageAction('Add service', Icons.add, () => _edit(context)) : null,
      headerBottom: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SearchField(hint: 'Service name or code', onChanged: (v) => setState(() => _search = v)),
        Gap.v12,
        FilterChips<String>(
          options: [('all', 'All'), for (final c in Vals.chargeCategories) (c, categoryLabel(c))],
          value: _category,
          onChanged: (v) => setState(() => _category = v),
        ),
        Gap.v4,
        Row(children: [
          Switch(value: _showInactive, onChanged: (v) => setState(() => _showInactive = v)),
          Gap.h8,
          const Expanded(child: Text('Show switched-off services')),
        ]),
      ]),
      body: LiveBuilder<List<Rec>>(
        watch: const {Col.services},
        deps: [_search, _category, _showInactive],
        load: (db) => db.query(_query()),
        builder: (context, items) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: MutedText('${plural(items.length, 'service')}'
                  '${canEdit ? '. Tap one to change its price.' : '. Ask accounts or the administrator to change prices.'}'),
            ),
          DataList<Rec>(
            items: items,
            empty: Card(
              child: EmptyState(
                icon: Icons.sell_outlined,
                title: _search.isEmpty ? 'Nothing in this category' : 'No service matches "$_search"',
                action: canEdit
                    ? FilledButton.icon(onPressed: () => _edit(context), icon: const Icon(Icons.add), label: const Text('Add service'))
                    : null,
              ),
            ),
            onTap: canEdit ? (s) => _edit(context, s) : null,
            title: (s) => s.str('name'),
            subtitle: (s) => '${s.str('code')} · ${categoryLabel(s.strOrNull('category'))}'
                '${s.flag('active') ? '' : ' · switched off'}',
            trailing: (s) => MoneyText(s.integer('price_paise'),
                style: theme.textTheme.titleSmall, color: s.flag('active') ? null : theme.colorScheme.outline),
            columns: [
              ListColumn('Code', (s) => Text(s.str('code'), style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')), flex: 2),
              ListColumn('Service', (s) => TwoLine(s.str('name'), s.str('department')), flex: 5),
              ListColumn('Category', (s) => Text(categoryLabel(s.strOrNull('category'))), flex: 2),
              ListColumn('GST', (s) => Text(s.realOrNull('tax_percent') == null || s.real('tax_percent') == 0 ? '—' : '${formatNumber(s.real('tax_percent'))}%'),
                  width: 64, numeric: true),
              ListColumn('Price', (s) => MoneyText(s.integer('price_paise'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  width: 120, numeric: true),
              ListColumn('Active', (s) => Switch(value: s.flag('active'), onChanged: canEdit ? (v) => _toggle(context, s, v) : null),
                  width: 80, numeric: true),
            ],
          ),
        ]),
      ),
    );
  }
}

class _ServiceForm extends StatefulWidget {
  const _ServiceForm({this.service});
  final Rec? service;
  @override
  State<_ServiceForm> createState() => _ServiceFormState();
}

class _ServiceFormState extends State<_ServiceForm> {
  final _form = GlobalKey<FormState>();
  late final s = widget.service;
  late final _code = TextEditingController(text: s?.str('code') ?? '');
  late final _name = TextEditingController(text: s?.str('name') ?? '');
  late final _price = TextEditingController(text: s == null ? '' : moneyInput(s!.integer('price_paise')));
  late final _dept = TextEditingController(text: s?.str('department') ?? '');
  late final _tax = TextEditingController(text: s?.realOrNull('tax_percent') == null ? '' : formatNumber(s!.real('tax_percent')));
  late final _notes = TextEditingController(text: s?.str('notes') ?? '');
  late String _category = s?.str('category', Vals.procedure) ?? Vals.procedure;
  late bool _active = s?.flag('active') ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _price, _dept, _tax, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final db = context.db;
    final nav = Navigator.of(context);
    final data = {
      'name': _name.text.trim(),
      'category': _category,
      'price_paise': parseMoney(_price.text) ?? 0,
      'department': _dept.text.trim(),
      'tax_percent': double.tryParse(_tax.text.trim()),
      'notes': _notes.text.trim(),
      'active': _active,
    };
    Rec? saved;
    final ok = await runGuarded(context, () async {
      saved = s == null
          ? await db.insert(Col.services, {...data, 'code': _code.text.trim().toUpperCase()})
          : await db.update(Col.services, s!.id, data, expectedVersion: s!.version);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final old = s?.integer('price_paise');
    final now = parseMoney(_price.text);
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        FormGrid(minFieldWidth: 240, maxColumns: 2, children: [
          AppTextField(
            label: 'Code',
            controller: _code,
            autofocus: s == null,
            readOnly: s != null,
            textCapitalization: TextCapitalization.characters,
            helper: s != null ? 'Codes never change; other departments use them' : 'e.g. PROC-DRESS',
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return 'Code is required';
              if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-]*$').hasMatch(t)) return 'Letters, numbers and dashes only';
              return null;
            },
          ),
          AppTextField(label: 'Name', controller: _name, autofocus: s != null, validator: Validators.required('Name')),
          AppDropdown<String>(
            label: 'Category',
            value: _category,
            items: [for (final c in Vals.chargeCategories) (c, categoryLabel(c))],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          AmountField(
            label: 'Price',
            controller: _price,
            onChanged: (_) => setState(() {}),
            helper: old != null && now != null && now != old ? 'Was ${formatMoney(old)}. New bills use the new price.' : null,
          ),
          AppTextField(label: 'Department', controller: _dept, textCapitalization: TextCapitalization.words),
          AppTextField(
            label: 'GST %',
            controller: _tax,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            hint: 'Leave empty if exempt',
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return null;
              final n = double.tryParse(t);
              return n == null || n < 0 || n > 28 ? 'Enter 0 to 28' : null;
            },
          ),
          FullWidth(child: AppTextField(label: 'Notes', controller: _notes, maxLines: 2)),
          FullWidth(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('On the price list'),
              subtitle: const MutedText('Switched-off services cannot be added to new bills'),
            ),
          ),
        ]),
        Gap.v16,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          Gap.h8,
          FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.check), label: const Text('Save')),
        ]),
      ]),
    );
  }
}

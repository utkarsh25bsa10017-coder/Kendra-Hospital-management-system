import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../bed_charging.dart';
import '../ipd_schema.dart';
import '../ipd_service.dart';

/// Wards, their beds and what a bed-day costs in each.
class WardsScreen extends StatelessWidget {
  const WardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Wards & beds',
      subtitle: 'Bed numbers and the daily bed and nursing charges of each ward',
      primaryAction: PageAction('Add ward', Icons.add, () => _editWard(context, null)),
      body: LiveBuilder<(List<Rec>, Map<String, List<Rec>>, BedPricing)>(
        watch: const {IpdCol.wards, IpdCol.beds, Col.services},
        load: (db) async {
          final wards = IpdService.sortWards(await db.query(const Query(IpdCol.wards).take(200)));
          final beds = <String, List<Rec>>{};
          for (final b in await db.query(const Query(IpdCol.beds).eq('active', true).take(2000))) {
            beds.putIfAbsent(b.str('ward_id'), () => []).add(b);
          }
          for (final l in beds.values) {
            l.sort((a, b) => IpdService.compareLabels(a.str('label'), b.str('label')));
          }
          return (wards, beds, await BedPricing.load(db));
        },
        builder: (context, data) {
          final (wards, beds, pricing) = data;
          if (wards.isEmpty) {
            return EmptyState(
              icon: Icons.meeting_room_outlined,
              title: 'No wards yet',
              message: 'Add a ward, then its beds.',
              action: FilledButton.icon(onPressed: () => _editWard(context, null), icon: const Icon(Icons.add), label: const Text('Add ward')),
            );
          }
          final total = beds.values.fold<int>(0, (a, l) => a + l.length);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${plural(wards.where((w) => w['active'] != false).length, 'ward')} · ${plural(total, 'bed')}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              Gap.v12,
              for (final w in wards) ...[
                _WardCard(ward: w, beds: beds[w.id] ?? const [], pricing: pricing),
                Gap.v16,
              ],
            ],
          );
        },
      ),
    );
  }
}

Future<void> _editWard(BuildContext context, Rec? ward) => showFormSheet<void>(
      context,
      title: ward == null ? 'Add ward' : 'Edit ${ward.str('name')}',
      builder: (c) => _WardForm(ward: ward),
    );

class _WardCard extends StatelessWidget {
  const _WardCard({required this.ward, required this.beds, required this.pricing});
  final Rec ward;
  final List<Rec> beds;
  final BedPricing pricing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = ward['active'] != false;
    final bed = pricing.price(ward.id, BedCharging.bed);
    final nursing = pricing.price(ward.id, BedCharging.nursing);
    final price = bed == null
        ? 'No bed charge set'
        : 'Bed ${formatMoney(bed.$2, alwaysDecimals: false)} + nursing ${nursing == null ? '—' : formatMoney(nursing.$2, alwaysDecimals: false)} per day';
    return SectionCard(
      title: ward.str('name'),
      subtitle: [wardKindLabel(ward.str('kind')), if (ward.str('floor').isNotEmpty) ward.str('floor'), plural(beds.length, 'bed')].join(' · '),
      trailing: Wrap(
        spacing: Gap.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!active) const StatusChip('Closed'),
          IconButton(tooltip: 'Edit ward', icon: const Icon(Icons.edit_outlined), onPressed: () => _editWard(context, ward)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.payments_outlined, size: 18, color: bed == null ? ToneColors.of(context, Tone.danger).foreground : theme.colorScheme.onSurfaceVariant),
            Gap.h8,
            Expanded(
              child: Text(price,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: bed == null ? ToneColors.of(context, Tone.danger).foreground : theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
          Gap.v12,
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final b in beds) _BedChip(bed: b),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add beds'),
                onPressed: () => showFormSheet<void>(context,
                    title: 'Add beds to ${ward.str('name')}', builder: (c) => _AddBedsForm(ward: ward, existing: beds), width: 520),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BedChip extends StatelessWidget {
  const _BedChip({required this.bed});
  final Rec bed;

  @override
  Widget build(BuildContext context) {
    final status = bed.str('status', IpdVals.available);
    final c = ToneColors.of(context, bedStatusTone(status));
    final label = bed.str('label');
    return PopupMenuButton<String>(
      tooltip: '$label · ${bedStatusLabel(status)}',
      onSelected: (action) async {
        final db = context.app.db;
        switch (action) {
          case 'maintenance':
            await runGuarded(context, () => IpdService.setMaintenance(db, bed, true), success: '$label is under maintenance');
          case 'in_use':
            await runGuarded(context, () => IpdService.setMaintenance(db, bed, false), success: '$label is back in use');
          case 'retire':
            final ok = await confirmDialog(context,
                title: 'Remove $label?', message: 'It disappears from the bed board. Its history is kept.', confirmLabel: 'Remove', destructive: true);
            if (ok && context.mounted) await runGuarded(context, () => IpdService.retireBed(db, bed), success: '$label removed');
        }
      },
      itemBuilder: (c) => [
        if (status == IpdVals.maintenance)
          const PopupMenuItem(value: 'in_use', child: Text('Back in use'))
        else if (status != IpdVals.occupied)
          const PopupMenuItem(value: 'maintenance', child: Text('Under maintenance')),
        if (status != IpdVals.occupied) const PopupMenuItem(value: 'retire', child: Text('Remove bed')),
        if (status == IpdVals.occupied) const PopupMenuItem(enabled: false, child: Text('Occupied — move the patient first')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.sm)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            switch (status) {
              IpdVals.maintenance => Icons.build_outlined,
              IpdVals.occupied => Icons.person,
              IpdVals.cleaning => Icons.cleaning_services_outlined,
              _ => Icons.king_bed_outlined,
            },
            size: 16,
            color: c.foreground,
          ),
          Gap.h4,
          Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: c.foreground)),
        ]),
      ),
    );
  }
}

class _WardForm extends StatefulWidget {
  const _WardForm({this.ward});
  final Rec? ward;

  @override
  State<_WardForm> createState() => _WardFormState();
}

class _WardFormState extends State<_WardForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.ward?.str('name'));
  late final _floor = TextEditingController(text: widget.ward?.str('floor'));
  late String _kind = widget.ward?.str('kind', 'general') ?? 'general';
  late String? _bedCode = widget.ward?.strOrNull('bed_service_code') ?? defaultBedCode(_kind);
  late String? _nursingCode = widget.ward?.strOrNull('nursing_service_code') ?? defaultNursingCode(_kind);
  late bool _active = widget.ward?['active'] != false;
  List<Rec>? _services;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services == null) _loadServices();
  }

  Future<void> _loadServices() async {
    final s = await context.app.readDb
        .query(Query(Col.services).isIn('category', [Vals.bed, Vals.nursing]).eq('active', true).sort('code').take(500));
    if (mounted) setState(() => _services = s);
  }

  @override
  void dispose() {
    _name.dispose();
    _floor.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final ok = await runGuarded(
      context,
      () => IpdService.saveWard(context.app.db, existing: widget.ward, data: {
        'name': _name.text,
        'kind': _kind,
        'floor': _floor.text.trim(),
        'bed_service_code': _bedCode,
        'nursing_service_code': _nursingCode,
        'active': _active,
      }),
      success: widget.ward == null ? 'Ward added. Now add its beds.' : 'Ward saved',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) nav.pop();
  }

  List<(String, String)> _options(String category) => [
        for (final s in _services ?? const <Rec>[])
          if (s.str('category') == category) (s.str('code'), '${s.str('name')} · ${formatMoney(s.integer('price_paise'), alwaysDecimals: false)}'),
      ];

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FormGrid(maxColumns: 2, children: [
            AppTextField(label: 'Ward name', controller: _name, validator: Validators.required('Ward name'), textCapitalization: TextCapitalization.words),
            AppTextField(label: 'Floor', controller: _floor, hint: 'e.g. First floor'),
            AppDropdown<String>(
              label: 'Kind',
              value: _kind,
              items: [for (final k in IpdVals.wardKinds) (k, wardKindLabel(k))],
              onChanged: (v) => setState(() {
                final old = _kind;
                _kind = v ?? 'general';
                // Follow the kind unless someone picked a price on purpose.
                if (_bedCode == defaultBedCode(old)) _bedCode = defaultBedCode(_kind);
                if (_nursingCode == defaultNursingCode(old)) _nursingCode = defaultNursingCode(_kind);
              }),
            ),
            if (widget.ward != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Open'),
                subtitle: const Text('Closed wards are hidden from the bed board'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            FullWidth(
              child: AppDropdown<String>(
                key: ValueKey('bed$_bedCode${_services?.length}'),
                label: 'Bed charge per day',
                value: _bedCode,
                items: _options(Vals.bed),
                helper: 'From the price list',
                validator: (v) => v == null ? 'Choose the bed charge' : null,
                onChanged: (v) => setState(() => _bedCode = v),
              ),
            ),
            FullWidth(
              child: AppDropdown<String>(
                key: ValueKey('nursing$_nursingCode${_services?.length}'),
                label: 'Nursing charge per day',
                value: _nursingCode,
                items: _options(Vals.nursing),
                validator: (v) => v == null ? 'Choose the nursing charge' : null,
                onChanged: (v) => setState(() => _nursingCode = v),
              ),
            ),
          ]),
          Gap.v24,
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.check), label: const Text('Save ward')),
          ),
        ],
      ),
    );
  }
}

class _AddBedsForm extends StatefulWidget {
  const _AddBedsForm({required this.ward, required this.existing});
  final Rec ward;
  final List<Rec> existing;

  @override
  State<_AddBedsForm> createState() => _AddBedsFormState();
}

class _AddBedsFormState extends State<_AddBedsForm> {
  late final TextEditingController _prefix;
  late final TextEditingController _from;
  late final TextEditingController _to;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Continue the ward's numbering: G-12 → G-13…
    var prefix = '${widget.ward.str('name').isEmpty ? 'B' : widget.ward.str('name')[0].toUpperCase()}-';
    var next = 1;
    for (final b in widget.existing) {
      final m = RegExp(r'^(.*?)(\d+)$').firstMatch(b.str('label'));
      if (m == null) continue;
      prefix = m.group(1)!;
      final n = int.parse(m.group(2)!);
      if (n >= next) next = n + 1;
    }
    _prefix = TextEditingController(text: prefix);
    _from = TextEditingController(text: '$next');
    _to = TextEditingController(text: '${next + 3}');
  }

  @override
  void dispose() {
    _prefix.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  List<String> get _labels {
    final from = int.tryParse(_from.text.trim());
    final to = int.tryParse(_to.text.trim());
    if (from == null || to == null) return const [];
    return IpdService.bedLabels(_prefix.text, from, to);
  }

  Future<void> _save() async {
    final labels = _labels;
    if (labels.isEmpty) {
      context.app.nav.toast('Enter a range like 13 to 16', error: true);
      return;
    }
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    var added = 0;
    final ok = await runGuarded(context, () async {
      added = await IpdService.addBeds(context.app.db, widget.ward, labels);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      context.app.nav.toast(added == 0 ? 'Those beds already exist' : 'Added ${plural(added, 'bed')} to ${widget.ward.str('name')}');
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = _labels;
    final theme = Theme.of(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FormGrid(minFieldWidth: 100, children: [
          AppTextField(label: 'Prefix', controller: _prefix, onChanged: (_) => setState(() {})),
          AppTextField(label: 'From', controller: _from, keyboardType: TextInputType.number, inputFormatters: digits, onChanged: (_) => setState(() {})),
          AppTextField(label: 'To', controller: _to, keyboardType: TextInputType.number, inputFormatters: digits, onChanged: (_) => setState(() {})),
        ]),
        Gap.v12,
        Text(
          labels.isEmpty
              ? 'Enter the first and last bed number.'
              : 'Adds ${plural(labels.length, 'bed')}: ${labels.length <= 6 ? labels.join(', ') : '${labels.first} … ${labels.last}'}',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Gap.v24,
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.add), label: const Text('Add beds')),
        ),
      ],
    );
  }
}

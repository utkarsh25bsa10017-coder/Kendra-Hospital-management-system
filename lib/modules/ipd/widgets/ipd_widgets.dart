import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../bed_charging.dart';
import '../bed_days.dart';
import '../ipd_schema.dart';
import '../ipd_service.dart';

/// Everything the bed board needs, loaded in a handful of queries.
class BoardData {
  BoardData({required this.wards, required this.beds, required this.admissions, required this.patients, required this.doctors});

  /// Active wards in the order they were set up.
  final List<Rec> wards;

  /// Active beds by ward id, in natural label order.
  final Map<String, List<Rec>> beds;

  /// Current admissions by id.
  final Map<String, Rec> admissions;
  final Map<String, Rec> patients;
  final Map<String, Rec> doctors;

  static Future<BoardData> load(ReadDb db) async {
    final wards = IpdService.sortWards(await db.query(const Query(IpdCol.wards).eq('active', true).take(200)));
    final beds = <String, List<Rec>>{};
    for (final b in await db.query(const Query(IpdCol.beds).eq('active', true).take(2000))) {
      beds.putIfAbsent(b.str('ward_id'), () => []).add(b);
    }
    for (final l in beds.values) {
      l.sort((a, b) => IpdService.compareLabels(a.str('label'), b.str('label')));
    }
    final adms = await db.query(Query(IpdCol.admissions).isIn('status', IpdVals.current).take(2000));
    final patients = await db.byIds(Col.patients, adms.map((a) => a.strOrNull('patient_id')));
    final doctors = await db.byIds(Col.users, adms.map((a) => a.strOrNull('attending_doctor_id')));
    return BoardData(
      wards: wards,
      beds: beds,
      admissions: {for (final a in adms) a.id: a},
      patients: patients,
      doctors: doctors,
    );
  }

  List<Rec> bedsOf(String wardId) => beds[wardId] ?? const [];
  Iterable<Rec> get allBeds => wards.expand((w) => bedsOf(w.id));

  int count(String status, [String? wardId]) =>
      (wardId == null ? allBeds : bedsOf(wardId)).where((b) => b.str('status', IpdVals.available) == status).length;
  int total([String? wardId]) => (wardId == null ? allBeds : bedsOf(wardId)).length;

  Rec? admissionIn(Rec bed) {
    final a = admissions[bed.str('admission_id')];
    if (a != null) return a;
    // Fall back to the admission that says it is in this bed.
    for (final x in admissions.values) {
      if (x.str('bed_id') == bed.id) return x;
    }
    return null;
  }
}

/// A coloured panel with an icon, for warnings like allergies.
class ToneBanner extends StatelessWidget {
  const ToneBanner({super.key, required this.tone, required this.icon, required this.title, this.message, this.action});
  final Tone tone;
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ToneColors.of(context, tone);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      decoration: BoxDecoration(color: c.background, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(
        children: [
          Icon(icon, color: c.foreground, size: 20),
          Gap.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(color: c.foreground)),
                if (message != null) ...[
                  Gap.v4,
                  Text(message!, style: theme.textTheme.bodySmall?.copyWith(color: c.foreground)),
                ],
              ],
            ),
          ),
          if (action != null) ...[Gap.h8, action!],
        ],
      ),
    );
  }
}

class AdmissionStatusChip extends StatelessWidget {
  const AdmissionStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) => switch (status) {
        IpdVals.admitted => const StatusChip('In hospital', tone: Tone.info),
        IpdVals.dischargePending => const StatusChip('Discharge pending', tone: Tone.warning),
        IpdVals.discharged => const StatusChip('Discharged', tone: Tone.success),
        _ => StatusChip(titleCase(status)),
      };
}

/// One bed on the bed board.
class BedTile extends StatelessWidget {
  const BedTile({super.key, required this.bed, this.admission, this.patient, this.doctor, this.onTap, this.now});
  final Rec bed;
  final Rec? admission;
  final Rec? patient;
  final Rec? doctor;
  final VoidCallback? onTap;
  final DateTime? now;

  static const height = 104.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = bed.str('status', IpdVals.available);
    final occupied = status == IpdVals.occupied;
    final c = ToneColors.of(context, bedStatusTone(status));
    final at = now ?? DateTime.now();
    final since = bed.date('status_since');
    final pending = admission?.str('status') == IpdVals.dischargePending;

    final icon = switch (status) {
      IpdVals.available => Icons.check_circle_outline,
      IpdVals.occupied => Icons.person,
      IpdVals.cleaning => Icons.cleaning_services_outlined,
      IpdVals.maintenance => Icons.build_outlined,
      _ => Icons.bookmark_border,
    };

    final String line1;
    final String line2;
    if (occupied) {
      line1 = patient?.str('full_name') ?? 'Occupied';
      final day = admission?.date('admitted_at') == null ? null : BedDays.dayNumber(admission!.date('admitted_at')!, at);
      line2 = [if (day != null) 'Day $day', if (doctor != null) shortDoctor(doctor!.str('display_name'))].join(' · ');
    } else if (status == IpdVals.cleaning) {
      line1 = 'Cleaning';
      line2 = since == null ? 'Tap when ready' : '${formatDuration(at.difference(since))} · tap when ready';
    } else if (status == IpdVals.maintenance) {
      line1 = 'Maintenance';
      line2 = since == null ? 'Not in use' : 'Since ${formatDateShort(since)}';
    } else if (status == IpdVals.reserved) {
      line1 = 'Reserved';
      line2 = 'Tap to admit';
    } else {
      line1 = 'Free';
      line2 = 'Tap to admit';
    }

    return Material(
      color: c.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md), side: BorderSide(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm + 2, Gap.sm, Gap.sm + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(bed.str('label'),
                          style: theme.textTheme.titleSmall?.copyWith(color: c.foreground, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (pending)
                      Tooltip(
                        message: 'Discharge pending',
                        child: Icon(Icons.logout, size: 18, color: ToneColors.of(context, Tone.warning).foreground),
                      )
                    else
                      Icon(icon, size: 18, color: c.foreground),
                  ],
                ),
                const Spacer(),
                Text(line1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600, color: occupied ? theme.colorScheme.onSurface : c.foreground)),
                Gap.v4,
                Text(pending ? 'Discharge pending' : line2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: pending ? ToneColors.of(context, Tone.warning).foreground : theme.colorScheme.onSurfaceVariant,
                        fontWeight: pending ? FontWeight.w600 : null)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiles in as many columns as fit.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children, this.minTileWidth = 156, this.spacing = Gap.sm});
  final List<Widget> children;
  final double minTileWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(1, 12);
      final w = (c.maxWidth - (cols - 1) * spacing) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

/// Choose a ward, then one of its free beds. Used when admitting and
/// transferring.
class FreeBedPicker extends StatefulWidget {
  const FreeBedPicker({super.key, required this.selected, required this.onChanged, this.initialWardId, this.excludeBedId});
  final Rec? selected;
  final ValueChanged<Rec?> onChanged;
  final String? initialWardId;
  final String? excludeBedId;

  @override
  State<FreeBedPicker> createState() => _FreeBedPickerState();
}

class _FreeBedPickerState extends State<FreeBedPicker> {
  String? _wardId;

  @override
  void initState() {
    super.initState();
    _wardId = widget.selected?.str('ward_id') ?? widget.initialWardId;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LiveBuilder<(List<Rec>, Map<String, List<Rec>>, BedPricing)>(
      watch: const {IpdCol.wards, IpdCol.beds, Col.services},
      load: (db) async {
        final wards = IpdService.sortWards(await db.query(const Query(IpdCol.wards).eq('active', true).take(200)));
        final free = <String, List<Rec>>{};
        for (final b in await db.query(Query(IpdCol.beds).isIn('status', [IpdVals.available, IpdVals.reserved]).eq('active', true).take(2000))) {
          if (b.id == widget.excludeBedId) continue;
          free.putIfAbsent(b.str('ward_id'), () => []).add(b);
        }
        for (final l in free.values) {
          l.sort((a, b) => IpdService.compareLabels(a.str('label'), b.str('label')));
        }
        return (wards, free, await BedPricing.load(db));
      },
      builder: (context, data) {
        final (wards, free, pricing) = data;
        if (wards.isEmpty) {
          return const Text('No wards are set up yet. An administrator can add them under Wards & beds.');
        }
        final wardId = _wardId ?? wards.firstWhere((w) => (free[w.id] ?? const []).isNotEmpty, orElse: () => wards.first).id;
        final ward = wards.firstWhere((w) => w.id == wardId, orElse: () => wards.first);
        final beds = free[ward.id] ?? const <Rec>[];
        final bedPrice = pricing.price(ward.id, BedCharging.bed)?.$2;
        final nursingPrice = pricing.price(ward.id, BedCharging.nursing)?.$2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SubHeading('Ward'),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final w in wards)
                  ChoiceChip(
                    showCheckmark: false,
                    selected: w.id == ward.id,
                    label: Text('${w.str('name')} · ${(free[w.id] ?? const []).length} free'),
                    onSelected: (_) {
                      setState(() => _wardId = w.id);
                      if (widget.selected != null && widget.selected!.str('ward_id') != w.id) widget.onChanged(null);
                    },
                  ),
              ],
            ),
            Gap.v12,
            SubHeading('Free beds in ${ward.str('name')}'),
            if (beds.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Text('No free bed here right now. Pick another ward, or mark a cleaned bed ready on the bed board.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              )
            else
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final b in beds)
                    ChoiceChip(
                      selected: widget.selected?.id == b.id,
                      label: Text(b.str('label')),
                      onSelected: (on) => widget.onChanged(on ? b : null),
                    ),
                ],
              ),
            if (bedPrice != null) ...[
              Gap.v12,
              Text(
                '${formatMoney(bedPrice + (nursingPrice ?? 0), alwaysDecimals: false)} per day'
                ' (bed ${formatMoney(bedPrice, alwaysDecimals: false)}'
                '${nursingPrice == null ? '' : ' + nursing ${formatMoney(nursingPrice, alwaysDecimals: false)}'})',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        );
      },
    );
  }
}

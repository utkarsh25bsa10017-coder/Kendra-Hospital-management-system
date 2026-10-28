import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../ipd_schema.dart';
import '../ipd_service.dart';
import '../widgets/ipd_widgets.dart';

/// Who is in which bed, which beds are free and which are being cleaned.
class BedBoardScreen extends StatefulWidget {
  const BedBoardScreen({super.key});

  @override
  State<BedBoardScreen> createState() => _BedBoardScreenState();
}

class _BedBoardScreenState extends State<BedBoardScreen> {
  String? _wardId;

  @override
  Widget build(BuildContext context) {
    final canAdmit = context.can(IpdPerms.admit);
    final primary = canAdmit
        ? PageAction('Admit patient', Icons.king_bed_outlined, () => context.app.nav.open('ipd.admit'), tourAnchor: 'ipd.admit')
        : null;
    return LiveBuilder<BoardData>(
      watch: const {IpdCol.wards, IpdCol.beds, IpdCol.admissions, Col.patients},
      load: BoardData.load,
      loading: PageScaffold(title: 'Beds', primaryAction: primary, body: const LoadingView()),
      builder: (context, data) {
        final total = data.total();
        final occupied = data.count(IpdVals.occupied);
        final wards = _wardId == null ? data.wards : data.wards.where((w) => w.id == _wardId).toList();
        return PageScaffold(
          title: 'Beds',
          subtitle: total == 0
              ? 'Set up wards and beds to start'
              : '$occupied of $total occupied · ${data.count(IpdVals.available)} free · ${data.count(IpdVals.cleaning)} in cleaning',
          primaryAction: primary,
          headerBottom: total == 0
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Summary(data: data),
                    Gap.v12,
                    FilterChips<String?>(
                      options: [
                        (null, 'All wards'),
                        for (final w in data.wards) (w.id, '${w.str('name')} (${data.count(IpdVals.available, w.id)} free)'),
                      ],
                      value: _wardId,
                      onChanged: (v) => setState(() => _wardId = v),
                    ),
                  ],
                ),
          body: total == 0
              ? EmptyState(
                  icon: Icons.king_bed_outlined,
                  title: 'No beds yet',
                  message: context.can(IpdPerms.setup)
                      ? 'Add your wards and beds, with their daily bed and nursing charges.'
                      : 'An administrator needs to add wards and beds first.',
                  action: context.can(IpdPerms.setup)
                      ? FilledButton.icon(
                          onPressed: () => context.app.nav.open('ipd.wards'),
                          icon: const Icon(Icons.meeting_room_outlined),
                          label: const Text('Set up wards'))
                      : null,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, w) in wards.indexed) ...[
                      if (i > 0) Gap.v16,
                      i == 0 ? TourAnchor(id: 'ipd.board', child: _WardPanel(ward: w, data: data)) : _WardPanel(ward: w, data: data),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.data});
  final BoardData data;

  @override
  Widget build(BuildContext context) {
    final total = data.total();
    final occupied = data.count(IpdVals.occupied);
    final pct = total == 0 ? 0 : (occupied * 100 / total).round();
    final freeByKind = <String, int>{};
    for (final w in data.wards) {
      final n = data.count(IpdVals.available, w.id);
      final k = wardKindLabel(w.str('kind'));
      freeByKind[k] = (freeByKind[k] ?? 0) + n;
    }
    final pending = data.admissions.values.where((a) => a.str('status') == IpdVals.dischargePending).length;
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        StatusChip('Occupied $occupied / $total · $pct%', icon: Icons.person, tone: Tone.info),
        StatusChip(
          'Free ${data.count(IpdVals.available)}: ${freeByKind.entries.map((e) => '${e.key} ${e.value}').join(' · ')}',
          icon: Icons.check_circle_outline,
          tone: Tone.success,
        ),
        StatusChip('Cleaning ${data.count(IpdVals.cleaning)}', icon: Icons.cleaning_services_outlined, tone: Tone.warning),
        if (data.count(IpdVals.maintenance) > 0)
          StatusChip('Maintenance ${data.count(IpdVals.maintenance)}', icon: Icons.build_outlined),
        if (pending > 0) StatusChip('Discharge pending $pending', icon: Icons.logout, tone: Tone.warning),
      ],
    );
  }
}

class _WardPanel extends StatelessWidget {
  const _WardPanel({required this.ward, required this.data});
  final Rec ward;
  final BoardData data;

  @override
  Widget build(BuildContext context) {
    final beds = data.bedsOf(ward.id);
    final occupied = data.count(IpdVals.occupied, ward.id);
    final now = DateTime.now();
    return SectionCard(
      title: ward.str('name'),
      subtitle: [
        wardKindLabel(ward.str('kind')),
        if (ward.str('floor').isNotEmpty) ward.str('floor'),
        '$occupied of ${beds.length} occupied',
      ].join(' · '),
      trailing: StatusChip('${data.count(IpdVals.available, ward.id)} free',
          tone: data.count(IpdVals.available, ward.id) == 0 ? Tone.neutral : Tone.success),
      child: beds.isEmpty
          ? const Text('No beds in this ward yet.')
          : TileGrid(
              children: [
                for (final b in beds)
                  Builder(builder: (context) {
                    final adm = b.str('status') == IpdVals.occupied ? data.admissionIn(b) : null;
                    return BedTile(
                      bed: b,
                      admission: adm,
                      patient: adm == null ? null : data.patients[adm.str('patient_id')],
                      doctor: adm == null ? null : data.doctors[adm.str('attending_doctor_id')],
                      now: now,
                      onTap: () => _tap(context, b, adm),
                    );
                  }),
              ],
            ),
    );
  }

  Future<void> _tap(BuildContext context, Rec bed, Rec? admission) async {
    final app = context.app;
    final label = bed.str('label');
    switch (bed.str('status', IpdVals.available)) {
      case IpdVals.occupied:
        if (admission != null) app.nav.open('ipd.admission', {'id': admission.id});
      case IpdVals.available || IpdVals.reserved:
        if (context.can(IpdPerms.admit)) {
          app.nav.open('ipd.admit', {'bedId': bed.id});
        } else {
          app.nav.toast('$label is free');
        }
      case IpdVals.cleaning:
        if (!context.can(IpdPerms.admit)) {
          app.nav.toast('$label is being cleaned');
          return;
        }
        final since = bed.date('status_since');
        final ok = await confirmDialog(
          context,
          title: 'Mark $label ready?',
          message: since == null
              ? 'The bed will show as free on the board.'
              : 'In cleaning since ${formatTime(since)} (${formatDuration(DateTime.now().difference(since))}). '
                  'The bed will show as free on the board.',
          confirmLabel: 'Mark ready',
        );
        if (ok && context.mounted) {
          await runGuarded(context, () => IpdService.markReady(app.db, bed), success: '$label is ready for the next patient');
        }
      case IpdVals.maintenance:
        if (!context.can(IpdPerms.setup)) {
          app.nav.toast('$label is under maintenance');
          return;
        }
        final ok = await confirmDialog(context,
            title: 'Put $label back in use?', message: 'Only if the repair is done.', confirmLabel: 'Back in use');
        if (ok && context.mounted) {
          await runGuarded(context, () => IpdService.setMaintenance(app.db, bed, false), success: '$label is back in use');
        }
    }
  }
}

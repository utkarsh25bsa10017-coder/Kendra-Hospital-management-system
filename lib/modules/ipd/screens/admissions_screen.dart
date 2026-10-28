import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../bed_days.dart';
import '../ipd_schema.dart';
import '../ipd_service.dart';
import '../widgets/ipd_widgets.dart';

enum _Show { current, pending, discharged }

enum _Sort { longest, newest }

class _Row {
  _Row(this.admission, this.patient, this.bed, this.ward, this.doctor, this.days);
  final Rec admission;
  final Rec? patient;
  final Rec? bed;
  final Rec? ward;
  final Rec? doctor;
  final int days;

  String get name => patient?.str('full_name') ?? 'Patient';
}

/// Current inpatients and recent discharges.
class AdmissionsScreen extends StatefulWidget {
  const AdmissionsScreen({super.key});

  @override
  State<AdmissionsScreen> createState() => _AdmissionsScreenState();
}

class _AdmissionsScreenState extends State<AdmissionsScreen> {
  String _search = '';
  _Show _show = _Show.current;
  _Sort _sort = _Sort.longest;

  Future<List<_Row>> _load(ReadDb db) async {
    final now = DateTime.now();
    final q = switch (_show) {
      _Show.current => Query(IpdCol.admissions).isIn('status', IpdVals.current).take(1000),
      _Show.pending => const Query(IpdCol.admissions).eq('status', IpdVals.dischargePending).take(500),
      _Show.discharged => Query(IpdCol.admissions)
          .eq('status', IpdVals.discharged)
          .gte('discharged_at', now.subtract(const Duration(days: 30)))
          .sort('discharged_at', desc: true)
          .take(500),
    };
    final list = await db.query(q);
    final patients = await db.byIds(Col.patients, list.map((a) => a.strOrNull('patient_id')));
    final beds = await db.byIds(IpdCol.beds, list.map((a) => a.strOrNull('bed_id')));
    final wards = await db.byIds(IpdCol.wards, list.map((a) => a.strOrNull('ward_id')));
    final doctors = await db.byIds(Col.users, list.map((a) => a.strOrNull('attending_doctor_id')));
    final words = _search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final rows = <_Row>[];
    for (final a in list) {
      final p = patients[a.str('patient_id')];
      final b = beds[a.str('bed_id')];
      final w = wards[a.str('ward_id')];
      final d = doctors[a.str('attending_doctor_id')];
      final hay = [a.str('number'), a.str('diagnosis'), p?.str('full_name'), p?.str('uhid'), p?.str('phone'), b?.str('label'), w?.str('name'), d?.str('display_name')]
          .join(' ')
          .toLowerCase();
      if (!words.every(hay.contains)) continue;
      final admitted = a.date('admitted_at')!;
      final days = a.str('status') == IpdVals.discharged
          ? BedDays.count(admittedAt: admitted, dischargedAt: a.date('discharged_at'), now: now)
          : BedDays.dayNumber(admitted, now);
      rows.add(_Row(a, p, b, w, d, days));
    }
    if (_show != _Show.discharged) {
      rows.sort((x, y) => _sort == _Sort.longest
          ? x.admission.date('admitted_at')!.compareTo(y.admission.date('admitted_at')!)
          : y.admission.date('admitted_at')!.compareTo(x.admission.date('admitted_at')!));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canAdmit = context.can(IpdPerms.admit);
    return PageScaffold(
      title: 'Admissions',
      subtitle: 'Inpatients now in hospital and discharges of the last 30 days',
      primaryAction: canAdmit ? PageAction('Admit patient', Icons.king_bed_outlined, () => app.nav.open('ipd.admit')) : null,
      headerBottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchField(hint: 'Name, UHID, IP number, bed or diagnosis', onChanged: (v) => setState(() => _search = v)),
          Gap.v12,
          Wrap(
            spacing: Gap.md,
            runSpacing: Gap.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChips<_Show>(
                options: const [(_Show.current, 'In hospital'), (_Show.pending, 'Discharge pending'), (_Show.discharged, 'Discharged (30 days)')],
                value: _show,
                onChanged: (v) => setState(() => _show = v),
              ),
              if (_show != _Show.discharged)
                PopupMenuButton<_Sort>(
                  tooltip: 'Sort',
                  initialValue: _sort,
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (c) => const [
                    PopupMenuItem(value: _Sort.longest, child: Text('Longest stay first')),
                    PopupMenuItem(value: _Sort.newest, child: Text('Newest admission first')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.sm),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.sort, size: 20),
                      Gap.h8,
                      Text(_sort == _Sort.longest ? 'Longest stay first' : 'Newest first'),
                    ]),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: TourAnchor(
        id: 'ipd.admissions.list',
        child: LiveBuilder<List<_Row>>(
          watch: const {IpdCol.admissions, IpdCol.beds, Col.patients},
          deps: [_search, _show, _sort],
          load: _load,
          builder: (context, rows) => DataList<_Row>(
            items: rows,
            empty: EmptyState(
              icon: Icons.king_bed_outlined,
              title: _search.isNotEmpty
                  ? 'No admission matches "$_search"'
                  : switch (_show) {
                      _Show.current => 'No inpatients right now',
                      _Show.pending => 'No discharges waiting',
                      _Show.discharged => 'No discharges in the last 30 days',
                    },
            ),
            onTap: (r) => app.nav.open('ipd.admission', {'id': r.admission.id}),
            leading: (r) => Avatar(r.name, size: 36),
            title: (r) => r.name,
            subtitle: (r) => [
              if (r.admission.str('status') != IpdVals.discharged) r.bed?.str('label') ?? '',
              r.admission.str('status') == IpdVals.discharged ? plural(r.days, 'day') : 'Day ${r.days}',
              r.admission.str('diagnosis'),
            ].where((s) => s.isNotEmpty).join(' · '),
            trailing: (r) => AdmissionStatusChip(r.admission.str('status')),
            columns: [
              ListColumn('Patient', (r) => Row(children: [
                    Avatar(r.name, size: 32),
                    Gap.h12,
                    Expanded(child: TwoLine(r.name, [r.patient?.str('uhid') ?? '', r.admission.str('number')].where((s) => s.isNotEmpty).join(' · '))),
                  ]), flex: 4),
              ListColumn('Bed', (r) => TwoLine(r.bed?.str('label') ?? '—', r.ward?.str('name')), flex: 2),
              ListColumn(
                  _show == _Show.discharged ? 'Stay' : 'Admitted',
                  (r) => TwoLine(
                        _show == _Show.discharged ? plural(r.days, 'bed-day') : 'Day ${r.days}',
                        _show == _Show.discharged
                            ? 'Out ${formatDateShort(r.admission.date('discharged_at') ?? r.admission.updatedAt)}'
                            : formatDateShort(r.admission.date('admitted_at')!),
                      ),
                  flex: 2),
              ListColumn('Diagnosis', (r) => Text(r.admission.str('diagnosis', '—'), maxLines: 2, overflow: TextOverflow.ellipsis), flex: 4),
              ListColumn('Doctor', (r) => Text(shortDoctor(r.doctor?.str('display_name') ?? '—'), overflow: TextOverflow.ellipsis), flex: 2),
              ListColumn('Status', (r) => AdmissionStatusChip(r.admission.str('status')), width: 150),
            ],
          ),
        ),
      ),
    );
  }
}

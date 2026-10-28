import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../patient_service.dart';

enum _Filter { all, today, insured }

class PatientListScreen extends StatefulWidget {
  const PatientListScreen({super.key});

  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  String _search = '';
  _Filter _filter = _Filter.all;

  Query _query() {
    var q = const Query(Col.patients).matching(_search).sort('updated_at', desc: true).take(100);
    final today = startOfDay(DateTime.now());
    q = switch (_filter) {
      _Filter.all => q,
      _Filter.today => q.gte('created_at', today),
      _Filter.insured => q.isIn('payer_type', ['insurance', 'corporate']),
    };
    return q;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canEdit = context.can(PatientPerms.edit);
    return PageScaffold(
      title: 'Patients',
      subtitle: 'Search by name, patient ID or mobile number',
      primaryAction: canEdit
          ? PageAction('New patient', Icons.person_add_alt_1, () => app.nav.open('patients.register'),
              tourAnchor: 'patients.new')
          : null,
      headerBottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TourAnchor(
            id: 'patients.search',
            child: SearchField(hint: 'Name, UHID or phone', onChanged: (v) => setState(() => _search = v)),
          ),
          Gap.v12,
          FilterChips<_Filter>(
            options: const [(_Filter.all, 'All'), (_Filter.today, 'Registered today'), (_Filter.insured, 'Insurance / corporate')],
            value: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),
        ],
      ),
      body: LiveBuilder<List<Rec>>(
        watch: const {Col.patients},
        deps: [_search, _filter],
        load: (db) => db.query(_query()),
        builder: (context, patients) => DataList<Rec>(
          items: patients,
          empty: EmptyState(
            icon: Icons.people_outline,
            title: _search.isEmpty ? 'No patients yet' : 'No patient matches "$_search"',
            message: canEdit ? 'Register a patient to give them a UHID.' : null,
            action: canEdit
                ? FilledButton.icon(
                    onPressed: () => app.nav.open('patients.register'),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('New patient'))
                : null,
          ),
          onTap: (p) => app.nav.open('patients.profile', {'id': p.id}),
          leading: (p) => Avatar(p.str('full_name'), size: 36),
          title: (p) => p.str('full_name'),
          subtitle: PatientService.summary,
          trailing: (p) => _payerChip(p),
          columns: [
            ListColumn('Patient', (p) => Row(children: [
                  Avatar(p.str('full_name'), size: 32),
                  Gap.h12,
                  Expanded(child: TwoLine(p.str('full_name'), p.str('uhid'))),
                ]), flex: 4),
            ListColumn('Age / sex', (p) => Text('${ageLabel(p.date('dob'), p.intOrNull('age_years'))} · ${genderLabel(p.strOrNull('gender'))}')),
            ListColumn('Mobile', (p) => Text(p.str('phone', '—'))),
            ListColumn('City', (p) => Text(p.str('city', '—'), overflow: TextOverflow.ellipsis)),
            ListColumn('Registered', (p) => Text(formatDate(p.createdAt))),
            ListColumn('Payer', _payerChip, width: 120),
          ],
        ),
      ),
    );
  }

  Widget _payerChip(Rec p) => switch (p.str('payer_type', 'self')) {
        'insurance' => const StatusChip('Insurance', tone: Tone.info),
        'corporate' => const StatusChip('Corporate', tone: Tone.board),
        _ => const StatusChip('Self pay'),
      };
}

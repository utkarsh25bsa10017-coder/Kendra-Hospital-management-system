import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import '../pharmacy_schema.dart';

class _Meds {
  _Meds(this.waiting, this.dispenses, this.doctors);
  final List<Rec> waiting;
  final List<Rec> dispenses;
  final Map<String, Rec> doctors;
}

/// "Medicines" tab on the patient profile: prescriptions not yet collected,
/// and everything the pharmacy has given.
class PatientMedicinesTab extends StatelessWidget {
  const PatientMedicinesTab({super.key, required this.patient});
  final Rec patient;

  Future<_Meds> _load(ReadDb db) async {
    final rx = await db.query(Query(Col.prescriptions)
        .eq('patient_id', patient.id)
        .isIn('status', [Vals.active, Vals.partiallyDispensed])
        .sort('created_at', desc: true)
        .take(20));
    final d = await db.query(Query(PCol.dispenses).eq('patient_id', patient.id).sort('dispensed_at', desc: true).take(50));
    final doctors = await db.byIds(Col.users, [...rx.map((r) => r.strOrNull('doctor_id')), ...d.map((x) => x.strOrNull('doctor_id'))]);
    return _Meds(rx, d, doctors);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final canDispense = context.can(PharmacyPerms.dispense);
    return LiveBuilder<_Meds>(
      watch: const {Col.prescriptions, PCol.dispenses},
      deps: [patient.id],
      load: _load,
      builder: (context, m) {
        final theme = Theme.of(context);
        if (m.waiting.isEmpty && m.dispenses.isEmpty) {
          return EmptyState(
            icon: Icons.medication_outlined,
            title: 'No medicines from the pharmacy yet',
            message: 'Prescriptions and counter sales for this patient will show here.',
            action: canDispense
                ? FilledButton.icon(
                    onPressed: () => app.nav.open('pharmacy.sale', {'patientId': patient.id}),
                    icon: const Icon(Icons.point_of_sale_outlined),
                    label: const Text('Counter sale'))
                : null,
          );
        }
        final total = m.dispenses.fold<int>(0, (a, d) => a + d.integer('total_paise'));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (m.waiting.isNotEmpty) ...[
              SectionCard(
                title: 'Waiting at the pharmacy',
                child: Column(children: [
                  for (final (i, rx) in m.waiting.indexed) ...[
                    if (i > 0) const Divider(height: Gap.lg),
                    Row(children: [
                      Expanded(
                        child: TwoLine(
                          rx.maps('items').map((x) => x['drug_name']).join(', '),
                          '${m.doctors[rx.str('doctor_id')]?.str('display_name') ?? 'Doctor'} · ${formatDateTime(rx.createdAt)}'
                              '${rx.str('status') == Vals.partiallyDispensed ? ' · part dispensed' : ''}',
                        ),
                      ),
                      if (canDispense) ...[
                        Gap.h8,
                        FilledButton.tonal(
                          onPressed: () => app.nav.open('pharmacy.dispense_rx', {'prescriptionId': rx.id}),
                          child: const Text('Dispense'),
                        ),
                      ],
                    ]),
                  ],
                ]),
              ),
              Gap.v16,
            ],
            SectionCard(
              title: 'Given by the pharmacy',
              subtitle: '${plural(m.dispenses.length, 'visit')} · ${formatMoney(total)}',
              trailing: canDispense
                  ? TextButton.icon(
                      onPressed: () => app.nav.open('pharmacy.sale', {'patientId': patient.id}),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Counter sale'))
                  : null,
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
              child: m.dispenses.isEmpty
                  ? Text('Nothing dispensed yet.', style: theme.textTheme.bodyMedium)
                  : Column(children: [
                      for (final (i, d) in m.dispenses.indexed) ...[
                        if (i > 0) const Divider(height: 1),
                        InkWell(
                          onTap: () => app.nav.open('pharmacy.dispense_summary', {'id': d.id}),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: Gap.sm + 2),
                            child: Row(children: [
                              Expanded(
                                child: TwoLine(
                                  d.maps('items').map((x) => '${x['name']} × ${x['qty']}').join(', '),
                                  '${d.str('number')} · ${formatDateTime(d.date('dispensed_at'))} · ${switch (d.str('kind')) {
                                    DispenseKind.returned => 'returned',
                                    DispenseKind.counter => 'counter sale',
                                    _ => m.doctors[d.str('doctor_id')]?.str('display_name') ?? 'prescription',
                                  }}',
                                ),
                              ),
                              Gap.h8,
                              MoneyText(d.integer('total_paise')),
                            ]),
                          ),
                        ),
                      ],
                    ]),
            ),
          ],
        );
      },
    );
  }
}

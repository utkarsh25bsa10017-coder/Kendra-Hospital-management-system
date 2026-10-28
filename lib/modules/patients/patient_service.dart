import 'package:kendra_hms/core/core.dart';

abstract final class PatientPerms {
  static const view = 'patients.view';
  static const edit = 'patients.edit';
}

/// Registration rules shared by the screens and the demo seeder.
abstract final class PatientService {
  static String fullName(String first, String? last) =>
      [first.trim(), (last ?? '').trim()].where((s) => s.isNotEmpty).join(' ');

  /// Next UHID, e.g. SMH-26-000123. Numbers never repeat, even across devices.
  static Future<String> nextUhid(Db db, SettingsService settings) async {
    final prefix = settings.str(SettingKeys.uhidPrefix, 'H');
    final n = await db.nextSequence('uhid');
    final yy = (DateTime.now().year % 100).toString().padLeft(2, '0');
    return '$prefix-$yy-${n.toString().padLeft(6, '0')}';
  }

  static Map<String, Object?> _normalise(Map<String, Object?> data) {
    final out = {...data};
    final first = (out['first_name'] as String? ?? '').trim();
    final last = (out['last_name'] as String?)?.trim();
    out['first_name'] = first;
    out['last_name'] = last;
    out['full_name'] = fullName(first, last);
    final phone = (out['phone'] as String?)?.replaceAll(RegExp(r'[^0-9+]'), '');
    out['phone'] = phone;
    return out;
  }

  static Future<Rec> register(Db db, SettingsService settings, Map<String, Object?> data) async {
    final uhid = await nextUhid(db, settings);
    return db.insert(Col.patients, {..._normalise(data), 'uhid': uhid, 'payer_type': data['payer_type'] ?? 'self'});
  }

  static Future<Rec> updatePatient(Db db, Rec patient, Map<String, Object?> data) =>
      db.update(Col.patients, patient.id, _normalise(data), expectedVersion: patient.version);

  /// Existing patients who are probably the same person: same mobile number,
  /// or same name with the same date of birth.
  static Future<List<Rec>> possibleDuplicates(ReadDb db,
      {String? phone, required String first, String? last, DateTime? dob, String? excludeId}) async {
    final found = <String, Rec>{};
    final p = phone?.replaceAll(RegExp(r'[^0-9+]'), '') ?? '';
    if (p.length >= 10) {
      for (final r in await db.query(Query(Col.patients).eq('phone', p).take(10))) {
        found[r.id] = r;
      }
    }
    final name = fullName(first, last);
    if (name.length >= 3) {
      for (final r in await db.query(Query(Col.patients).where('full_name', Op.eq, name).take(10))) {
        final rd = r.date('dob');
        if (dob == null || rd == null || (rd.year == dob.year && rd.month == dob.month && rd.day == dob.day)) {
          found[r.id] = r;
        }
      }
    }
    found.remove(excludeId);
    return found.values.toList();
  }

  static String summary(Rec p) => [
        p.str('uhid'),
        ageLabel(p.date('dob'), p.intOrNull('age_years')),
        genderLabel(p.strOrNull('gender')),
        p.str('phone'),
      ].where((s) => s.isNotEmpty && s != '—').join(' · ');
}

const bloodGroups = ['A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−'];
const referralSources = ['Walk-in', 'Doctor referral', 'Existing patient', 'Online search', 'Camp / outreach', 'Insurance / TPA', 'Corporate', 'Other'];

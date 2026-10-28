import 'dart:math';

import 'package:kendra_hms/core/core.dart';

import 'patient_service.dart';

const _female = ['Aarti', 'Sneha', 'Pooja', 'Kavya', 'Ananya', 'Meena', 'Lakshmi', 'Fatima', 'Ritu', 'Sunita', 'Divya', 'Nisha', 'Shreya', 'Geeta', 'Zoya'];
const _male = ['Rohan', 'Amit', 'Rajesh', 'Karthik', 'Imran', 'Sanjay', 'Vivek', 'Arun', 'Manoj', 'Deepak', 'Harish', 'Nikhil', 'Joseph', 'Gurpreet', 'Faisal'];
const _last = ['Kulkarni', 'Deshpande', 'Patil', 'Sharma', 'Reddy', 'Iyer', 'Khan', 'Fernandes', 'Joshi', 'Pawar', 'Nair', 'Gupta', 'Shinde', 'Menon', 'Singh'];
const _cities = ['Pune', 'Pune', 'Pune', 'Pimpri-Chinchwad', 'Hadapsar', 'Wakad', 'Kothrud', 'Baner'];

/// Forty patients registered over the last 90 days, plus one deliberate
/// duplicate so the duplicate agent has something to find.
Future<void> seedDemoPatients(ModuleContext ctx) async {
  final db = ctx.systemDb;
  final settings = ctx.services.settings;
  final rnd = Random(7);
  for (var i = 0; i < 40; i++) {
    final female = rnd.nextBool();
    final first = female ? _female[rnd.nextInt(_female.length)] : _male[rnd.nextInt(_male.length)];
    final last = _last[rnd.nextInt(_last.length)];
    final age = i % 9 == 0 ? 1 + rnd.nextInt(10) : 18 + rnd.nextInt(60);
    final dob = DateTime.now().subtract(Duration(days: age * 365 + rnd.nextInt(300)));
    final payer = i % 6 == 0 ? 'insurance' : (i % 11 == 0 ? 'corporate' : 'self');
    await PatientService.register(db, settings, {
      'first_name': first,
      'last_name': last,
      'gender': female ? 'female' : 'male',
      'dob': dob,
      'phone': '9${(800000000 + rnd.nextInt(199999999)).toString()}',
      'city': _cities[rnd.nextInt(_cities.length)],
      'state': 'Maharashtra',
      'blood_group': bloodGroups[rnd.nextInt(bloodGroups.length)],
      'allergies': i % 7 == 0 ? 'Penicillin' : (i % 13 == 0 ? 'Sulfa drugs' : ''),
      'referral_source': referralSources[rnd.nextInt(referralSources.length)],
      'payer_type': payer,
      'insurer': payer == 'insurance' ? 'Star Health' : (payer == 'corporate' ? 'Infosys Ltd' : ''),
      'policy_no': payer == 'self' ? '' : 'POL${100000 + rnd.nextInt(899999)}',
      'emergency_name': '${female ? _male[rnd.nextInt(_male.length)] : _female[rnd.nextInt(_female.length)]} $last',
      'emergency_phone': '9${(800000000 + rnd.nextInt(199999999)).toString()}',
    });
  }
  // A receptionist registered the same person twice.
  final first = (await db.query(const Query(Col.patients).sort('created_at').take(1))).first;
  await PatientService.register(db, settings, {
    'first_name': first.str('first_name'),
    'last_name': first.str('last_name'),
    'gender': first.str('gender'),
    'dob': first.date('dob'),
    'phone': first.str('phone'),
    'city': first.str('city'),
    'payer_type': 'self',
  });
}

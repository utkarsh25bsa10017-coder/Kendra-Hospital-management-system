import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/duplicate_patient_agent.dart';
import 'demo_data.dart';
import 'patient_service.dart';
import 'screens/patient_form_screen.dart';
import 'screens/patient_list_screen.dart';
import 'screens/patient_profile_screen.dart';

/// Front desk registration and the patient profile that every other module
/// adds tabs and actions to. The `patients` table itself lives in core.
class PatientsModule extends HmsModule {
  @override
  String get id => 'patients';
  @override
  String get name => 'Patients';
  @override
  String get description => 'Registration with automatic UHIDs, duplicate checks and the patient profile.';
  @override
  IconData get icon => Icons.people_alt_outlined;

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(PatientPerms.view, 'See patient records', roles: {
          Roles.admin, Roles.board, Roles.doctor, Roles.nurse, Roles.receptionist, Roles.billing,
          Roles.pharmacist, Roles.labTech, Roles.pathologist, Roles.accountant,
        }),
        PermissionDef(PatientPerms.edit, 'Register and edit patients',
            roles: {Roles.admin, Roles.receptionist, Roles.doctor, Roles.nurse}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'patients.list',
          title: 'Patients',
          icon: Icons.people_alt_outlined,
          section: NavSection.frontDesk,
          order: 10,
          mobilePriority: 2,
          permission: PatientPerms.view,
          description: 'Find or register patients',
          builder: (c, a) => const PatientListScreen(),
        ),
        ModuleRoute(
          id: 'patients.register',
          title: 'Register patient',
          icon: Icons.person_add_alt_1,
          showInNav: false,
          permission: PatientPerms.edit,
          builder: (c, a) => const PatientFormScreen(),
        ),
        ModuleRoute(
          id: 'patients.edit',
          title: 'Edit patient',
          icon: Icons.edit,
          showInNav: false,
          permission: PatientPerms.edit,
          builder: (c, a) => PatientFormScreen(patientId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'patients.profile',
          title: 'Patient',
          icon: Icons.person_outline,
          showInNav: false,
          permission: PatientPerms.view,
          builder: (c, a) => PatientProfileScreen(patientId: a['id'] as String),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'patients.new',
          label: 'Register a new patient',
          icon: Icons.person_add_alt_1,
          permission: PatientPerms.edit,
          keywords: const ['new patient', 'registration', 'uhid', 'add'],
          run: (c) => c.app.nav.open('patients.register'),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'patients.nav',
          order: 10,
          anchorId: 'nav.patients.list',
          routeId: 'patients.list',
          permission: PatientPerms.view,
          title: 'Patients',
          body: 'Every patient has one record and one UHID. Search by name, UHID or mobile number.',
        ),
        TourStep(
          id: 'patients.new',
          order: 11,
          anchorId: 'patients.new',
          routeId: 'patients.list',
          permission: PatientPerms.edit,
          title: 'Register a patient',
          body: 'While you type, Kendra checks whether the person is already registered, '
              'so nobody ends up with two records.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [DuplicatePatientAgent()];

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoPatients(ctx);
}

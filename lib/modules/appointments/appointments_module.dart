import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/long_wait_agent.dart';
import 'agents/missed_appointments_agent.dart';
import 'appointment_service.dart';
import 'collections.dart';
import 'demo_data.dart';
import 'encounter_sync.dart';
import 'screens/board_screen.dart';
import 'screens/book_screen.dart';
import 'screens/common.dart';
import 'screens/dashboard_card.dart';
import 'screens/patient_tab.dart';
import 'screens/queue_screen.dart';
import 'screens/schedules_screen.dart';
import 'screens/today_screen.dart';

DateTime? _dateArg(Object? v) => switch (v) {
      DateTime d => d,
      String s => DateTime.tryParse(s),
      _ => null,
    };

/// Doctor schedules, bookings, walk-ins with tokens and the live waiting
/// room. Checking a patient in opens the OPD visit (a core encounter) that
/// the OPD module picks up.
class AppointmentsModule extends HmsModule {
  EncounterSync? _sync;

  @override
  String get id => 'appointments';
  @override
  String get name => 'Appointments';
  @override
  String get description => 'Doctor schedules, bookings, walk-ins with token numbers and the live waiting room.';
  @override
  IconData get icon => Icons.event_available_outlined;

  @override
  List<CollectionSchema> get collections => const [doctorSchedulesCollection, appointmentsCollection];

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(AppointmentPerms.view, 'See appointments and the waiting room',
            roles: {Roles.receptionist, Roles.doctor, Roles.nurse, Roles.admin, Roles.board}),
        PermissionDef(AppointmentPerms.manage, 'Book, check in and cancel appointments',
            roles: {Roles.receptionist, Roles.nurse, Roles.admin}),
        PermissionDef(AppointmentPerms.schedules, 'Set doctors\' OPD schedules', roles: {Roles.admin, Roles.receptionist}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'appointments.today',
          title: 'Appointments',
          icon: Icons.event_available_outlined,
          section: NavSection.frontDesk,
          order: 5,
          mobilePriority: 3,
          permission: AppointmentPerms.view,
          description: 'Today\'s appointments, check-in and walk-ins',
          builder: (c, a) => TodayScreen(initialDate: _dateArg(a['date']), initialDoctorId: a['doctorId'] as String?),
        ),
        ModuleRoute(
          id: 'appointments.book',
          title: 'Book appointment',
          icon: Icons.edit_calendar_outlined,
          showInNav: false,
          permission: AppointmentPerms.manage,
          builder: (c, a) => BookScreen(
            patientId: a['patientId'] as String?,
            doctorId: a['doctorId'] as String?,
            date: _dateArg(a['date']),
          ),
        ),
        ModuleRoute(
          id: 'appointments.queue',
          title: 'Waiting room',
          icon: Icons.groups_2_outlined,
          section: NavSection.frontDesk,
          order: 6,
          permission: AppointmentPerms.view,
          description: 'Live tokens and waiting times for each doctor',
          builder: (c, a) => const QueueScreen(),
        ),
        ModuleRoute(
          id: 'appointments.board',
          title: 'Waiting room TV',
          icon: Icons.tv_outlined,
          showInNav: false,
          permission: AppointmentPerms.view,
          builder: (c, a) => const QueueBoardScreen(),
        ),
        ModuleRoute(
          id: 'appointments.schedules',
          title: 'Doctor schedules',
          icon: Icons.calendar_view_week_outlined,
          section: NavSection.frontDesk,
          order: 7,
          permission: AppointmentPerms.schedules,
          description: 'Weekly OPD sessions for each doctor',
          builder: (c, a) => SchedulesScreen(doctorId: a['doctorId'] as String?),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'appointments.tab',
          title: 'Appointments',
          order: 20,
          permission: AppointmentPerms.view,
          builder: (c, p) => PatientAppointmentsTab(patient: p),
        ),
      ];

  @override
  List<PatientAction> get patientActions => [
        PatientAction(
          id: 'appointments.book',
          label: 'Book appointment',
          icon: Icons.edit_calendar_outlined,
          order: 10,
          permission: AppointmentPerms.manage,
          run: (c, p) => c.app.nav.open('appointments.book', {'patientId': p.id}),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'appointments.book',
          label: 'Book appointment',
          icon: Icons.edit_calendar_outlined,
          permission: AppointmentPerms.manage,
          keywords: const ['appointment', 'booking', 'slot', 'schedule', 'opd'],
          run: (c) => c.app.nav.open('appointments.book'),
        ),
        QuickAction(
          id: 'appointments.walk_in',
          label: 'Walk-in',
          icon: Icons.directions_walk,
          permission: AppointmentPerms.manage,
          keywords: const ['walk in', 'check in', 'token', 'queue', 'arrived'],
          run: (c) => startWalkIn(c),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
          id: 'appointments.today',
          title: 'Today\'s appointments',
          order: 20,
          permission: AppointmentPerms.view,
          builder: (c) => const TodayAppointmentsCard(),
        ),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'appointments.today',
          order: 20,
          anchorId: 'appointments.day',
          routeId: 'appointments.today',
          permission: AppointmentPerms.view,
          title: 'Appointments',
          body: 'Pick the day and the doctor here; the counts show who is booked, waiting, with the doctor or done. '
              'Tap a free slot to book it, and press Check in when the patient arrives: they get a token number.',
        ),
        TourStep(
          id: 'appointments.walk_in',
          order: 21,
          anchorId: 'appointments.walk_in',
          routeId: 'appointments.today',
          permission: AppointmentPerms.manage,
          title: 'Walk-in patients',
          body: 'Someone without an appointment? Press Walk-in, choose the patient, and Kendra suggests the doctor '
              'with the shortest queue.',
        ),
        TourStep(
          id: 'appointments.queue',
          order: 22,
          anchorId: 'appointments.tv',
          routeId: 'appointments.queue',
          permission: AppointmentPerms.view,
          title: 'Waiting room',
          body: 'The Waiting room shows live tokens and waiting times for every doctor. "Show on TV" puts a '
              'large token display on the waiting-room screen.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [LongWaitAgent(), MissedAppointmentsAgent()];

  @override
  Map<String, ProposalHandler> get proposalHandlers => {
        'appointments.mark_no_show': (ctx, proposal, db) async {
          final ids = (proposal.map('payload')['appointment_ids'] as List? ?? const []).whereType<String>().toList();
          final (marked, skipped) = await AppointmentService.markNoShowMany(db, ids);
          return 'Marked ${plural(marked, 'appointment')} as no-show'
              '${skipped > 0 ? '; ${plural(skipped, 'was', 'were')} no longer booked and left as is' : ''}';
        },
      };

  @override
  Future<void> onStart(ModuleContext ctx) async {
    _sync?.stop();
    _sync = EncounterSync(ctx)..start();
  }

  @override
  Future<void> onStop(ModuleContext ctx) async {
    _sync?.stop();
    _sync = null;
  }

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedDemoAppointments(ctx);
}

import '../core/modules/module.dart';
import '../modules/admin/admin_module.dart';
import '../modules/appointments/appointments_module.dart';
import '../modules/billing/billing_module.dart';
import '../modules/dashboard/dashboard_module.dart';
import '../modules/ipd/ipd_module.dart';
import '../modules/lab/lab_module.dart';
import '../modules/opd/opd_module.dart';
import '../modules/patients/patients_module.dart';
import '../modules/pharmacy/pharmacy_module.dart';
import '../modules/tower/tower_module.dart';

/// THE list of installed features. To add a module, add one line here.
/// To remove one, delete its line (and its folder under lib/modules/).
/// Its tables stay in the database, so no data is lost.
///
/// Order matters only for demo data: modules seed their samples in this
/// order, so put modules after the ones whose records they use.
List<HmsModule> installedModules() => [
      PatientsModule(),
      AppointmentsModule(),
      OpdModule(),
      LabModule(),
      PharmacyModule(),
      IpdModule(),
      BillingModule(),
      TowerModule(),
      DashboardModule(),
      AdminModule(),
    ];

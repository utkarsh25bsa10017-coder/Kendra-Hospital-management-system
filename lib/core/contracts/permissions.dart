/// Permissions are plain strings, `<module>.<action>`. Modules declare theirs
/// with [PermissionDef] and say which built-in roles get them by default.
library;

class PermissionDef {
  const PermissionDef(this.id, this.label, {this.description = '', this.roles = const {}});
  final String id;
  final String label;
  final String description;

  /// Built-in role ids that receive this permission by default.
  final Set<String> roles;
}

class RoleTemplate {
  const RoleTemplate(this.id, this.name, this.description);
  final String id;
  final String name;
  final String description;
}

abstract final class Roles {
  static const owner = 'owner';
  static const admin = 'admin';
  static const board = 'board';
  static const doctor = 'doctor';
  static const nurse = 'nurse';
  static const receptionist = 'receptionist';
  static const billing = 'billing';
  static const pharmacist = 'pharmacist';
  static const labTech = 'lab_tech';
  static const pathologist = 'pathologist';
  static const accountant = 'accountant';
  static const storeManager = 'store_manager';

  static const templates = <RoleTemplate>[
    RoleTemplate(owner, 'Owner / Director', 'Everything, including all reports and approvals.'),
    RoleTemplate(admin, 'Hospital administrator', 'Staff, settings, departments and configuration.'),
    RoleTemplate(board, 'Board member', 'Reviews findings from the agents and approves exceptions.'),
    RoleTemplate(doctor, 'Doctor', 'Consultations, clinical notes, prescriptions and orders.'),
    RoleTemplate(nurse, 'Nurse', 'Ward tasks, vitals and medication rounds.'),
    RoleTemplate(receptionist, 'Receptionist', 'Registration, appointments and queues.'),
    RoleTemplate(billing, 'Billing executive', 'Bills, payments and permitted adjustments.'),
    RoleTemplate(pharmacist, 'Pharmacist', 'Dispensing, medicine stock and purchases.'),
    RoleTemplate(labTech, 'Lab technician', 'Samples, worklists and result entry.'),
    RoleTemplate(pathologist, 'Pathologist', 'Verifies and authorises lab reports.'),
    RoleTemplate(accountant, 'Accountant', 'Collections, reconciliation and financial reports.'),
    RoleTemplate(storeManager, 'Store manager', 'Stock, suppliers and purchase orders.'),
  ];

  static RoleTemplate? template(String id) {
    for (final t in templates) {
      if (t.id == id) return t;
    }
    return null;
  }
}

abstract final class CorePerms {
  static const adminUsers = 'admin.users';
  static const adminRoles = 'admin.roles';
  static const adminSettings = 'admin.settings';
  static const adminModules = 'admin.modules';
  static const adminAudit = 'admin.audit';
  static const adminBackup = 'admin.backup';
  static const adminNetwork = 'admin.network';
  static const towerView = 'tower.view';
  static const towerDecide = 'tower.decide';
  static const approvalsDecide = 'approvals.decide';
  static const agentsManage = 'agents.manage';
  static const pricesEdit = 'prices.edit';

  static const defs = <PermissionDef>[
    PermissionDef(adminUsers, 'Manage staff accounts', roles: {Roles.admin}),
    PermissionDef(adminRoles, 'Edit roles and permissions', roles: {Roles.admin}),
    PermissionDef(adminSettings, 'Change hospital settings', roles: {Roles.admin}),
    PermissionDef(adminModules, 'Turn modules on or off', roles: {Roles.admin}),
    PermissionDef(adminAudit, 'View the audit log', roles: {Roles.admin, Roles.board, Roles.accountant}),
    PermissionDef(adminBackup, 'Back up and restore data', roles: {Roles.admin}),
    PermissionDef(adminNetwork, 'Manage the hospital network hub', roles: {Roles.admin}),
    PermissionDef(towerView, 'See agent findings', roles: {Roles.board, Roles.admin, Roles.accountant}),
    PermissionDef(towerDecide, 'Confirm, dismiss or assign findings', roles: {Roles.board}),
    PermissionDef(approvalsDecide, 'Approve discounts, refunds and agent proposals', roles: {Roles.board}),
    PermissionDef(agentsManage, 'Turn agents on or off', roles: {Roles.board, Roles.admin}),
    PermissionDef(pricesEdit, 'Edit the price list', roles: {Roles.admin, Roles.accountant}),
  ];
}

import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/expiry_agent.dart';
import 'agents/low_stock_agent.dart';
import 'agents/stock_integrity_agent.dart';
import 'catalog_data.dart';
import 'demo_data.dart';
import 'pharmacy_schema.dart';
import 'pharmacy_service.dart';
import 'screens/catalog_screen.dart';
import 'screens/dispense_queue_screen.dart';
import 'screens/dispense_screen.dart';
import 'screens/dispense_summary_screen.dart';
import 'screens/order_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/patient_medicines_tab.dart';
import 'screens/pharmacy_cards.dart';
import 'screens/product_screen.dart';
import 'screens/receive_screen.dart';
import 'screens/stock_screen.dart';

/// Dispensing against electronic prescriptions (FEFO batches), counter
/// sales, stock by batch, purchase orders and goods receipts. The medicine
/// master (`medicines`) lives in core and is shared with OPD.
class PharmacyModule extends HmsModule {
  @override
  String get id => 'pharmacy';
  @override
  String get name => 'Pharmacy & stock';
  @override
  String get description =>
      'Dispense prescriptions with first-expiry-first-out batches, counter sales, stock, purchase orders and receipts.';
  @override
  IconData get icon => Icons.medication_outlined;

  @override
  List<CollectionSchema> get collections => pharmacyCollections;

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(PharmacyPerms.view, 'See pharmacy stock and dispensing',
            roles: {Roles.pharmacist, Roles.storeManager, Roles.doctor, Roles.admin, Roles.board}),
        PermissionDef(PharmacyPerms.dispense, 'Dispense medicines and make counter sales', roles: {Roles.pharmacist}),
        PermissionDef(PharmacyPerms.purchase, 'Raise purchase orders and receive stock',
            roles: {Roles.pharmacist, Roles.storeManager}),
        PermissionDef(PharmacyPerms.catalog, 'Edit medicines, prices and suppliers',
            roles: {Roles.pharmacist, Roles.storeManager, Roles.admin}),
        PermissionDef(PharmacyPerms.adjust, 'Adjust stock and write off expired medicines',
            roles: {Roles.pharmacist, Roles.storeManager}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'pharmacy.dispense',
          title: 'Pharmacy',
          icon: Icons.medication_outlined,
          section: NavSection.operations,
          order: 10,
          mobilePriority: 4,
          permission: PharmacyPerms.view,
          description: 'Prescriptions waiting to be dispensed',
          builder: (c, a) => const DispenseQueueScreen(),
        ),
        ModuleRoute(
          id: 'pharmacy.dispense_rx',
          title: 'Dispense prescription',
          icon: Icons.medication_outlined,
          showInNav: false,
          permission: PharmacyPerms.dispense,
          builder: (c, a) => DispenseScreen(prescriptionId: a['prescriptionId'] as String?),
        ),
        ModuleRoute(
          id: 'pharmacy.sale',
          title: 'Counter sale',
          icon: Icons.point_of_sale_outlined,
          showInNav: false,
          permission: PharmacyPerms.dispense,
          builder: (c, a) => DispenseScreen(patientId: a['patientId'] as String?),
        ),
        ModuleRoute(
          id: 'pharmacy.dispense_summary',
          title: 'Dispense slip',
          icon: Icons.receipt_long_outlined,
          showInNav: false,
          permission: PharmacyPerms.view,
          builder: (c, a) => DispenseSummaryScreen(dispenseId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'pharmacy.stock',
          title: 'Stock',
          icon: Icons.inventory_2_outlined,
          section: NavSection.operations,
          order: 20,
          permission: PharmacyPerms.view,
          description: 'Medicine stock, value and expiry',
          builder: (c, a) => const StockScreen(),
        ),
        ModuleRoute(
          id: 'pharmacy.product',
          title: 'Medicine stock',
          icon: Icons.inventory_2_outlined,
          showInNav: false,
          permission: PharmacyPerms.view,
          builder: (c, a) => ProductScreen(productId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'pharmacy.orders',
          title: 'Purchase orders',
          icon: Icons.local_shipping_outlined,
          section: NavSection.operations,
          order: 30,
          permission: PharmacyPerms.purchase,
          description: 'Orders to suppliers and goods receipts',
          builder: (c, a) => const OrdersScreen(),
        ),
        ModuleRoute(
          id: 'pharmacy.order',
          title: 'Purchase order',
          icon: Icons.local_shipping_outlined,
          showInNav: false,
          permission: PharmacyPerms.purchase,
          builder: (c, a) => OrderScreen(orderId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'pharmacy.receive',
          title: 'Receive stock',
          icon: Icons.move_to_inbox_outlined,
          showInNav: false,
          permission: PharmacyPerms.purchase,
          builder: (c, a) => ReceiveScreen(orderId: a['orderId'] as String?),
        ),
        ModuleRoute(
          id: 'pharmacy.catalog',
          title: 'Medicines',
          icon: Icons.vaccines_outlined,
          section: NavSection.operations,
          order: 40,
          permission: PharmacyPerms.catalog,
          description: 'Medicine list, prices, reorder levels and suppliers',
          builder: (c, a) => const CatalogScreen(),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'pharmacy.medicines',
          title: 'Medicines',
          order: 40,
          permission: PharmacyPerms.view,
          builder: (c, p) => PatientMedicinesTab(patient: p),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'pharmacy.counter_sale',
          label: 'Counter sale',
          icon: Icons.point_of_sale_outlined,
          permission: PharmacyPerms.dispense,
          keywords: const ['pharmacy', 'sell', 'medicine', 'otc', 'bill'],
          run: (c) => c.app.nav.open('pharmacy.sale'),
        ),
        QuickAction(
          id: 'pharmacy.receive_stock',
          label: 'Receive stock',
          icon: Icons.move_to_inbox_outlined,
          permission: PharmacyPerms.purchase,
          keywords: const ['grn', 'goods receipt', 'purchase', 'supplier', 'invoice', 'stock in'],
          run: (c) => c.app.nav.open('pharmacy.receive'),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
            id: 'pharmacy.sales_today',
            title: 'Pharmacy sales today',
            order: 40,
            permission: PharmacyPerms.view,
            builder: (c) => const PharmacySalesCard()),
        DashboardCard(
            id: 'pharmacy.stock_value',
            title: 'Stock value',
            order: 41,
            permission: PharmacyPerms.view,
            builder: (c) => const StockValueCard()),
        DashboardCard(
            id: 'pharmacy.expiring',
            title: 'Expiring in 60 days',
            order: 42,
            permission: PharmacyPerms.view,
            builder: (c) => const ExpiringCard()),
        DashboardCard(
            id: 'pharmacy.low_stock',
            title: 'Low stock',
            order: 43,
            permission: PharmacyPerms.view,
            builder: (c) => const LowStockCard()),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'pharmacy.queue',
          order: 50,
          anchorId: 'nav.pharmacy.dispense',
          routeId: 'pharmacy.dispense',
          permission: PharmacyPerms.view,
          title: 'Pharmacy queue',
          body: 'Prescriptions arrive here as soon as the doctor saves them, oldest first, with how long each '
              'patient has been waiting.',
        ),
        TourStep(
          id: 'pharmacy.fefo',
          order: 51,
          anchorId: 'pharmacy.dispense_button',
          routeId: 'pharmacy.dispense',
          permission: PharmacyPerms.dispense,
          title: 'Dispense in one tap',
          body: 'Kendra matches each prescribed medicine to your stock, fills in the quantity and picks the batch '
              'that expires first. Check the allergy banner, change anything you need, then press Dispense.',
        ),
        TourStep(
          id: 'pharmacy.counter',
          order: 52,
          anchorId: 'pharmacy.counter_sale',
          routeId: 'pharmacy.dispense',
          permission: PharmacyPerms.dispense,
          title: 'Counter sales',
          body: 'For walk-in purchases: choose the patient, add medicines, and the charge goes to their bill.',
        ),
        TourStep(
          id: 'pharmacy.stock',
          order: 53,
          anchorId: 'pharmacy.stock_filters',
          routeId: 'pharmacy.stock',
          permission: PharmacyPerms.view,
          title: 'Stock at a glance',
          body: 'Filter to what needs attention: low, out of stock, near expiry or expired. Stock only changes '
              'through receipts, dispenses and adjustments with a reason, so the numbers can be trusted.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [LowStockAgent(), ExpiryAgent(), StockIntegrityAgent()];

  @override
  Map<String, ProposalHandler> get proposalHandlers => {
        'pharmacy.create_po': createPoFromProposal,
        'pharmacy.writeoff_expired': writeOffFromProposal,
      };

  @override
  Map<String, ApprovalHandler> get approvalHandlers => {
        'pharmacy.adjustment': (ctx, approval, db) {
          final p = approval.map('payload');
          return PharmacyService.applyAdjustment(
            db,
            batchId: p['batch_id'] as String,
            qtyDelta: (p['qty_delta'] as num).toInt(),
            reason: '${p['reason'] ?? approval.str('reason')} (approved)',
            byName: approval.str('requested_by_name', db.actor.name),
            approvalId: approval.id,
          );
        },
        'pharmacy.writeoff': (ctx, approval, db) {
          final ids = [for (final i in (approval.map('payload')['batch_ids'] as List? ?? const [])) '$i'];
          return PharmacyService.writeOffExpired(db, ids,
              byName: approval.str('requested_by_name', db.actor.name),
              reason: approval.str('reason', 'Expired'),
              approvalId: approval.id);
        },
      };

  @override
  Future<void> seedDefaults(ModuleContext ctx) => seedStarterCatalog(ctx.systemDb);

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedPharmacyDemo(ctx);
}

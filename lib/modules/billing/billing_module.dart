import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';

import 'agents/bill_matching_agent.dart';
import 'agents/cash_variance_agent.dart';
import 'agents/discount_patterns_agent.dart';
import 'agents/unpaid_bills_agent.dart';
import 'billing_schema.dart';
import 'billing_service.dart';
import 'demo_data.dart';
import 'screens/billing_desk_screen.dart';
import 'screens/billing_widgets.dart';
import 'screens/collections_screen.dart';
import 'screens/dashboard_cards.dart';
import 'screens/invoice_list_screen.dart';
import 'screens/invoice_screen.dart';
import 'screens/patient_bills_tab.dart';
import 'screens/price_list_screen.dart';
import 'screens/receipt_screen.dart';

/// Bills that assemble themselves from the charges other departments post,
/// payments, refunds and credit notes, the cash count at the end of the
/// day, and the agents that check every bill.
class BillingModule extends HmsModule {
  @override
  String get id => 'billing';
  @override
  String get name => 'Billing';
  @override
  String get description =>
      'Bills built from department charges, payments, refunds, credit notes and the end-of-day cash count.';
  @override
  IconData get icon => Icons.receipt_long_outlined;

  @override
  List<CollectionSchema> get collections => billingCollections;

  @override
  List<PermissionDef> get permissions => const [
        PermissionDef(BillingPerms.view, 'See bills and payments',
            roles: {Roles.billing, Roles.accountant, Roles.admin, Roles.board, Roles.receptionist}),
        PermissionDef(BillingPerms.invoice, 'Create and finalise bills', roles: {Roles.billing, Roles.receptionist}),
        PermissionDef(BillingPerms.payment, 'Take payments and refunds', roles: {Roles.billing, Roles.receptionist}),
        PermissionDef(BillingPerms.closeDay, 'See collections and close the day', roles: {Roles.billing, Roles.accountant}),
      ];

  @override
  List<ModuleRoute> get routes => [
        ModuleRoute(
          id: 'billing.desk',
          title: 'Billing',
          icon: Icons.point_of_sale_outlined,
          section: NavSection.finance,
          order: 10,
          mobilePriority: 4,
          permission: BillingPerms.view,
          description: 'Patients ready to be billed, drafts and today\'s bills',
          builder: (c, a) => const BillingDeskScreen(),
        ),
        ModuleRoute(
          id: 'billing.invoice',
          title: 'Bill',
          icon: Icons.receipt_long_outlined,
          showInNav: false,
          permission: BillingPerms.view,
          builder: (c, a) => InvoiceScreen(invoiceId: a['id'] as String?, patientId: a['patientId'] as String?),
        ),
        ModuleRoute(
          id: 'billing.receipt',
          title: 'Receipt',
          icon: Icons.receipt_outlined,
          showInNav: false,
          permission: BillingPerms.view,
          builder: (c, a) => ReceiptScreen(invoiceId: a['id'] as String),
        ),
        ModuleRoute(
          id: 'billing.invoices',
          title: 'Bills',
          icon: Icons.receipt_long_outlined,
          section: NavSection.finance,
          order: 20,
          permission: BillingPerms.view,
          description: 'Every bill and credit note',
          builder: (c, a) => const InvoiceListScreen(),
        ),
        ModuleRoute(
          id: 'billing.collections',
          title: 'Collections',
          icon: Icons.account_balance_wallet_outlined,
          section: NavSection.finance,
          order: 30,
          permission: BillingPerms.closeDay,
          description: 'Money in by mode and counter, and closing the day',
          builder: (c, a) => const CollectionsScreen(),
        ),
        ModuleRoute(
          id: 'billing.prices',
          title: 'Price list',
          icon: Icons.sell_outlined,
          section: NavSection.finance,
          order: 40,
          permission: CorePerms.pricesEdit,
          description: 'Services and their prices',
          builder: (c, a) => const PriceListScreen(),
        ),
      ];

  @override
  List<PatientTab> get patientTabs => [
        PatientTab(
          id: 'billing.bills',
          title: 'Bills',
          order: 60,
          permission: BillingPerms.view,
          builder: (c, p) => PatientBillsTab(patient: p),
        ),
      ];

  @override
  List<PatientAction> get patientActions => [
        PatientAction(
          id: 'billing.create_bill',
          label: 'Create bill',
          icon: Icons.receipt_long_outlined,
          order: 60,
          permission: BillingPerms.invoice,
          run: (c, p) => c.app.nav.open('billing.invoice', {'patientId': p.id}),
        ),
      ];

  @override
  List<QuickAction> get quickActions => [
        QuickAction(
          id: 'billing.new_bill',
          label: 'Create bill',
          icon: Icons.receipt_long_outlined,
          permission: BillingPerms.invoice,
          keywords: const ['bill', 'invoice', 'payment', 'charge', 'new bill'],
          run: (c) async {
            final p = await pickPatient(c, title: 'Bill which patient?');
            if (p != null && c.mounted) await openBillForPatient(c, p.id);
          },
        ),
        QuickAction(
          id: 'billing.collections',
          label: 'Collections',
          icon: Icons.account_balance_wallet_outlined,
          permission: BillingPerms.closeDay,
          keywords: const ['cash', 'close day', 'day end', 'counter', 'collection'],
          run: (c) => c.app.nav.open('billing.collections'),
        ),
      ];

  @override
  List<DashboardCard> get dashboardCards => [
        DashboardCard(
            id: 'billing.revenue_today', title: 'Revenue today', order: 10, permission: BillingPerms.view,
            builder: (c) => const RevenueTodayCard()),
        DashboardCard(
            id: 'billing.collections_today',
            title: 'Collections today',
            order: 11,
            size: CardSize.wide,
            permission: BillingPerms.view,
            builder: (c) => const CollectionsTodayCard()),
        DashboardCard(
            id: 'billing.outstanding', title: 'Outstanding', order: 12, permission: BillingPerms.view,
            builder: (c) => const OutstandingCard()),
        DashboardCard(
            id: 'billing.discounts_refunds',
            title: 'Discounts & refunds this month',
            order: 13,
            permission: BillingPerms.view,
            builder: (c) => const DiscountsRefundsCard()),
      ];

  @override
  List<TourStep> get tourSteps => const [
        TourStep(
          id: 'billing.ready',
          order: 60,
          anchorId: 'billing.ready',
          routeId: 'billing.desk',
          permission: BillingPerms.invoice,
          title: 'Ready to bill',
          body: 'Consultations, tests, medicines and bed-days appear here as soon as a department posts them. '
              'Tap a patient and the bill is made for you; check it and finalise.',
        ),
        TourStep(
          id: 'billing.take_payment',
          order: 61,
          anchorId: 'billing.today',
          routeId: 'billing.desk',
          permission: BillingPerms.payment,
          title: 'Take payment',
          body: 'Finalise a bill and take payment in the same step. Choose cash, UPI or card; the amount is already '
              'filled in. Split it across modes if the patient pays in parts.',
        ),
        TourStep(
          id: 'billing.request_discount',
          order: 62,
          anchorId: 'billing.drafts',
          routeId: 'billing.desk',
          permission: BillingPerms.invoice,
          title: 'Request discount',
          body: 'On a draft bill, choose Request discount. Within your own limit it applies at once and is logged; '
              'above it, the board approves first. The agents watch for unusual patterns.',
        ),
      ];

  @override
  List<HmsAgent> get agents => [BillMatchingAgent(), DiscountPatternsAgent(), CashVarianceAgent(), UnpaidBillsAgent()];

  @override
  Map<String, ApprovalHandler> get approvalHandlers => {
        BillingApprovals.discount: (ctx, approval, db) => BillingService.applyDiscount(db, approval),
        BillingApprovals.refund: (ctx, approval, db) => BillingService.applyRefund(db, approval),
        BillingApprovals.cancel: (ctx, approval, db) => BillingService.applyCancel(db, approval),
      };

  @override
  Future<void> seedDefaults(ModuleContext ctx) => seedPriceList(ctx);

  @override
  Future<void> seedDemo(ModuleContext ctx) => seedBillingDemo(ctx);
}

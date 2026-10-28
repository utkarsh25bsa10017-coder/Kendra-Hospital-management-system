# Writing a Kendra module

Kendra is one Flutter codebase that builds native apps for macOS, Windows and
Android. Every feature (patients, billing, pharmacy…) is a **module** under
`lib/modules/<id>/`. Modules plug into a small core (`lib/core/`) and never
import each other, so any module can be added or removed without breaking the
rest.

Read `lib/modules/patients/` first. It is the reference implementation: copy
its structure, naming and style.

## The rules

1. **One folder, one class.** `lib/modules/<id>/<id>_module.dart` defines
   `class XxxModule extends HmsModule`. Add it to `lib/app/module_list.dart`
   (one line) to install it. Delete that line to uninstall it.
2. **Never import another module.** Only `package:kendra_hms/core/core.dart`
   (plus Flutter and Dart). Modules talk to each other through:
   - the **contract collections** in `lib/core/contracts/collections.dart`
     (`patients`, `encounters`, `charges`, `services`, `service_orders`,
     `prescriptions`, `medicines`, …). Read their field comments.
   - **route ids**: `context.app.nav.open('billing.invoice', {'id': id})`.
     If the target module is switched off, the user just sees a message.
   - **extension points** on `HmsModule`: `patientTabs`, `patientActions`,
     `dashboardCards`, `quickActions`, `tourSteps`.
3. **Don't edit `lib/core/`.** If you need something there, build it inside
   your module and mention it in your report.
4. **No new packages.** Everything needed is in core or the Flutter SDK. The
   one exception is `package:pdf/widgets.dart` (imported `as pw`) for
   printed documents; see [Printing](#printing).
5. **Money is integer paise** everywhere (`*_paise`). Show it with
   `formatMoney` / `MoneyText`; read input with `MoneyField` + `parseMoney`.
6. **Never delete data.** Records are archived, never removed. Financial
   records are never edited after they are final: corrections are new
   records (credit notes, refunds, reversing stock movements).
7. **Every list query has a limit** (`.take(n)`).

## Data

Declare your tables as `CollectionSchema`s with `owner: '<module id>'`. The
store creates and migrates them automatically; adding a field later is just
adding it to the list.

```dart
const invoicesCollection = CollectionSchema(
  name: 'invoices',
  owner: 'billing',
  writePermissions: {'billing.invoice'},   // enforced on every device
  fields: [
    Field.text('number', required: true, unique: true, searchable: true),
    Field.ref('patient_id', Col.patients, required: true),
    Field.integer('net_paise'),
    Field.dateTime('finalised_at', indexed: true),
    Field.json('meta'),
  ],
);
```

- Read: `db.query(Query('invoices').eq('patient_id', id).sort('created_at', desc: true).take(50))`,
  `db.get`, `db.count`, `db.sum`, `db.aggregate(AggQuery(..., groupByDay: 'created_at', sums: ['net_paise']))`,
  `db.byIds(collection, ids)`.
- Write (in screens): `context.db.insert / update / archive / batch`. A
  `batch([InsertOp(...), UpdateOp(...)])` is all-or-nothing; use
  `context.db.newId()` to pre-assign ids that other ops in the batch refer to.
  Pass `expectedVersion: rec.version` when updating something a person was
  looking at, so two people can't overwrite each other.
- Every write is attributed to the signed-in user and lands in the
  tamper-evident audit log automatically.
- Numbering: `db.nextSequence('invoice')` (never repeats, works across devices).
- Unknown field names throw — that catches typos early.
- `Rec` accessors: `r.str('x')`, `r.integer('x')`, `r.date('x')`, `r.flag('x')`,
  `r.list<String>('x')`, `r.maps('items')`, `r.map('x')`, `r.id`, `r.version`,
  `r.createdAt`.

## Screens

Register screens as `ModuleRoute`s. Top-level ones (`showInNav: true`) appear
in the sidebar / bottom bar, grouped by `section`. Detail screens use
`showInNav: false` and are opened with `context.app.nav.open(id, args)`.

Build screens from the core UI kit so the whole app feels like one product:

| Need | Use |
| --- | --- |
| Page with title + main button | `PageScaffold(title:, subtitle:, primaryAction: PageAction(...), actions:, headerBottom:, body:)` |
| Live data that refreshes when anything changes (on any device) | `LiveBuilder<T>(watch: {collections}, deps: [filters], load: (db) => ..., builder: ...)` |
| Table on desktop, cards on phone | `DataList<Rec>(items:, columns: [ListColumn(...)], title:, subtitle:, trailing:, onTap:)`, `TwoLine` |
| Panels | `SectionCard`, `ResponsiveGrid`, `InfoGrid`, `SubHeading` |
| Status | `StatusChip(label, tone: Tone.success)`, `toneForSeverity` |
| Numbers | `KpiTile`, `BarChart`, `ShareBars` |
| Forms | `FormGrid` (+ `FullWidth`), `AppTextField`, `MoneyField`, `DateField`, `AppDropdown`, `SegmentedButton`, `Validators` |
| Dialogs | `showFormSheet` (dialog on desktop, full page on phone), `confirmDialog`, `reasonDialog(presets: [...])` |
| Pick things | `pickPatient`, `pickDoctor`, `pickRecord(query:, itemTitle:)`, `pickFolder` |
| Print | `PrintButton(name:, build:)` in the page's `actions`; see [Printing](#printing) |
| Errors | wrap writes in `runGuarded(context, () async {...}, success: 'Saved')` |
| Filters / search | `SearchField`, `FilterChips` |
| Empty / loading | `EmptyState`, `LoadingView` |
| Master–detail on wide screens | `SplitView` |
| Formatting | `formatMoney`, `formatDate`, `formatDateTime`, `formatTime`, `formatRelative`, `ageLabel`, `titleCase`, `plural` |
| Spacing | `Gap.v16`, `Gap.h8`, `Gap.lg`; breakpoints `context.isCompact` |

Design rules:
- It must work at **400 px (phone), 900 px (tablet) and 1440 px (desktop)**.
  `DataList`, `FormGrid`, `ResponsiveGrid` and `PageScaffold` do most of this.
  On phones the page's `primaryAction` becomes a floating button.
- Use theme colours (`Theme.of(context).colorScheme`) and `Tone`s. No new
  colours, no purple, no gradients.
- Plain, short, human labels ("Take payment", not "Initiate payment flow").
  Sentence case.
- Touch targets ≥ 44 px (the theme's buttons already are).
- Show the next useful action. After saving, say what happened (toast) and
  move the user on.
- Permission-check UI with `context.can('x.y')`; hide what the user can't do.

## Printing

Anything a patient takes home or a hospital files (bills, reports,
prescriptions, discharge summaries) gets a **Print** button. It opens the
system print dialog, which also offers "Save as PDF".

Build the document in its own file (`screens/<thing>_print.dart`) from the
same data the screen shows, with `PrintDoc` and the `PrintKit` helpers, so
every printout shares the letterhead, font and layout:

```dart
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> billPdf(BillData data, Letterhead letterhead) => PrintDoc(
      letterhead: letterhead,                  // Letterhead.of(context.app.settings)
      label: 'BILL / RECEIPT',
      meta: [inv.str('number'), formatDateTime(when)],
      banner: draft ? 'DRAFT — not valid as a bill until it is finalised' : null,
      footer: 'Computer-generated bill. No signature needed.',
      body: [
        PrintKit.fields([('Patient', name), ('UHID', uhid)]),
        PrintKit.table(headers: ['Item', 'Amount'], right: {1}, rows: [...]),
        PrintKit.totals([('Total', grossPaise, strong: true)]),
      ],
    ).build();
```

Then in the screen: `actions: [PrintButton(name: 'Bill INV-12', build: () => billPdf(data, Letterhead.of(context.app.settings)))]`.

Helpers: `PrintKit.fields`, `section`, `table` (cells are strings or
`PrintKit.twoLine`), `totals`, `paragraph`, `signature`; styles
`PrintKit.muted`, `small`, `strong`; colours `ink`, `grey`, `accent`,
`danger`. Long documents flow over pages, with the letterhead on page one
and "Page x of y" on every page. Test it with `expectPdf(bytes, '<module>_<name>')`
from `test/helpers.dart`, which saves `build/print/<module>_<name>.pdf`.
**Open the PDFs and look at them.**

## Permissions

Declare `PermissionDef('billing.invoice', 'Create and edit bills', roles: {Roles.billing, Roles.admin})`.
Built-in roles automatically receive the permissions you list for them. Use
`<module>.<action>` ids. The owner role has everything.

## Agents (monitoring) — least human input, but a human decides

Agents watch the data and report; **they never change anything**. They get a
read-only `ReadDb`.

```dart
class LowStockAgent extends HmsAgent {
  @override String get id => 'pharmacy.low_stock';
  @override String get name => 'Low stock';
  @override String get description => 'Suggests purchase orders before medicines run out.';
  @override Set<String> get watches => const {'pharmacy_batches'};  // run (debounced) when these change
  @override Duration get interval => const Duration(hours: 2);       // and at least this often

  @override
  Future<AgentReport> run(AgentContext ctx) async {
    ...
    return AgentReport(
      findings: [FindingDraft(key: 'batch:$id', title: ..., summary: ..., severity: Severity.medium,
          amountAtRiskPaise: ..., patientId: ..., subjectKey: 'product:$pid',
          evidence: [Evidence('Batch B12', collection: 'pharmacy_batches', id: id, routeId: 'pharmacy.stock')])],
      proposals: [ProposalDraft(key: 'po:$supplierId', title: 'Reorder 4 medicines from MedLine',
          summary: ..., handler: 'pharmacy.create_po', payload: {...})],
    );
  }
}
```

- Report the **current** state each run. A finding that is no longer
  reported is cleared automatically; one the board dismissed stays quiet.
  `key` must be stable between runs.
- High and critical findings alert the board instantly; others wait for the
  8 AM briefing.
- A **proposal** is the agent doing the legwork ("here is a purchase order
  for these 4 medicines") and a person approving it with one tap. Register
  the executor in `proposalHandlers: {'pharmacy.create_po': (ctx, proposal, db) async { ...; return 'Created PO-12'; }}`.
- Deterministic bookkeeping (posting bed-day charges, numbering, FEFO batch
  choice) is plain module code, not an agent.

## Approvals (discounts, refunds, write-offs)

```dart
final out = await context.app.approvals.request(
  type: 'billing.discount', title: 'Discount on INV-104', amountPaise: 50000,
  reason: reason, subjectCollection: 'invoices', subjectId: inv.id, patientId: pid,
  payload: {'invoice_id': inv.id});
// out.applied == true if it was within the user's own limit and already done.
```

Within the requester's `discount_limit_paise` it is applied at once (and
logged); above it, the board approves; above the hospital's high-value limit,
two different board members must approve; the requester can never approve
their own. Apply the change in `approvalHandlers: {'billing.discount': (ctx, approval, db) async {...}}`.

## Walkthrough

Add `TourStep`s for the main screens. Mark what you point at with
`TourAnchor(id: 'billing.take_payment', child: ...)`; sidebar items already
have anchors `nav.<route id>`. Set `routeId` so the tour opens the screen
first, and `permission` so people only see steps for what they can use.
Users see new steps once, as a "what's new" tour, when a module is added.

## Demo data

`seedDemo(ctx)` fills the demo hospital so every screen has something real
to show. Modules seed in `module_list.dart` order, so you can use patients
and staff created earlier: staff with role X are
`ctx.systemDb.query(Query(Col.users).contains('role_ids', '"doctor"'))`.
Write with `ctx.systemDb`. Keep it fast (a few hundred records at most).

## Checking your work

All heavy commands share one lock so several people (or agents) can work at
once without exhausting memory:

```bash
export PATH=$HOME/development/flutter/bin:$PATH
tool/kbuild.sh analyze lib/modules/<id> test/modules/<id>   # at most 2 at once
tool/kbuild.sh test test/modules/<id>                      # one at a time
```

- Put logic tests in `test/modules/<id>/`. Boot a hospital with
  `bootTestHospital([PatientsModule(), YourModule()], demo: true)` from
  `test/helpers.dart`, sign in with `signInDemo(app, 'billing')` (demo usernames:
  owner, admin, board, drkhan, drnair, reception, billing, pharmacy, lab,
  pathology, nurse, accounts — password `demo1234`; with `addUser` + `signIn`
  the password is `Passw0rd!`).
- Render your screens to PNG with `captureScreens` from
  `test/screens/capture.dart` at `desktopSize`, `tabletSize` and `phoneSize`,
  then **look at the PNGs** in `build/screens/` and fix anything that
  overflows, is cramped or unclear. Add `setUpAll(loadFonts)` from
  `test/screens/shots.dart`.
- `dart analyze` must report no issues.

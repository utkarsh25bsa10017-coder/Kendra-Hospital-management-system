# Kendra HMS

A hospital management system for small and medium multispeciality hospitals
in India. One Flutter codebase builds **native apps for macOS, Windows and
Android** — no web app, no cloud subscription.

- **Front desk:** registration with automatic UHIDs and duplicate checks,
  appointments, walk-ins, a token queue and a waiting-room TV display.
- **Clinical:** OPD consultations and EMR, prescriptions, lab and radiology
  orders, inpatient beds, nursing notes, discharge.
- **Diagnostics:** lab worklist, sample collection, result entry with
  critical-value flags, verification by a second person.
- **Pharmacy and stock:** prescriptions arrive electronically, batches are
  picked first-expiry-first-out, purchase orders and goods receipt.
- **Billing:** bills assemble themselves from what each department delivered.
  Discounts and refunds go through approvals, and finalised bills are never
  edited.
- **Control tower:** monitoring agents check every bill, stock movement and
  log entry. The board confirms, dismisses or assigns each finding and
  approves exceptions.
- **Administration:** staff and roles, modules on or off, network hub,
  backups, and a tamper-evident audit log.
- **Printing:** bills and receipts, lab reports, prescriptions and discharge
  summaries print on A4 with the hospital's letterhead, or save as PDF.

## Download

Installers for every platform are on the
[Releases page](https://github.com/utkarsh25bsa10017-coder/Kendra-Hospital-management-system/releases/latest).

| Device | File | How to install |
| --- | --- | --- |
| Windows 10 or 11 (64-bit) | `Kendra-HMS-windows-setup.exe` | Run it. If SmartScreen warns, click **More info → Run anyway**. |
| Windows, without installing | `Kendra-HMS-windows-portable.zip` | Unzip it and run `kendra_hms.exe`. |
| Mac (macOS 12 or later) | `Kendra-HMS-macos.dmg` | Open it and drag **Kendra HMS** to Applications. The first time, open **System Settings → Privacy & Security** and click **Open Anyway**. |
| Android 7 or later | `Kendra-HMS-android.apk` | Open the file on the device and allow installing from this source. |

On first launch, choose **Explore a demo hospital** to try it. Every demo
account uses the password `demo1234`.

## Why it costs almost nothing to run

| Need | Choice | Cost |
| --- | --- | --- |
| Apps for Mac, Windows, Android | Flutter (open source) | free |
| Database | Kendra's own data layer on **SQLite** (bundled, public domain) | free |
| Server | One Mac/Windows PC in the hospital acts as the **hub** on the local network | hardware you have |
| Monitoring agents | Rules + statistics running on the hub | free (no AI API bills) |
| Builds | GitHub Actions (`.github/workflows/build.yml`) | free tier |
| Fonts, icons | System fonts (SF, Segoe UI, Roboto), Material icons; Noto Sans bundled for printouts | free |
| Printing | The computer's own printers, through the system print dialog | free |

Data stays inside the hospital. Nothing is sent over the internet.

## How the pieces fit

```
 Reception PC ─┐                      ┌─ Doctor's laptop
 Android tablet┼──── hospital LAN ────┼─ Billing PC
 Pharmacy PC  ─┘          │           └─ Owner's phone
                          ▼
             ┌──────────────────────────┐
             │  Hub (main Mac/Windows)  │
             │  SQLite database         │
             │  audit log (hash chain)  │
             │  monitoring agents       │
             └──────────────────────────┘
```

- **Single device:** the database lives on the device. That's all you need for
  a clinic.
- **Hub:** switch on *Administration → Network*. Other devices connect with the
  hub's address and network key. Every request is checked against the
  signed-in person's permissions on the hub itself.
- **Clients** reconnect automatically: quickly at first, then every 2 minutes.

### Agents assist, people decide

Agents only **read**. They raise *findings* with evidence links, and they
draft *proposals*, for example "Reorder 4 medicines from MedLine".
Critical and high findings alert the board immediately; everything else goes
into the 8 AM briefing. Nothing that changes money, stock or clinical records
happens until a person approves it.

Approval rules:
- Discounts and refunds within a staff member's own limit apply straight away,
  and are logged.
- Anything above that limit needs a board member.
- Anything above the high-value limit needs two board members.
- Nobody can approve their own request.

When the board dismisses a finding with "Don't flag this again", that reason
tunes the agent.

### Modular by design

Each feature is a module in `lib/modules/<name>/`, and `lib/app/module_list.dart`
lists the installed modules, one line each.
- **Adding** a module means one new folder and one line.
- **Removing** one means deleting the line. Its data stays in the database.
- **Turning a module on or off** for a hospital is a switch in
  *Administration → Modules*.

Modules never import each other. They share a few contract tables (patients,
encounters, charges, orders, prescriptions) and open each other's screens by
route id. So removing a module can't break the rest. See
[docs/MODULE_GUIDE.md](docs/MODULE_GUIDE.md).

```
lib/
  app/            root widget + module list
  core/           data layer, auth, hub, agents, approvals, tour, UI kit, shell
  modules/        patients, appointments, opd, lab, pharmacy, ipd, billing,
                  tower (control tower), dashboard, admin
test/             core tests, module tests, screenshot tests
tool/             kbuild.sh (shared build slots), make_icons.py
```

### First run and the walkthrough

On first launch, a setup wizard offers three choices:
- set up a new hospital on this device;
- connect to an existing hub;
- explore a demo hospital with sample data, and one-tap sign-in for every role.

The first time each person signs in, a guided tour spotlights the parts of
the screen that matter for their role. When new modules are switched on later,
people get a short "what's new" tour. Anyone can replay the tour from the
profile menu.

## Running and building

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(stable).

```bash
flutter pub get
flutter run -d macos      # on a Mac (needs Xcode)
flutter run -d windows    # on Windows (needs Visual Studio with "Desktop development with C++")
flutter run -d <android-device-id>
```

Release builds:

```bash
flutter build macos --release      # build/macos/Build/Products/Release/Kendra HMS.app
flutter build windows --release    # build/windows/x64/runner/Release/
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
```

You can't build Mac and Windows apps on Linux. Either build them on those
machines, or let the included GitHub workflow build all three:

- Every push to `main` runs the tests and builds Android and Windows. Download
  them from the run's *Artifacts*.
- Pushing a version tag also builds macOS, then publishes a release with the
  Windows installer (made with the free Inno Setup, script in
  `windows/installer/`), a portable Windows zip, the macOS disk image and the
  APK:

  ```bash
  git tag v1.0.1 && git push origin v1.0.1
  ```

  Bump `version:` in `pubspec.yaml` to match first.

### Android release signing

Android only installs an update if it is signed with the same key as the
installed app, so make one key for the hospital and keep it safe (lose it and
every tablet has to uninstall and reinstall). Without a key, release builds
are signed with the debug key: fine for testing, not for real use.

```bash
keytool -genkey -v -keystore ~/kendra-release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias kendra
```

Then create `android/key.properties` (it is never committed):

```properties
storeFile=/home/you/kendra-release.jks
storePassword=...
keyAlias=kendra
keyPassword=...
```

For GitHub builds, add the repository secrets `ANDROID_KEYSTORE_BASE64`
(`base64 -w0 kendra-release.jks`), `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.

**macOS distribution:** the app runs straight away on the Mac that built it.
To hand it to other Macs without warnings, sign and notarise it with an Apple
Developer account (99 USD a year). Without one, macOS blocks the app the first
time it opens: go to *System Settings → Privacy & Security* and click *Open
Anyway* (on macOS 14 and earlier, right-clicking the app and choosing *Open*
also works).

## Tests

```bash
flutter test test/core            # data layer, audit chain, auth, approvals, agents, hub, printing
flutter test test/modules         # each module's business rules; printouts to build/print/*.pdf
flutter test test/e2e             # a patient's whole journey through every department
flutter test test/screens         # renders screens to build/screens/*.png
```

## Security notes

- Passwords are hashed with PBKDF2-HMAC-SHA256 (60,000 iterations) with a
  salt per user. Accounts lock for 5 minutes after 5 wrong attempts. Screens
  lock after a period of inactivity, which you can configure.
- Every write and every patient-record view is recorded in an append-only
  audit log. Each entry is hash-chained to the previous one, and
  *Administration → Audit log → Check integrity* detects any edit made outside
  the app.
- Permissions are enforced on the device that holds the data, not only in the
  screens.
- **Limitation:** devices talk to the hub over plain HTTP, protected by the
  network key and session tokens. Use it on the hospital's own private
  network, or over a VPN. Adding TLS is the next hardening step.
- Before going live, review the deployment against the DPDP Act and the
  medical-records obligations that apply to your hospital, with qualified
  counsel.

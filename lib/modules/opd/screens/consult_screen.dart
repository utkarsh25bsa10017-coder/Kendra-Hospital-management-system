import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kendra_hms/core/core.dart';

import '../clinical.dart';
import '../clinical_data.dart';
import '../opd_schema.dart';
import '../opd_service.dart';
import 'opd_widgets.dart';
import 'patient_summary_pane.dart';
import 'prescription_print.dart';
import 'rx_builder.dart';

/// The doctor's workspace for one OPD visit. Everything is autosaved as a
/// draft; "Finish consultation" signs it and sends medicines, tests and the
/// consultation charge on in one step.
class ConsultScreen extends StatefulWidget {
  const ConsultScreen({super.key, required this.encounterId});
  final String encounterId;

  /// Below this window width the summary and the note become two tabs.
  static const twoPaneWidth = 1280.0;

  @override
  State<ConsultScreen> createState() => _ConsultScreenState();
}

class _ConsultScreenState extends State<ConsultScreen> {
  bool _loading = true;
  String? _problem;
  late Db _db;
  late ReadDb _readDb;
  late Rec _me;
  Rec? _enc;
  Rec? _patient;
  Rec? _consult;
  bool _signed = false;

  final _complaint = TextEditingController();
  final _history = TextEditingController();
  final _exam = TextEditingController();
  final _diagnosis = TextEditingController();
  final _icd = TextEditingController();
  final _advice = TextEditingController();
  final _notes = TextEditingController();
  final _dxFocus = FocusNode();
  final _rxKey = GlobalKey<RxBuilderState>();
  Map<String, Object?> _vitals = const {};
  bool _vitalsDirty = false;
  List<Map<String, Object?>> _rx = [];
  List<Map<String, Object?>> _orders = [];
  DateTime? _followUp;

  List<DrugOption> _drugs = commonMedicines;
  List<TestOption> _tests = commonTests;
  List<DiagnosisOption> _frequent = const [];
  (Rec, DateTime)? _lastRx;
  List<Map<String, Object?>> _usual = const [];
  String? _usualFor;
  int _fee = 0;

  Timer? _saveTimer;
  Timer? _usualTimer;
  bool _dirty = false;
  Future<void> _saveChain = Future.value();
  final _status = ValueNotifier<String>('');
  bool _finishing = false;

  List<TextEditingController> get _textControllers => [_complaint, _history, _exam, _diagnosis, _icd, _advice, _notes];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading) return;
    _db = context.db;
    _readDb = context.app.readDb;
    _me = context.session!.user;
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _usualTimer?.cancel();
    if (_dirty && _consult != null && !_signed) {
      // Never lose typing: save what is left, quietly.
      OpdService.saveDraft(_db, _consult!.id, _patch()).then((_) {}, onError: (_) {});
    }
    for (final c in _textControllers) {
      c.dispose();
    }
    _dxFocus.dispose();
    _status.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final enc = await _readDb.get(Col.encounters, widget.encounterId);
      if (enc == null) {
        _problem = 'This visit was not found.';
        return;
      }
      _patient = await _readDb.get(Col.patients, enc.str('patient_id'));
      final existing = await OpdService.consultationFor(_readDb, enc.id);
      if (existing?.str('status') == ConsultStatus.signed) {
        _consult = existing;
        _enc = enc;
        _signed = true;
        return;
      }
      if (enc.str('status') != Vals.open) {
        _enc = enc;
        _problem = enc.str('status') == Vals.cancelled
            ? 'This patient was marked as left. Put them back in the queue to see them.'
            : 'This visit is closed.';
        return;
      }
      final c = await OpdService.start(_db, enc, doctor: _me);
      _enc = await _readDb.get(Col.encounters, enc.id) ?? enc;
      _consult = c;
      _complaint.text = c.str('chief_complaint');
      _history.text = c.str('history');
      _exam.text = c.str('examination');
      _diagnosis.text = c.str('diagnosis');
      _icd.text = c.str('icd_code');
      _advice.text = c.str('advice');
      _notes.text = c.str('notes');
      _vitals = c.map('vitals');
      _rx = c.maps('rx_draft');
      _orders = c.maps('orders_draft');
      _followUp = c.date('follow_up_date');

      _drugs = await OpdService.drugOptions(_readDb);
      _tests = await OpdService.testOptions(_readDb);
      _frequent = await OpdService.frequentDiagnoses(_readDb, _me.id);
      _lastRx = await OpdService.lastPrescription(_readDb, enc.str('patient_id'), excludeEncounterId: enc.id);
      final doctor = await _readDb.get(Col.users, c.str('doctor_id'));
      _fee = await OpdService.consultationFee(_readDb, doctor ?? _me);
      await _lookUpUsual();
      _status.value = c.version > 1 ? 'Draft saved ${formatTime(c.updatedAt)}' : 'New note';
      for (final t in _textControllers) {
        t.addListener(_edited);
      }
      _diagnosis.addListener(_diagnosisChanged);
    } catch (e) {
      _problem = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ------------------------------------------------------------------ autosave

  Map<String, Object?> _patch() => {
        'chief_complaint': _complaint.text.trim(),
        'history': _history.text.trim(),
        'examination': _exam.text.trim(),
        'diagnosis': _diagnosis.text.trim(),
        'icd_code': _icd.text.trim(),
        'advice': _advice.text.trim(),
        'notes': _notes.text.trim(),
        'follow_up_date': _followUp,
        'rx_draft': _rx,
        'orders_draft': _orders,
        if (_vitalsDirty) ...{
          'vitals': _vitals,
          'vitals_at': DateTime.now(),
          'vitals_by_name': _me.str('display_name'),
        },
      };

  void _edited() {
    if (_consult == null || _signed) return;
    _dirty = true;
    _status.value = 'Editing…';
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _save);
  }

  Future<void> _save() {
    _saveTimer?.cancel();
    return _saveChain = _saveChain.then((_) => _doSave());
  }

  Future<void> _doSave() async {
    if (!_dirty || _consult == null || _signed) return;
    _dirty = false;
    final hadVitals = _vitalsDirty;
    try {
      _consult = await OpdService.saveDraft(_db, _consult!.id, _patch());
      if (hadVitals) _vitalsDirty = false;
      _status.value = 'Draft saved ${formatTime(DateTime.now())}';
    } catch (e) {
      _dirty = true;
      _status.value = 'Not saved';
      if (mounted) context.toast('Could not save the draft: $e', error: true);
    }
  }

  void _diagnosisChanged() {
    _usualTimer?.cancel();
    _usualTimer = Timer(const Duration(milliseconds: 600), () async {
      await _lookUpUsual();
      if (mounted) setState(() {});
    });
  }

  Future<void> _lookUpUsual() async {
    final dx = _diagnosis.text.trim();
    if (dx.isEmpty) {
      _usual = const [];
      _usualFor = null;
      return;
    }
    _usual = await OpdService.usualPrescription(_readDb, _me.id, dx);
    _usualFor = dx;
  }

  void _setRx(List<Map<String, Object?>> items) {
    setState(() => _rx = items);
    _edited();
  }

  void _setFollowUp(DateTime? d) {
    setState(() => _followUp = d);
    _edited();
  }

  void _setOrders(List<Map<String, Object?>> items) {
    setState(() => _orders = items);
    _edited();
  }

  /// Adds medicines from an earlier prescription, skipping ones already
  /// written and asking about any the patient is allergic to.
  Future<void> _addFrom(List<Map<String, Object?>> source, String what) async {
    final allergies = _patient?.str('allergies') ?? '';
    final have = _rx.map((m) => (m['drug_name'] as String? ?? '').toLowerCase()).toSet();
    final fresh = [
      for (final m in source)
        if (!have.contains((m['drug_name'] as String? ?? '').toLowerCase())) OpdService.draftItem(m),
    ];
    if (fresh.isEmpty) {
      context.toast('Those medicines are already on the prescription');
      return;
    }
    final risky = fresh
        .where((m) => Allergy.match(allergies, drugName: m['drug_name'] as String? ?? '', genericName: m['generic_name'] as String?) != null)
        .toList();
    if (risky.isNotEmpty) {
      final keep = await confirmDialog(
        context,
        title: 'Allergy warning',
        message: 'The patient is allergic to "$allergies". '
            '${risky.map((m) => m['drug_name']).join(', ')} may cause a reaction.\n\nAdd ${risky.length == 1 ? 'it' : 'them'} anyway?',
        confirmLabel: 'Add anyway',
        destructive: true,
      );
      if (!keep) fresh.removeWhere(risky.contains);
    }
    if (fresh.isEmpty || !mounted) return;
    _setRx([..._rx, ...fresh]);
    context.toast('Added ${plural(fresh.length, 'medicine')} from $what. Check the doses and days.');
  }

  Future<void> _repeatLast() async {
    final last = _lastRx;
    if (last == null) return;
    await _addFrom(last.$1.maps('items'), 'the ${formatDate(last.$2)} prescription');
  }

  // ------------------------------------------------------------------ finish

  Future<void> _finish() async {
    if (_finishing || _consult == null) return;
    final rx = _rxKey.currentState;
    if (rx != null && rx.hasPendingEntry) {
      context.toast('Press Add to put ${rx.pendingName} on the prescription, or clear it', error: true);
      rx.focusMedicine();
      return;
    }
    if (_diagnosis.text.trim().isEmpty && _complaint.text.trim().isEmpty) {
      context.toast('Add a diagnosis (or at least the complaint) before finishing', error: true);
      _dxFocus.requestFocus();
      return;
    }
    setState(() => _finishing = true);
    _dirty = true;
    await _save();
    if (!mounted) return;
    FinishResult? result;
    final ok = await runGuarded(context, () async {
      result = await OpdService.finish(_db, _consult!.id, signer: _me);
    });
    if (!mounted) return;
    if (!ok || result == null) {
      setState(() => _finishing = false);
      return;
    }
    _signed = true;
    _consult = result!.consultation;
    final next = await OpdService.nextWaiting(_readDb, _me.id);
    final nextPatient = next == null ? null : await _readDb.get(Col.patients, next.str('patient_id'));
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => _FinishedDialog(
        result: result!,
        patientName: _patient?.str('full_name') ?? 'the patient',
        next: next,
        nextName: nextPatient?.str('full_name'),
      ),
    );
    if (!mounted) return;
    final app = context.app;
    final nav = Navigator.of(context);
    switch (choice) {
      case 'next':
        final ok2 = await runGuarded(context, () => OpdService.start(_db, next!, doctor: _me));
        nav.pop();
        if (ok2) {
          app.nav.toast('Token ${next!.intOrNull('token_no') ?? ''} · ${nextPatient?.str('full_name') ?? 'next patient'}, please come in');
          app.nav.open('opd.consult', {'encounterId': next.id});
        }
      case 'note':
        nav.pop();
        app.nav.open('opd.consultation', {'id': _consult!.id});
      default:
        if (app.registry.route('opd.queue') != null && app.nav.canOpen('opd.queue')) {
          app.nav.open('opd.queue');
        } else {
          nav.pop();
        }
    }
  }

  Future<void> _markLeft() async {
    final enc = _enc;
    if (enc == null) return;
    final ok = await confirmDialog(context,
        title: 'Mark ${_patient?.str('full_name') ?? 'patient'} as left?',
        message: 'The draft note is kept. You can put the patient back in the queue later.',
        confirmLabel: 'Mark as left');
    if (!ok || !mounted) return;
    await _save();
    if (!mounted) return;
    final nav = Navigator.of(context);
    final done = await runGuarded(context, () => OpdService.markLeft(_db, enc), success: 'Marked as left');
    if (done) nav.pop();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: LoadingView());
    final p = _patient;
    if (_signed && !_finishing) {
      final c = _consult!;
      return PageScaffold(
        title: p?.str('full_name') ?? 'Consultation',
        body: EmptyState(
          icon: Icons.task_alt,
          title: 'This consultation is finished',
          message: 'Signed by ${c.str('signed_by_name', 'the doctor')} on ${formatDateTime(c.date('signed_at'))}.',
          action: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              context.app.nav.open('opd.consultation', {'id': c.id});
            },
            icon: const Icon(Icons.description_outlined),
            label: const Text('View the note'),
          ),
        ),
      );
    }
    if (_problem != null || p == null || _consult == null) {
      return PageScaffold(
        title: p?.str('full_name') ?? 'Consultation',
        body: EmptyState(icon: Icons.info_outline, title: _problem ?? 'Could not open this consultation'),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= ConsultScreen.twoPaneWidth;
    final compact = context.isCompact;
    final allergies = p.str('allergies');
    final enc = _enc!;
    final subtitle = [
      'Token ${enc.intOrNull('token_no') ?? '–'}',
      patientLine(p),
      if (!compact) payerLabel(p),
    ].join(' · ');

    final note = _NotePane(state: this);
    final summary = PatientSummaryPane(
      patient: p,
      encounterId: enc.id,
      onRepeat: _lastRx == null ? null : _repeatLast,
    );

    Widget scroll(Widget child) => SingleChildScrollView(
          padding: EdgeInsets.only(top: Gap.xs, bottom: compact ? 96 : Gap.xl),
          child: child,
        );

    final body = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: scroll(summary)),
              Gap.h16,
              Expanded(child: scroll(note)),
            ],
          )
        : TabBarView(children: [KeepTabAlive(child: scroll(note)), KeepTabAlive(child: scroll(summary))]);

    return CallbackShortcuts(
      bindings: {
        modShortcut(LogicalKeyboardKey.enter): _finish,
        modShortcut(LogicalKeyboardKey.keyS): () {
          _dirty = true;
          _save();
        },
        modShortcut(LogicalKeyboardKey.keyM): () => _rxKey.currentState?.focusMedicine(),
        modShortcut(LogicalKeyboardKey.keyD): () => _dxFocus.requestFocus(),
      },
      child: DefaultTabController(
        length: 2,
        child: PageScaffold(
          title: p.str('full_name'),
          subtitle: subtitle,
          scrollable: false,
          primaryAction: PageAction(
            compact ? 'Finish' : 'Finish consultation',
            Icons.check_circle_outline,
            _finishing ? null : _finish,
            tourAnchor: 'opd.finish',
          ),
          actions: [
            ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (c, s, _) => compact
                  ? Tooltip(
                      message: s,
                      child: Icon(s == 'Not saved' ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                          size: 20, color: Theme.of(c).colorScheme.onSurfaceVariant),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(s == 'Not saved' ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                            size: 18, color: Theme.of(c).colorScheme.onSurfaceVariant),
                        Gap.h4,
                        Caption(s, maxLines: 1),
                      ]),
                    ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                switch (v) {
                  case 'save':
                    _dirty = true;
                    _save();
                  case 'left':
                    _markLeft();
                  case 'profile':
                    context.app.nav.open('patients.profile', {'id': p.id});
                }
              },
              itemBuilder: (c) => [
                PopupMenuItem(
                    value: 'save',
                    child: ListTile(
                        leading: const Icon(Icons.save_outlined), title: const Text('Save draft now'), trailing: Text('$modKeyLabel S'))),
                const PopupMenuItem(value: 'left', child: ListTile(leading: Icon(Icons.directions_walk), title: Text('Patient left'))),
                if (context.app.registry.route('patients.profile') != null)
                  const PopupMenuItem(value: 'profile', child: ListTile(leading: Icon(Icons.person_outline), title: Text('Patient profile'))),
              ],
            ),
          ],
          headerBottom: (allergies.isEmpty || Allergy.isNone(allergies)) && wide
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!Allergy.isNone(allergies)) AllergyBanner(allergies, dense: compact),
                    if (!wide) ...[
                      if (!Allergy.isNone(allergies)) Gap.v8,
                      const TabBar(tabs: [Tab(text: 'Note'), Tab(text: 'Patient summary')]),
                    ],
                  ],
                ),
          body: body,
        ),
      ),
    );
  }
}

class _NotePane extends StatelessWidget {
  const _NotePane({required this.state});
  final _ConsultScreenState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final theme = Theme.of(context);
    final specialty = specialtyOf(s._me.strOrNull('department') ?? s._enc?.strOrNull('department'));
    final vitalsBy = s._consult?.strOrNull('vitals_by_name');
    final vitalsAt = s._consult?.date('vitals_at');
    final last = s._lastRx;
    final compact = context.isCompact;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Caption(
                'Shortcuts: $modKeyLabel+Enter finish · $modKeyLabel+D diagnosis · $modKeyLabel+M add medicine · '
                '$modKeyLabel+S save. Everything is saved as you type.'),
          ),
        SectionCard(
          title: 'Vitals',
          subtitle: vitalsBy == null || s._vitals.isEmpty
              ? 'BP as 120/80. Temperature in °C or °F.'
              : 'Recorded by $vitalsBy${vitalsAt == null ? '' : ' at ${formatTime(vitalsAt)}'}',
          child: VitalsEditor(
            initial: s._vitals,
            onChanged: (v) {
              s._vitals = v;
              s._vitalsDirty = true;
              s._edited();
            },
          ),
        ),
        Gap.v12,
        SectionCard(
          title: 'Complaint and examination',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhraseField(
                label: 'Chief complaint',
                controller: s._complaint,
                phrases: Phrases.complaints(specialty),
                hint: 'What brings the patient in, and since when',
              ),
              Gap.v16,
              PhraseField(label: 'History', controller: s._history, phrases: Phrases.history(specialty)),
              Gap.v16,
              PhraseField(label: 'Examination', controller: s._exam, phrases: Phrases.examination(specialty)),
            ],
          ),
        ),
        Gap.v12,
        SectionCard(
          title: 'Diagnosis',
          child: DiagnosisField(
            controller: s._diagnosis,
            icd: s._icd,
            focusNode: s._dxFocus,
            frequent: s._frequent,
          ),
        ),
        Gap.v12,
        TourAnchor(
          id: 'opd.rx',
          child: SectionCard(
            title: 'Prescription',
            subtitle: s._rx.isEmpty ? null : plural(s._rx.length, 'medicine'),
            child: RxBuilder(
              key: s._rxKey,
              items: s._rx,
              onChanged: s._setRx,
              drugs: s._drugs,
              allergies: s._patient?.str('allergies') ?? '',
              lastRxLabel: last == null ? null : '${formatDateShort(last.$2)} · ${plural(last.$1.maps('items').length, 'medicine')}',
              onRepeatLast: last == null ? null : s._repeatLast,
              usual: s._usual,
              usualFor: s._usualFor,
              onUseUsual: s._usual.isEmpty ? null : () => s._addFrom(s._usual, 'your usual prescription'),
            ),
          ),
        ),
        Gap.v12,
        SectionCard(
          title: 'Tests',
          subtitle: s._orders.isEmpty ? null : plural(s._orders.length, 'test'),
          child: OrdersBuilder(items: s._orders, onChanged: s._setOrders, tests: s._tests),
        ),
        Gap.v12,
        SectionCard(
          title: 'Advice and follow-up',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhraseField(label: 'Advice to the patient', controller: s._advice, phrases: Phrases.advice(specialty)),
              Gap.v16,
              _FollowUp(
                value: s._followUp,
                onChanged: s._setFollowUp,
              ),
              Gap.v16,
              TextField(
                controller: s._notes,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Other notes (optional)', alignLabelWithHint: true),
              ),
            ],
          ),
        ),
        Gap.v12,
        Card(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Wrap(
              spacing: Gap.lg,
              runSpacing: Gap.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(
                    '${[
                      'Finishing signs the note',
                      if (s._rx.isNotEmpty) 'sends ${plural(s._rx.length, 'medicine')} to the pharmacy',
                      if (s._orders.isNotEmpty) 'orders ${plural(s._orders.length, 'test')}',
                      'adds the ${formatMoney(s._fee)} consultation charge',
                    ].join(', ')} and closes the visit.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Tooltip(
                  message: '$modKeyLabel + Enter',
                  child: FilledButton.icon(
                    onPressed: s._finishing ? null : s._finish,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(compact ? 'Finish consultation' : 'Finish consultation  ($modKeyLabel+Enter)'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FollowUp extends StatelessWidget {
  const _FollowUp({required this.value, required this.onChanged});
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  static const options = [(3, '3 days'), (7, '1 week'), (14, '2 weeks'), (30, '1 month')];

  @override
  Widget build(BuildContext context) {
    final today = startOfDay(DateTime.now());
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text('Follow-up', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        for (final (days, label) in options)
          ChoiceChip(
            label: Text(label),
            showCheckmark: false,
            selected: value != null && dayKey(value!) == dayKey(today.add(Duration(days: days))),
            onSelected: (_) => onChanged(today.add(Duration(days: days))),
          ),
        ChoiceChip(label: const Text('None'), showCheckmark: false, selected: value == null, onSelected: (_) => onChanged(null)),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 190,
          child: DateField(
            label: 'Date',
            value: value,
            firstDate: today,
            lastDate: today.add(const Duration(days: 730)),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _FinishedDialog extends StatelessWidget {
  const _FinishedDialog({required this.result, required this.patientName, this.next, this.nextName});
  final FinishResult result;
  final String patientName;
  final Rec? next;
  final String? nextName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = ToneColors.of(context, Tone.success);
    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 20, color: success.foreground),
            Gap.h12,
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ]),
        );
    final n = next;
    return AlertDialog(
      icon: Icon(Icons.task_alt, color: success.foreground, size: 36),
      title: Text(result.alreadySigned ? 'Already finished' : 'Consultation finished'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line(Icons.draw_outlined, 'Note for $patientName signed'),
            if (result.medicineCount > 0)
              line(Icons.medication_outlined, 'Prescription sent to the pharmacy · ${plural(result.medicineCount, 'medicine')}'),
            if (result.orderCount > 0) line(Icons.biotech_outlined, '${plural(result.orderCount, 'test')} ordered'),
            if (result.chargePaise != null)
              line(Icons.receipt_long_outlined, 'Consultation charge of ${formatMoney(result.chargePaise)} added to the bill'),
            Gap.v12,
            Caption(n == null ? 'No one else is waiting for you.' : 'Next: token ${n.intOrNull('token_no') ?? '–'} · ${nextName ?? ''}'),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            final db = context.app.readDb;
            final letterhead = Letterhead.of(context.app.settings);
            printDocument(context,
                name: 'Prescription $patientName ${formatDate(DateTime.now())}',
                build: () => prescriptionPdfFor(db, letterhead, result.consultation.id));
          },
          icon: const Icon(Icons.print_outlined, size: 20),
          label: const Text('Print'),
        ),
        TextButton(onPressed: () => Navigator.pop(context, 'note'), child: const Text('View note')),
        if (n == null)
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, 'queue'), child: const Text('Back to queue'))
        else ...[
          TextButton(onPressed: () => Navigator.pop(context, 'queue'), child: const Text('Back to queue')),
          FilledButton.icon(
            autofocus: true,
            onPressed: () => Navigator.pop(context, 'next'),
            icon: const Icon(Icons.arrow_forward),
            label: Text('Next patient · ${n.intOrNull('token_no') ?? ''}'),
          ),
        ],
      ],
    );
  }
}

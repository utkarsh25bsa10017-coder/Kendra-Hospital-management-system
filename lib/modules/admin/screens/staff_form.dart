import 'package:flutter/material.dart';
import 'package:kendra_hms/core/auth/auth_service.dart' show usernameProblem;
import 'package:kendra_hms/core/core.dart';

import '../admin_service.dart';

typedef NewStaff = ({Rec user, String password});

/// Opens the "Add staff" form. Returns the new account and its temporary
/// password, or null if cancelled.
Future<NewStaff?> showAddStaff(BuildContext context) =>
    showFormSheet<NewStaff>(context, title: 'Add staff', width: 680, builder: (c) => const StaffForm());

/// Opens the edit form for [user]. Returns the saved record.
Future<Rec?> showEditStaff(BuildContext context, Rec user) => showFormSheet<Rec>(context,
    title: 'Edit ${user.str('display_name')}', width: 680, builder: (c) => StaffForm(user: user));

/// Add a staff member, or edit one when [user] is given.
class StaffForm extends StatefulWidget {
  const StaffForm({super.key, this.user});
  final Rec? user;

  @override
  State<StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends State<StaffForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _dept = TextEditingController();
  final _spec = TextEditingController();
  final _reg = TextEditingController();
  final _fee = TextEditingController();
  final _discount = TextEditingController();
  final _roles = <String>{};
  bool _clinician = false;
  bool _clinicianTouched = false;
  bool _usernameTouched = false;
  bool _saving = false;
  String? _error;
  String? _rolesError;
  List<Rec>? _allRoles;
  Set<String> _taken = const {};

  bool get _editing => widget.user != null;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    if (u != null) {
      _name.text = u.str('display_name');
      _username.text = u.str('username');
      _phone.text = u.str('phone');
      _email.text = u.str('email');
      _dept.text = u.str('department');
      _spec.text = u.str('specialization');
      _reg.text = u.str('registration_no');
      _fee.text = moneyInput(u.intOrNull('consultation_fee_paise'));
      _discount.text = moneyInput(u.integer('discount_limit_paise'));
      _roles.addAll(u.list<String>('role_ids'));
      _clinician = u.flag('is_clinician');
      _clinicianTouched = true;
      _usernameTouched = true;
    } else {
      _discount.text = '0';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_allRoles == null) _load();
  }

  Future<void> _load() async {
    final db = context.app.readDb;
    final roles = await db.query(const Query(Col.roles).sort('name').take(500));
    final users = await db.query(const Query(Col.users).withArchived().take(5000));
    final order = {for (final (i, t) in Roles.templates.indexed) t.id: i};
    roles.sort((a, b) => (order[a.id] ?? 1000).compareTo(order[b.id] ?? 1000));
    if (!mounted) return;
    setState(() {
      _allRoles = roles;
      _taken = {for (final u in users) if (u.id != widget.user?.id) u.str('username')};
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _username, _phone, _email, _dept, _spec, _reg, _fee, _discount]) {
      c.dispose();
    }
    super.dispose();
  }

  void _nameChanged(String v) {
    if (_usernameTouched) return;
    final s = Staff.suggestUsername(v, _taken);
    _username.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
  }

  void _toggleRole(String id, bool on) {
    setState(() {
      on ? _roles.add(id) : _roles.remove(id);
      _rolesError = null;
      if (!_clinicianTouched) _clinician = _roles.contains(Roles.doctor);
    });
  }

  Map<String, Object?> _values() => {
        'display_name': _name.text,
        'username': _username.text,
        'role_ids': [
          for (final r in _allRoles ?? const <Rec>[])
            if (_roles.contains(r.id)) r.id,
          for (final r in _roles)
            if (!(_allRoles ?? const <Rec>[]).any((x) => x.id == r)) r,
        ],
        'is_clinician': _clinician,
        'department': _dept.text,
        'specialization': _clinician ? _spec.text : null,
        'registration_no': _clinician ? _reg.text : null,
        'consultation_fee_paise': _clinician ? parseMoney(_fee.text) : null,
        'discount_limit_paise': parseMoney(_discount.text) ?? 0,
        'phone': _phone.text,
        'email': _email.text,
      };

  Future<void> _save() async {
    final valid = _form.currentState!.validate();
    if (_roles.isEmpty) setState(() => _rolesError = 'Choose at least one role');
    if (!valid || _roles.isEmpty) return;
    final app = context.app;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Object result =
          _editing ? await Staff.update(app, widget.user!, _values()) : await Staff.add(app, _values());
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final roles = _allRoles;
    final me = context.session;
    final iAmOwner = me != null && Staff.sessionIsOwner(me);
    final limit = formatMoney(context.app.settings.highValueLimitPaise, alwaysDecimals: false);

    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _editing
                ? 'Changes apply the next time they open a screen.'
                : 'Kendra makes a temporary password for them. They choose their own at first sign-in.',
            style: muted,
          ),
          Gap.v8,
          const SubHeading('Person'),
          FormGrid(maxColumns: 2, children: [
            AppTextField(
              label: 'Full name',
              controller: _name,
              autofocus: !_editing,
              textCapitalization: TextCapitalization.words,
              validator: Validators.required('Full name'),
              onChanged: _nameChanged,
            ),
            AppTextField(
              label: 'Username',
              controller: _username,
              prefixIcon: Icons.alternate_email,
              helper: 'They sign in with this',
              validator: (v) {
                final u = (v ?? '').trim().toLowerCase();
                if (u.isEmpty) return 'Username is required';
                if (_taken.contains(u)) return 'Someone already uses "$u"';
                return usernameProblem(u);
              },
              onChanged: (_) => _usernameTouched = true,
            ),
            AppTextField(
              label: 'Mobile number',
              controller: _phone,
              keyboardType: TextInputType.phone,
              prefixIcon: Icons.phone_outlined,
              validator: Validators.phone,
            ),
            AppTextField(
              label: 'Email',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              prefixIcon: Icons.mail_outline,
              validator: Validators.email,
            ),
          ]),
          Gap.v16,
          const SubHeading('What they do'),
          Text('Pick every role that fits. Each role opens the screens that job needs.', style: muted),
          Gap.v8,
          if (roles == null)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final r in roles)
                  if (r.id != Roles.owner || iAmOwner || _roles.contains(Roles.owner))
                    FilterChip(
                      label: Text(r.str('name')),
                      tooltip: r.str('description'),
                      selected: _roles.contains(r.id),
                      onSelected: (r.id == Roles.owner && !iAmOwner) ? null : (v) => _toggleRole(r.id, v),
                    ),
              ],
            ),
          if (_rolesError != null) ...[
            Gap.v8,
            Text(_rolesError!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
          if (roles != null && _roles.isNotEmpty) ...[
            Gap.v12,
            for (final r in roles.where((r) => _roles.contains(r.id)))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline, size: 16, color: theme.colorScheme.primary),
                    Gap.h8,
                    Expanded(
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: r.str('name'), style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (r.str('description').isNotEmpty) TextSpan(text: ' — ${r.str('description')}'),
                      ]), style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
          Gap.v16,
          const SubHeading('Clinical'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _clinician,
            onChanged: (v) => setState(() {
              _clinician = v;
              _clinicianTouched = true;
            }),
            title: const Text('Sees patients as a doctor or consultant'),
            subtitle: const Text('They can be chosen as the doctor for appointments, consultations and admissions.'),
          ),
          Gap.v8,
          FormGrid(maxColumns: 2, children: [
            AppTextField(label: 'Department', controller: _dept, textCapitalization: TextCapitalization.words, hint: 'e.g. Paediatrics'),
            if (_clinician) ...[
              AppTextField(label: 'Specialization', controller: _spec, textCapitalization: TextCapitalization.words, hint: 'e.g. Paediatrician'),
              AppTextField(label: 'Registration no.', controller: _reg, helper: 'Medical council registration number'),
              MoneyField(label: 'Consultation fee', controller: _fee, helper: 'Charged for an OPD visit'),
            ],
          ]),
          Gap.v16,
          const SubHeading('Discounts and refunds'),
          FormGrid(maxColumns: 1, children: [
            MoneyField(
              label: 'Can approve on their own up to',
              controller: _discount,
              helper: 'Up to this amount their discounts and refunds apply at once. Above it a board member must '
                  'approve, and above $limit two board members. Leave 0 if every discount should be approved.',
            ),
          ]),
          if (_error != null) ...[
            Gap.v16,
            Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ],
          Gap.v24,
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: Icon(_editing ? Icons.check : Icons.person_add_alt_1, size: 18),
                label: Text(_editing ? 'Save changes' : 'Create account'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

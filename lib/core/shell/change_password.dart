import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../auth/password.dart';
import '../services/app_services.dart';
import '../ui/forms.dart';
import '../ui/tokens.dart';

/// [forced]: shown after an administrator reset the password; cannot be skipped.
Future<void> showChangePasswordDialog(BuildContext context, {bool forced = false}) => showDialog<void>(
      context: context,
      barrierDismissible: !forced,
      builder: (_) => _ChangePassword(forced: forced),
    );

class _ChangePassword extends StatefulWidget {
  const _ChangePassword({required this.forced});
  final bool forced;

  @override
  State<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<_ChangePassword> {
  final _form = GlobalKey<FormState>();
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.app.auth.changePassword(_old.text, _new.text);
      if (!mounted) return;
      Navigator.pop(context);
      context.toast('Password changed');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.forced,
      child: AlertDialog(
        title: Text(widget.forced ? 'Choose a new password' : 'Change password'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.forced) ...[
                  const Text('Your administrator set a temporary password. Choose your own to continue.'),
                  Gap.v16,
                ],
                AppTextField(
                  label: widget.forced ? 'Temporary password' : 'Current password',
                  controller: _old,
                  obscure: true,
                  autofocus: true,
                  validator: Validators.required('Password'),
                ),
                Gap.v12,
                AppTextField(
                  label: 'New password',
                  controller: _new,
                  obscure: true,
                  helper: 'At least 8 characters, with letters and a number',
                  validator: (v) => passwordProblem(v ?? ''),
                ),
                Gap.v12,
                AppTextField(
                  label: 'New password again',
                  controller: _again,
                  obscure: true,
                  onSubmitted: (_) => _save(),
                  validator: (v) => v != _new.text ? 'The passwords do not match' : null,
                ),
                if (_error != null) ...[
                  Gap.v12,
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (!widget.forced) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save password')),
        ],
      ),
    );
  }
}

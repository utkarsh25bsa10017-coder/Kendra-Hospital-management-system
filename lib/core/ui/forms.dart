import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'tokens.dart';

abstract final class Validators {
  static FormFieldValidator<String> required([String label = 'This']) =>
      (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null;

  static String? phone(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10 || digits.length > 13) return 'Enter a 10-digit mobile number';
    return null;
  }

  static String? requiredPhone(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Mobile number is required' : phone(v);

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim()) ? null : 'Enter a valid email';
  }

  static String? money(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final p = parseMoney(v);
    if (p == null) return 'Enter an amount like 1250 or 1250.50';
    if (p < 0) return 'Amount cannot be negative';
    return null;
  }

  static String? requiredMoney(String? v) => (v == null || v.trim().isEmpty) ? 'Amount is required' : money(v);

  static String? positiveInt(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = int.tryParse(v.trim());
    if (n == null || n <= 0) return 'Enter a whole number above 0';
    return null;
  }
}

/// Text field with the app's label style and sensible keyboard handling.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.validator,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.prefixIcon,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.textInputAction,
    this.inputFormatters,
    this.readOnly = false,
    this.onTap,
    this.obscure = false,
    this.enabled = true,
    this.initialValue,
    this.textCapitalization = TextCapitalization.none,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final TextInputType? keyboardType;
  final int? maxLines;
  final int? minLines;
  final IconData? prefixIcon;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final bool readOnly;
  final VoidCallback? onTap;
  final bool obscure;
  final bool enabled;
  final String? initialValue;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? initialValue : null,
      validator: validator,
      keyboardType: keyboardType,
      maxLines: obscure ? 1 : maxLines,
      minLines: minLines,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      autofocus: autofocus,
      textInputAction: textInputAction ?? (maxLines == 1 ? TextInputAction.next : TextInputAction.newline),
      inputFormatters: inputFormatters,
      readOnly: readOnly,
      onTap: onTap,
      obscureText: obscure,
      enabled: enabled,
      textCapitalization: textCapitalization,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
        suffixIcon: suffix,
        alignLabelWithHint: (maxLines ?? 2) > 1,
      ),
    );
  }
}

/// Rupee amount input. Read the value with `parseMoney(controller.text)`.
class MoneyField extends StatelessWidget {
  const MoneyField({super.key, required this.label, required this.controller, this.required = false, this.helper, this.onChanged});
  final String label;
  final TextEditingController controller;
  final bool required;
  final String? helper;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        validator: required ? Validators.requiredMoney : Validators.money,
        onChanged: onChanged,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: label, prefixText: '₹ ', helperText: helper),
      );
}

/// Date picker field.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
    this.required = false,
    this.helper,
  });
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool required;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return FormField<DateTime>(
      initialValue: value,
      validator: (_) => required && value == null ? '$label is required' : null,
      builder: (state) => InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: value ?? now,
            firstDate: firstDate ?? DateTime(1900),
            lastDate: lastDate ?? DateTime(now.year + 5),
          );
          if (picked != null) {
            onChanged(picked);
            state.didChange(picked);
          }
        },
        child: InputDecorator(
          isEmpty: value == null,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            errorText: state.errorText,
            suffixIcon: value != null && !required
                ? IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      onChanged(null);
                      state.didChange(null);
                    })
                : const Icon(Icons.calendar_today_outlined),
          ),
          child: SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(value == null ? '' : formatDate(value), style: Theme.of(context).textTheme.bodyLarge),
            ),
          ),
        ),
      ),
    );
  }
}

class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.validator,
    this.helper,
  });
  final String label;
  final T? value;
  final List<(T, String)> items;
  final ValueChanged<T?> onChanged;
  final FormFieldValidator<T>? validator;
  final String? helper;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: items.any((i) => i.$1 == value) ? value : null,
        isExpanded: true,
        validator: validator,
        decoration: InputDecoration(labelText: label, helperText: helper),
        items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
        onChanged: onChanged,
      );
}

/// Lays out form fields in 1–3 columns depending on width.
class FormGrid extends StatelessWidget {
  const FormGrid({super.key, required this.children, this.minFieldWidth = 260, this.maxColumns = 3});
  final List<Widget> children;
  final double minFieldWidth;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minFieldWidth).floor().clamp(1, maxColumns);
      final w = (c.maxWidth - (cols - 1) * Gap.lg) / cols;
      return Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.lg,
        children: [
          for (final ch in children) ch is FullWidth ? SizedBox(width: c.maxWidth, child: ch.child) : SizedBox(width: w, child: ch),
        ],
      );
    });
  }
}

/// Inside a [FormGrid], spans the whole row.
class FullWidth extends StatelessWidget {
  const FullWidth({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

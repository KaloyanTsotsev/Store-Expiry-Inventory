import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/delivery_draft.dart';

/// Formats numeric DMY input; explicit ISO/slash/dash formats remain editable.
class BulgarianDateInputFormatter extends TextInputFormatter {
  const BulgarianDateInputFormatter();
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed ||
        newValue.text.contains(RegExp(r'[/\-]')) ||
        !RegExp(r'^[0-9.]*$').hasMatch(newValue.text)) {
      return newValue;
    }
    var raw = newValue.text;
    var cursor = newValue.selection.extentOffset.clamp(0, raw.length);
    // Backspace over an inserted separator deletes the preceding digit too.
    if (oldValue.selection.isCollapsed &&
        newValue.selection.isCollapsed &&
        oldValue.text.length == raw.length + 1 &&
        cursor > 0 &&
        oldValue.text[cursor] == '.') {
      raw = raw.replaceRange(cursor - 1, cursor, '');
      cursor--;
    }
    final digits = raw.replaceAll('.', '');
    if (digits.length > 8) return newValue;
    String format(String value) => [
      for (var i = 0; i < value.length; i++)
        '${i == 2 || i == 4 ? '.' : ''}${value[i]}',
    ].join();
    final before = raw.substring(0, cursor).replaceAll('.', '').length;
    final text = format(digits);
    int offset(int count) => count + (count > 2 ? 1 : 0) + (count > 4 ? 1 : 0);
    final baseDigits = raw
        .substring(0, newValue.selection.baseOffset.clamp(0, raw.length))
        .replaceAll('.', '')
        .length;
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: newValue.selection.isCollapsed
            ? offset(before)
            : offset(baseDigits),
        extentOffset: offset(before),
      ),
    );
  }
}

class ExpiryDateField extends StatelessWidget {
  const ExpiryDateField({
    super.key,
    required this.controller,
    required this.enabled,
    this.onChanged,
    this.label = 'Срок на годност',
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final String label;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: parseDocumentDate(controller.text) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: 'Изберете срок на годност',
      cancelText: 'Отказ',
      confirmText: 'Избери',
    );
    if (!context.mounted || selected == null) return;
    final value = formatDocumentDate(selected);
    controller.text = value;
    onChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final date = parseDocumentDate(value.text);
      final normalized = date == null ? null : formatDocumentDate(date);
      return TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: const [BulgarianDateInputFormatter()],
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          hintText: 'ДД.ММ.ГГГГ',
          helperText: normalized != null && value.text != normalized
              ? 'Разчетена дата: $normalized'
              : null,
          suffixIcon: IconButton(
            tooltip: 'Избери дата от календара',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: enabled ? () => _pick(context) : null,
          ),
        ),
      );
    },
  );
}

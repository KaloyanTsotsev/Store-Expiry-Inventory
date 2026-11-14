import 'package:flutter/material.dart';

import '../models/delivery_draft.dart';

/// Owns a temporary value. Only the explicit confirmation returns a new value.
class QuantityCorrectionDialog extends StatefulWidget {
  const QuantityCorrectionDialog({super.key, required this.initialValue});

  final String initialValue;

  @override
  State<QuantityCorrectionDialog> createState() =>
      _QuantityCorrectionDialogState();
}

class _QuantityCorrectionDialogState extends State<QuantityCorrectionDialog> {
  late final controller = TextEditingController(text: widget.initialValue);
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = controller.text.trim();
    final quantity = parseQuantity(value);
    if (quantity == null || quantity <= 0) {
      setState(() => error = 'Въведете валидно положително количество.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Корекция на количество'),
    content: TextField(
      key: const Key('quantity-correction-input'),
      controller: controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(labelText: 'Количество', errorText: error),
      onChanged: (_) {
        if (error != null) setState(() => error = null);
      },
      // Keyboard completion dismisses only the keyboard, never the dialog.
      onSubmitted: (_) => FocusScope.of(context).unfocus(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отказ'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('Готово')),
    ],
  );
}

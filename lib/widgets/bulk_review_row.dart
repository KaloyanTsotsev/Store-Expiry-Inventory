import 'package:flutter/material.dart';

import '../models/delivery_draft.dart';

class BulkReviewRow extends StatefulWidget {
  final DraftItem item;
  final bool enabled;
  final String productLabel;
  final String productDetail, detailsLabel;
  final VoidCallback? onAddCatalog;
  final VoidCallback onChanged, onDetails;
  const BulkReviewRow({
    super.key,
    required this.item,
    required this.enabled,
    required this.productLabel,
    this.productDetail = '',
    this.detailsLabel = 'Детайли',
    this.onAddCatalog,
    required this.onChanged,
    required this.onDetails,
  });
  @override
  State<BulkReviewRow> createState() => _BulkReviewRowState();
}

class _BulkReviewRowState extends State<BulkReviewRow> {
  static const labels = {
    'name': 'Наименование',
    'supplierCode': 'Артикул',
    'ordered': 'Заявени',
    'received': 'Получени',
    'expiry': 'Годност • ДД.ММ.ГГГГ',
    'lot': 'Партида',
  };
  late final fields = {
    for (final key in labels.keys)
      key: TextEditingController(text: widget.item.toJson()[key] as String),
  };
  String? error;
  late final lotFocus = FocusNode()..addListener(_finishLot);

  void _finishLot() {
    if (!lotFocus.hasFocus) fields['lot']!.text = widget.item.lot;
  }

  @override
  void didUpdateWidget(covariant BulkReviewRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final entry in fields.entries) {
      if (entry.key == 'lot' && lotFocus.hasFocus) continue;
      final text = widget.item.toJson()[entry.key] as String;
      if (entry.value.text != text) entry.value.text = text;
    }
  }

  @override
  void dispose() {
    lotFocus.removeListener(_finishLot);
    lotFocus.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('${widget.item.id}_${entry.key}'),
                controller: entry.value,
                focusNode: entry.key == 'lot' ? lotFocus : null,
                enabled: widget.enabled && widget.item.catalogRequest == null,
                keyboardType: ['ordered', 'received'].contains(entry.key)
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: labels[entry.key],
                  helperText: entry.key == 'received'
                      ? widget.item.checked
                            ? 'Физически потвърдено количество.'
                            : 'Предложена стойност; още не е физически потвърдена.'
                      : null,
                  helperMaxLines: 2,
                  suffixIcon: widget.item.uncertainFields.contains(entry.key)
                      ? const Icon(Icons.help_outline)
                      : null,
                ),
                onChanged: (value) {
                  widget.item.edit(entry.key, value);
                  error = null;
                  widget.onChanged();
                },
              ),
            ),
          Text(
            widget.productLabel,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (widget.productDetail.isNotEmpty) Text(widget.productDetail),
          if (widget.onAddCatalog != null)
            FilledButton.tonalIcon(
              onPressed: widget.enabled ? widget.onAddCatalog : null,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Добави в каталога'),
            ),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Проверено'),
                  value: widget.item.checked,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: widget.enabled
                      ? (value) {
                          final errors = widget.item.validationErrors;
                          if (value == true && errors.isNotEmpty) {
                            setState(() => error = errors.join('\n'));
                            return;
                          }
                          widget.item.checked = value == true;
                          error = null;
                          widget.onChanged();
                        }
                      : null,
                ),
              ),
              TextButton(
                onPressed: widget.enabled ? widget.onDetails : null,
                child: Text(
                  widget.onAddCatalog != null ? 'Детайли' : widget.detailsLabel,
                ),
              ),
            ],
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

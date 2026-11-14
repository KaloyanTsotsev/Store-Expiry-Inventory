import 'package:flutter/material.dart';

import '../models/delivery_draft.dart';
import 'expiry_date_field.dart';
import 'quantity_correction_dialog.dart';

class BulkReviewRow extends StatefulWidget {
  final DraftItem item;
  final bool enabled;
  final String productLabel;
  final String productDetail, detailsLabel;
  final VoidCallback? onAddCatalog;
  final bool selected;
  final bool automaticValidation;
  final ValueChanged<bool>? onSelected;
  final List<String> reviewErrors;
  final VoidCallback onChanged, onDetails;
  const BulkReviewRow({
    super.key,
    required this.item,
    required this.enabled,
    required this.productLabel,
    this.productDetail = '',
    this.detailsLabel = 'Детайли',
    this.onAddCatalog,
    this.selected = false,
    this.automaticValidation = false,
    this.onSelected,
    this.reviewErrors = const [],
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
  bool get direct => widget.item.articleBarcode;
  bool get known => direct && widget.item.productId != null;
  bool get editable =>
      widget.enabled && (direct || widget.item.catalogRequest == null);
  late final lotFocus = FocusNode()..addListener(_finishLot);

  void _finishLot() {
    if (!lotFocus.hasFocus) fields['lot']!.text = widget.item.lot;
  }

  Future<void> _correctQuantity() async {
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          QuantityCorrectionDialog(initialValue: fields['received']!.text),
    );
    if (!mounted || !editable || value == null) return;
    fields['received']!.text = value;
    widget.item.edit('received', value);
    error = null;
    widget.onChanged();
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
          if (widget.automaticValidation && direct)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Артикулът е получен'),
              subtitle: Text(
                widget.item.received == '0'
                    ? 'Няма да се създават продукт, партида или движение.'
                    : 'Проверете действително полученото количество.',
              ),
              value: parseQuantity(widget.item.received) != 0,
              onChanged: editable
                  ? (received) {
                      widget.item.edit('received', received ? '' : '0');
                      widget.onChanged();
                    }
                  : null,
            ),
          if (known) ...[
            Text(
              widget.item.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('Артикул: ${widget.item.supplierCode}'),
            const SizedBox(height: 12),
          ],
          for (final entry in fields.entries.where(
            (e) =>
                !direct ||
                (e.key != 'ordered' &&
                    (!known || !['name', 'supplierCode'].contains(e.key))),
          ))
            if (entry.key == 'expiry')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ExpiryDateField(
                  key: ValueKey('${widget.item.id}_expiry'),
                  controller: entry.value,
                  enabled: editable,
                  label: 'Годност',
                  onChanged: (value) {
                    widget.item.edit('expiry', value);
                    error = null;
                    widget.onChanged();
                  },
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: ValueKey('${widget.item.id}_${entry.key}'),
                  controller: entry.value,
                  focusNode: entry.key == 'lot' ? lotFocus : null,
                  enabled: editable,
                  onTap: widget.automaticValidation && entry.key == 'received'
                      ? _correctQuantity
                      : null,
                  readOnly:
                      widget.automaticValidation && entry.key == 'received' ||
                      widget.item.articleBarcode &&
                          widget.item.productId != null &&
                          (entry.key == 'name' || entry.key == 'ordered'),
                  keyboardType: ['ordered', 'received'].contains(entry.key)
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: direct && entry.key == 'received'
                        ? 'Количество'
                        : labels[entry.key],
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
                    if (widget.automaticValidation && entry.key == 'received') {
                      return;
                    }
                    widget.item.edit(entry.key, value);
                    error = null;
                    widget.onChanged();
                  },
                ),
              ),
          Text(
            widget.automaticValidation &&
                    parseQuantity(widget.item.received) == 0
                ? 'Неполучен артикул — ще бъде пропуснат'
                : widget.productLabel,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (widget.productDetail.isNotEmpty) Text(widget.productDetail),
          if (widget.onAddCatalog != null)
            FilledButton.tonalIcon(
              onPressed: widget.enabled ? widget.onAddCatalog : null,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Добави в каталога'),
            ),
          if (widget.automaticValidation) ...[
            Text(
              widget.item.ready ? 'Готово' : 'За корекция',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (!widget.item.ready)
              Text(
                widget.item.validationErrors.join('\n'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            TextButton(
              onPressed: widget.enabled ? widget.onDetails : null,
              child: Text(widget.detailsLabel),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      widget.onSelected == null
                          ? 'Проверено'
                          : 'Избери позицията',
                    ),
                    subtitle: widget.onSelected == null
                        ? null
                        : Text(
                            widget.item.checked ? 'Проверено' : 'За проверка',
                          ),
                    value: widget.onSelected == null
                        ? widget.item.checked
                        : widget.selected,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: widget.enabled
                        ? (value) {
                            if (widget.onSelected case final select?) {
                              select(value == true);
                              return;
                            }
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
                    widget.onAddCatalog != null
                        ? 'Детайли'
                        : widget.detailsLabel,
                  ),
                ),
              ],
            ),
          if (widget.reviewErrors.isNotEmpty)
            Text(
              widget.reviewErrors.join('\n'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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

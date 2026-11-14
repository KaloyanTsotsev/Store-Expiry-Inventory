import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import '../services/product_catalog_service.dart';
import '../services/product_matcher.dart';
import '../theme/app_spacing.dart';

class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({
    super.key,
    this.product,
    this.products = const [],
    this.catalog,
    this.catalogAccess,
  });
  final RecordModel? product;
  final List<RecordModel> products;
  final ProductCatalogService? catalog;
  final CatalogAccess? catalogAccess;
  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController(),
      barcodeController = TextEditingController(),
      categoryController = TextEditingController();
  late final catalog = widget.catalog ?? ProductCatalogService();
  bool isSaving = false, isDeleting = false;
  String? errorMessage, suggestionId;
  Map<String, dynamic>? pendingRequest, pendingDelete;
  List<RecordModel> corrections = [];
  List<RecordModel> history = [];
  bool get _canManage => widget.catalogAccess?.canCreate ?? catalog.canManage;
  bool get _canDelete =>
      _canManage &&
      widget.product != null &&
      widget.catalogAccess?.canDeleteProduct == true;
  bool get locked =>
      isSaving || isDeleting || pendingRequest != null || pendingDelete != null;
  @override
  void initState() {
    super.initState();
    _fill(widget.product?.data ?? {});
    _loadCorrections();
  }

  void _fill(Map<String, dynamic> data) {
    nameController.text = data['name']?.toString() ?? '';
    barcodeController.text = data['barcode']?.toString() ?? '';
    categoryController.text = data['category']?.toString() ?? '';
  }

  Future<void> _loadCorrections() async {
    if (widget.product == null) return;
    try {
      final values = await catalog.corrections(widget.product!.id);
      if (mounted) setState(() => corrections = values);
      if (_canManage) {
        final changes = await catalog.history(widget.product!.id);
        if (mounted) setState(() => history = changes);
      }
    } catch (_) {
      /* Catalog V3 may not be deployed; legacy catalog remains readable. */
    }
  }

  String _describe(Map<String, dynamic> values) => [
    if (values.containsKey('name')) 'Име: ${values['name']}',
    if (values.containsKey('barcode')) 'Код: ${values['barcode']}',
    if (values.containsKey('category')) 'Категория: ${values['category']}',
  ].join('\n');
  String _historyLabel(RecordModel change) {
    final actor = change.get<List<RecordModel>>('expand.actor', []).firstOrNull;
    final name =
        actor?.data['name'] ?? actor?.data['username'] ?? change.data['actor'];
    final date = DateTime.tryParse(change.data['created']?.toString() ?? '')
        ?.toLocal();
    final when = date == null
        ? ''
        : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return '$when • Служител $name';
  }

  Future<void> saveProduct() async {
    if (isSaving || isDeleting || pendingDelete != null) return;
    if (widget.catalogAccess != null && !widget.catalogAccess!.available) {
      setState(() => errorMessage = widget.catalogAccess!.message);
      return;
    }
    if (pendingRequest == null) {
      if (!formKey.currentState!.validate()) return;
      if (!_canManage && widget.product == null) {
        setState(
          () => errorMessage = 'Само управител или администратор добавя продукт в каталога. Нов продукт при доставка се подготвя в черновата.',
        );
        return;
      }
      final duplicate = widget.products.where(
        (p) =>
            p.id != widget.product?.id &&
            (ProductMatcher.nameKey(p.data['name']?.toString() ?? '') ==
                    ProductMatcher.nameKey(nameController.text) ||
                (barcodeController.text.trim().isNotEmpty &&
                    p.getStringValue('barcode').trim() ==
                        barcodeController.text.trim())),
      );
      if (duplicate.isNotEmpty) {
        setState(
          () => errorMessage =
              'Възможен дубликат: ${duplicate.map((p) => p.data['name']).join(', ')}. Изберете съществуващия продукт.',
        );
        return;
      }
      pendingRequest = {
        'operation_key': 'catalog:${newDraftId()}',
        'form_version': 2,
        'product_id': widget.product?.id ?? '',
        'expected_revision': widget.product?.data['catalog_revision'] ?? 0,
        if (suggestionId != null) 'suggestion_id': suggestionId,
        'fields': {
          'name': nameController.text.trim(),
          'barcode': barcodeController.text.trim(),
          'category': categoryController.text.trim(),
        },
      };
    }
    setState(() {
      isSaving = true;
      errorMessage = null;
    });
    try {
      final response = await catalog.submit(
        pendingRequest!,
        proposal: !_canManage,
      );
      if (response['status'] != (_canManage ? 'saved' : 'pending')) {
        throw const FormatException('Липсва потвърден отговор за записа.');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _canManage ? 'Продуктът е записан.' : 'Предложението е изпратено за одобрение. Каталогът остава непроменен.',
          ),
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (e is ClientException &&
          [400, 401, 403, 404, 409, 501, 503].contains(e.statusCode)) {
        pendingRequest = null;
      }
      if (mounted) {
        setState(() => errorMessage = ProductCatalogService.message(e));
      }
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  Future<void> _deleteProduct() async {
    if (!_canDelete || isSaving || isDeleting || pendingRequest != null) return;
    final product = widget.product!;
    if (pendingDelete == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Изтрий продукт?'),
          content: Text(
            '${product.getStringValue('name')}\n\nПродуктът ще бъде изтрит само ако няма свързани записи или история.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отказ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Изтрий'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || isDeleting) return;
      pendingDelete = {
        'operation_key': 'catalog:delete:${newDraftId()}',
        'product_id': product.id,
        'expected_revision': product.data['catalog_revision'] ?? 0,
      };
    }
    setState(() {
      isDeleting = true;
      errorMessage = null;
    });
    try {
      final receipt = await catalog.deleteProduct(pendingDelete!);
      if (receipt['status'] != 'deleted' ||
          receipt['product_id'] != product.id) {
        throw const FormatException(
          'Няма потвърждение за изтриването. Повторете същата заявка.',
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Продуктът е изтрит.')));
      Navigator.pop(context, true);
    } catch (e) {
      if (e is ClientException &&
          [400, 401, 403, 404, 409, 501, 503].contains(e.statusCode) &&
          e.response['code'] != 'catalog_transaction_not_confirmed') {
        pendingDelete = null;
      }
      if (mounted) {
        setState(() => errorMessage = ProductCatalogService.message(e));
      }
    } finally {
      if (mounted) setState(() => isDeleting = false);
    }
  }

  @override
  void dispose() {
    for (final c in [nameController, barcodeController, categoryController]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = _canManage;
    return PopScope(
      canPop: !isSaving && !isDeleting,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.product == null
                ? 'Нов продукт'
                : manager
                ? 'Редактиране на продукт'
                : 'Предложи корекция',
          ),
        ),
        body: Form(
          key: formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: nameController,
                  enabled: !locked,
                  maxLines: null,
                  decoration: const InputDecoration(
                    labelText: 'Име на продукт',
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                  ),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Въведете име на продукта'
                      : null,
                ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: barcodeController,
                  enabled: !locked,
                  decoration: const InputDecoration(labelText: 'Код'),
                  validator: (v) {
                    final code = v?.trim() ?? '';
                    if (code.isEmpty ||
                        code ==
                            widget.product?.getStringValue('barcode').trim()) {
                      return null;
                    }
                    return validArticleCode(code)
                        ? null
                        : 'Въведете валиден артикулен код.';
                  },
                ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: categoryController,
                  enabled: !locked,
                  decoration: const InputDecoration(labelText: 'Категория'),
                ),
                if (corrections.isNotEmpty)
                  ExpansionTile(
                    title: Text(
                      'Предложения за корекция: ${corrections.length}',
                    ),
                    children: [
                      for (final c in corrections)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                _describe(
                                  Map<String, dynamic>.from(
                                    c.data['patch'] as Map,
                                  ),
                                ),
                              ),
                              if (manager)
                                TextButton(
                                  onPressed: locked
                                      ? null
                                      : () => setState(() {
                                          _fill(
                                            Map<String, dynamic>.from(
                                              c.data['patch'] as Map,
                                            ),
                                          );
                                          suggestionId = c.id;
                                        }),
                                  child: const Text(
                                    'Прегледай това предложение',
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (history.isNotEmpty)
                  ExpansionTile(
                    title: const Text('История на промените'),
                    children: [
                      for (final change in history)
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.medium),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _historyLabel(change),
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                'Преди:\n${_describe(Map<String, dynamic>.from(change.data['before'] as Map? ?? {}))}\n\nСлед:\n${_describe(Map<String, dynamic>.from(change.data['after'] as Map? ?? {}))}',
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: SelectableText(
                      errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (pendingRequest != null && !isSaving)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Резултатът е неизвестен. Полетата са заключени; повторението използва същата заявка.',
                    ),
                  ),
                if (widget.catalogAccess != null &&
                    !widget.catalogAccess!.available)
                  Text(widget.catalogAccess!.message),
                FilledButton.icon(
                  onPressed:
                      isSaving ||
                          isDeleting ||
                          pendingDelete != null ||
                          (widget.catalogAccess != null &&
                              !widget.catalogAccess!.available)
                      ? null
                      : saveProduct,
                  icon: isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    isSaving
                        ? 'Записване...'
                        : pendingRequest != null
                        ? 'Повтори същата заявка'
                        : manager
                        ? 'Запази продукта'
                        : 'Изпрати предложение',
                  ),
                ),
                if (_canDelete)
                  TextButton.icon(
                    onPressed: isSaving || isDeleting || pendingRequest != null
                        ? null
                        : _deleteProduct,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(
                      isDeleting
                          ? 'Проверка…'
                          : pendingDelete != null
                          ? 'Повтори заявката за изтриване'
                          : 'Изтрий продукт',
                    ),
                  ),
                const SizedBox(height: AppSpacing.section),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

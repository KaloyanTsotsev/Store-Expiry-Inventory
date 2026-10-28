import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import '../services/gtin.dart';
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
      categoryController = TextEditingController(),
      aliasController = TextEditingController(),
      codesController = TextEditingController();
  late final catalog = widget.catalog ?? ProductCatalogService();
  bool isSaving = false, active = true;
  String? errorMessage, suggestionId;
  Map<String, dynamic>? pendingRequest;
  List<RecordModel> corrections = [];
  List<RecordModel> history = [];
  bool get _canManage => widget.catalogAccess?.canCreate ?? catalog.canManage;
  bool get locked => isSaving || pendingRequest != null;
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
    aliasController.text = (data['aliases'] as List? ?? []).join('\n');
    codesController.text = (data['supplier_identifiers'] as List? ?? [])
        .whereType<Map>()
        .map((m) => '${m['supplier']} | ${m['code']}')
        .join('\n');
    active = data['active'] != false;
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

  List<Map<String, dynamic>> _codes() => [
    for (final line
        in codesController.text.split('\n').where((s) => s.trim().isNotEmpty))
      {
        'supplier': line.split('|').first.trim(),
        'code': line.contains('|')
            ? line.substring(line.indexOf('|') + 1).trim()
            : '',
      },
  ];
  String _describe(Map<String, dynamic> values) => [
    if (values.containsKey('name')) 'Име: ${values['name']}',
    if (values.containsKey('barcode')) 'Баркод: ${values['barcode']}',
    if (values.containsKey('category')) 'Категория: ${values['category']}',
    if (values.containsKey('active'))
      'Статус: ${values['active'] == true ? 'Активен' : 'Неактивен'}',
    if (values['aliases'] is List)
      'Алиаси: ${(values['aliases'] as List).join(', ')}',
    if (values['supplier_identifiers'] is List)
      'Кодове: ${(values['supplier_identifiers'] as List).whereType<Map>().map((m) => '${m['supplier']} → ${m['code']}').join(', ')}',
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
    if (isSaving) return;
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
                (gtinKey(barcodeController.text) != null &&
                    gtinKey(p.data['barcode']?.toString() ?? '') ==
                        gtinKey(barcodeController.text))),
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
        'product_id': widget.product?.id ?? '',
        'expected_revision': widget.product?.data['catalog_revision'] ?? 0,
        if (suggestionId != null) 'suggestion_id': suggestionId,
        'fields': {
          'name': nameController.text.trim(),
          'barcode': barcodeController.text.trim(),
          'category': categoryController.text.trim(),
          'active': active,
          'aliases': aliasController.text
              .split('\n')
              .map((a) => a.trim())
              .where((a) => a.isNotEmpty)
              .toSet()
              .toList(),
          'supplier_identifiers': _codes(),
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

  @override
  void dispose() {
    for (final c in [
      nameController,
      barcodeController,
      categoryController,
      aliasController,
      codesController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = _canManage;
    return PopScope(
      canPop: !isSaving,
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
                if (widget.product != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.large),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Продукт ${widget.product!.id}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            manager
                                ? 'Редакцията запазва същия ID и историята на доставките.'
                                : 'Корекцията е предложение. Управител проверява и одобрява промяната.',
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: nameController,
                  enabled: !locked,
                  maxLines: null,
                  decoration: const InputDecoration(
                    labelText: 'Име на продукта *',
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
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Баркод EAN/GTIN',
                    helperText: 'Незадължителен; само реален код с валидна контролна цифра.',
                    helperMaxLines: 3,
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isNotEmpty && gtinKey(v!) == null
                      ? 'Невалиден GTIN-8/12/13/14'
                      : null,
                ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: categoryController,
                  enabled: !locked,
                  decoration: const InputDecoration(labelText: 'Категория'),
                ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: aliasController,
                  enabled: !locked,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Алтернативни имена',
                    helperText: 'По един потвърден алиас на ред. Оригиналният OCR не се променя.',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: AppSpacing.large),
                TextFormField(
                  controller: codesController,
                  enabled: !locked,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Кодове по доставчик',
                    helperText: 'Всеки ред: Доставчик | Артикулен код. Водещите нули се запазват.',
                    helperMaxLines: 3,
                  ),
                  validator: (_) =>
                      _codes().any(
                        (m) => m['supplier'].isEmpty || m['code'].isEmpty,
                      )
                      ? 'Всеки код изисква доставчик и разделител |'
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Активен продукт'),
                  subtitle: const Text(
                    'Неактивните продукти остават в историята.',
                  ),
                  value: active,
                  onChanged: locked ? null : (v) => setState(() => active = v),
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
                const SizedBox(height: AppSpacing.section),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

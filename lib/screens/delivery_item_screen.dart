import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import '../services/ocr_service.dart';
import '../services/product_matcher.dart';
import '../services/product_catalog_service.dart';
import '../services/delivery_catalog_service.dart';
import '../widgets/document_photo.dart';

class DeliveryItemScreen extends StatefulWidget {
  final DraftItem item;
  final String imagePath;
  final String supplier;
  final List<RecordModel> products;
  final Future<List<RecordModel>> Function() onReloadCatalog;
  final Future<void> Function() onSave;
  final DeliveryCatalogService? identityService;
  final CatalogAccess? catalogAccess;
  const DeliveryItemScreen({
    super.key,
    required this.item,
    required this.imagePath,
    this.supplier = '',
    required this.products,
    required this.onReloadCatalog,
    required this.onSave,
    this.identityService,
    this.catalogAccess,
  });
  @override
  State<DeliveryItemScreen> createState() => _DeliveryItemScreenState();
}

class _DeliveryItemScreenState extends State<DeliveryItemScreen> {
  late final Map<String, TextEditingController> fields;
  late List<RecordModel> products;
  String? productId, error;
  bool saving = false;
  bool proposedNewProduct = false;
  bool selectionConfirmed = false, rememberMatch = true;
  static const labels = {
    'supplierCode': 'Код на доставчика (не EAN баркод)',
    'name': 'Име на продукта',
    'barcode': 'Историческа стойност (не продуктов GTIN)',
    'ordered': 'Заявено количество',
    'unit': 'Мерна единица от документа',
    'expiry': 'Срок на годност • ДД.ММ.ГГГГ',
    'lot': 'Номер на партида',
    'received': 'Физически прието количество',
  };
  @override
  void initState() {
    super.initState();
    final json = widget.item.toJson();
    fields = {
      for (final key in labels.keys)
        key: TextEditingController(text: json[key] as String),
    };
    productId = widget.item.productId;
    selectionConfirmed = widget.item.productSelectionConfirmed;
    proposedNewProduct = widget.item.proposedNewProduct;
    products = widget.products;
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseProduct() async {
    var query = '';
    final chosen = await showModalBottomSheet<RecordModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .85,
        child: StatefulBuilder(
          builder: (context, update) {
            final match = ProductMatcher.match(
              DraftItem(
                name: fields['name']!.text,
                barcode: fields['barcode']!.text,
                supplierCode: fields['supplierCode']!.text,
              ),
              products,
              widget.supplier,
            );
            final ranked = {
              ...{for (final p in match.products) p.id: p},
              ...{
                for (final p in products.where(ProductMatcher.active)) p.id: p,
              },
            }.values;
            final filtered = ranked
                .where(
                  (p) => '${p.data['name']} ${p.data['barcode']}'
                      .toLowerCase()
                      .contains(query),
                )
                .toList();
            final exact = products
                .where(
                  (p) =>
                      normalizedProductName(p.data['name']?.toString() ?? '') ==
                      normalizedProductName(fields['name']!.text),
                )
                .toList();
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    'Изберете продукт',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(match.reason),
                  if (exact.length > 1)
                    const Text(
                      'Има продукти с еднакво име. Сравнете баркода и идентификатора.',
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (value) =>
                        update(() => query = value.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      labelText: 'Търси име или баркод',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text(
                              'Няма съвпадения. Подгответе нов продукт в черновата, без да го създавате сега.',
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final product = filtered[index];
                              return ListTile(
                                title: Text(
                                  product.data['name']?.toString() ?? '',
                                ),
                                subtitle: Text(
                                  'Баркод: ${product.data['barcode'] ?? ''}\nID: ${product.id}',
                                ),
                                onTap: () => Navigator.pop(context, product),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        productId = chosen.id;
        fields['name']!.text =
            chosen.data['name']?.toString() ?? fields['name']!.text;
        selectionConfirmed = true;
        proposedNewProduct = false;
      });
    }
  }

  Future<void> _save(bool checked) async {
    if (saving) return;
    final candidate = DraftItem.fromJson({
      ...widget.item.toJson(),
      for (final entry in fields.entries) entry.key: entry.value.text.trim(),
      'productId': productId,
      'proposedNewProduct': proposedNewProduct,
    });
    if (candidate.requiresCatalogIdentity && candidate.catalogRequest == null) {
      ProductMatcher.prepare(candidate, products, widget.supplier);
    }
    if (checked &&
        candidate.requiresCatalogIdentity &&
        candidate.productId == null &&
        parseQuantity(candidate.received) != 0 &&
        widget.catalogAccess != null &&
        (!widget.catalogAccess!.available ||
            (!widget.catalogAccess!.canCreate &&
                !widget.catalogAccess!.canFinalizeDelivery))) {
      setState(() => error = widget.catalogAccess!.message);
      return;
    }
    if (checked &&
        candidate.requiresCatalogIdentity &&
        !candidate.catalogOnFinalize &&
        parseQuantity(candidate.received) != 0) {
      final physical = DraftItem.fromJson({
        ...candidate.toJson(),
        'requiresCatalogIdentity': false,
        'original': <String, String>{},
        'proposedNewProduct': true,
      });
      if (physical.validationErrors.isNotEmpty ||
          parseQuantity(candidate.ordered) == null) {
        setState(
          () => error = [
            ...physical.validationErrors,
            if (parseQuantity(candidate.ordered) == null)
              'Проверете заявеното количество.',
          ].join('\n'),
        );
        return;
      }
      setState(() {
        saving = true;
        error = null;
      });
      try {
        products = await widget.onReloadCatalog();
        final match = ProductMatcher.supplierIdentity(
          candidate,
          products,
          widget.supplier,
        );
        final service = widget.identityService ?? DeliveryCatalogService();
        if (!match.automatic &&
            !match.conflict &&
            service.catalog.canManage &&
            candidate.catalogRequest == null) {
          if (!mounted) return;
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Потвърди нов каталожен продукт'),
              content: Text(
                '${candidate.name}\nДоставчик: ${widget.supplier}\nКод: ${candidate.supplierCode}\n\nСъздава продукт и връзка към кода. Количества се записват само при приключване на доставката.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отказ'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Потвърди създаването'),
                ),
              ],
            ),
          );
          if (approved != true) {
            if (mounted) setState(() => saving = false);
            return;
          }
        }
        final record = await service.confirm(
          item: candidate,
          supplier: widget.supplier,
          products: products,
          physicallyConfirmed: true,
          persist: () async {
            _copy(candidate);
            widget.item.checked = false;
            await widget.onSave();
          },
        );
        products = [...products.where((p) => p.id != record.id), record];
        productId = record.id;
        proposedNewProduct = false;
        selectionConfirmed = true;
        fields['name']!.text = candidate.name;
      } catch (e) {
        if (mounted) {
          setState(() {
            saving = false;
            error = ProductCatalogService.message(e);
          });
        }
        return;
      }
    }
    if (checked && candidate.validationErrors.isNotEmpty) {
      setState(() {
        saving = false;
        error = candidate.validationErrors.join('\n');
      });
      return;
    }
    if (checked &&
        parseQuantity(candidate.received) != 0 &&
        !candidate.proposedNewProduct &&
        !products.any((p) => p.id == productId && ProductMatcher.active(p))) {
      setState(
        () => error = 'Продуктът не е в заредения каталог. Обновете и го изберете отново.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final item = widget.item;
    item.supplierCode = candidate.supplierCode;
    item.name = candidate.name;
    item.ordered = candidate.ordered;
    item.unit = candidate.unit;
    item.barcode = candidate.barcode;
    item.expiry = candidate.expiry;
    item.lot = candidate.lot;
    item.difference = candidate.difference;
    item.received = candidate.received;
    item.productId = candidate.productId;
    item.proposedNewProduct = candidate.proposedNewProduct;
    item.catalogOnFinalize = candidate.catalogOnFinalize;
    item.requiresCatalogIdentity = candidate.requiresCatalogIdentity;
    item.catalogRequest = candidate.catalogRequest;
    item.productSelectionConfirmed =
        checked && item.productId != null || selectionConfirmed;
    if (item.productSelectionConfirmed) {
      item.matchReason = 'Ръчно потвърден продукт от каталога';
    }
    item.checked = checked;
    try {
      await widget.onSave();
      final selected = products.where((p) => p.id == productId).firstOrNull;
      final alias = item.original['name'] ?? item.name;
      if (checked &&
          !item.requiresCatalogIdentity &&
          rememberMatch &&
          selected != null &&
          (ProductMatcher.nameKey(alias) !=
                  ProductMatcher.nameKey(
                    selected.data['name']?.toString() ?? '',
                  ) ||
              widget.supplier.isNotEmpty && item.supplierCode.isNotEmpty)) {
        try {
          final response = await ProductCatalogService()
              .confirmMatch(
                product: selected,
                alias: alias,
                supplier: widget.supplier,
                code: widget.supplier.isEmpty ? '' : item.supplierCode,
              )
              .timeout(const Duration(seconds: 8));
          if (mounted && response['status'] == 'pending') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Предложението за съвпадение чака одобрение от управител.',
                ),
              ),
            );
          }
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Проверката е запазена. Съвпадението не е потвърдено в каталога V3.',
                ),
              ),
            );
          }
        }
      }
      if (!mounted) return;
      setState(() => saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (e) {
      item.checked = false;
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _copy(DraftItem candidate) {
    final item = widget.item;
    item.name = candidate.name;
    item.supplierCode = candidate.supplierCode;
    item.ordered = candidate.ordered;
    item.received = candidate.received;
    item.expiry = candidate.expiry;
    item.lot = candidate.lot;
    item.barcode = candidate.barcode;
    item.unit = candidate.unit;
    item.productId = candidate.productId;
    item.proposedNewProduct = candidate.proposedNewProduct;
    item.productSelectionConfirmed = candidate.productSelectionConfirmed;
    item.catalogOnFinalize = candidate.catalogOnFinalize;
    item.requiresCatalogIdentity = candidate.requiresCatalogIdentity;
    item.catalogRequest = candidate.catalogRequest;
  }

  @override
  Widget build(BuildContext context) {
    final selected = products.where((p) => p.id == productId).firstOrNull;
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Проверка на позиция'),
          actions: [
            if (widget.imagePath.isNotEmpty)
              IconButton(
                tooltip: 'Виж документа',
                onPressed: () => showDocumentPhoto(context, widget.imagePath),
                icon: const Icon(Icons.image_outlined),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Сравнете с документа и стоката. Полученото количество е предварително попълнено и изисква физическа проверка.',
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                title: Text(
                  selected?.data['name']?.toString() ??
                      (proposedNewProduct
                          ? 'Нов продукт • ${fields['name']!.text}'
                          : widget.item.requiresCatalogIdentity
                          ? 'Уточнете доставчика и кода на тази позиция'
                          : 'Изберете продукт от каталога'),
                ),
                subtitle: Text(
                  selected == null
                      ? 'Няма автоматично съпоставяне по код на доставчик.'
                      : 'ID: ${selected.id} • Баркод: ${selected.data['barcode'] ?? ''}',
                ),
                trailing: Icon(
                  widget.item.requiresCatalogIdentity
                      ? Icons.inventory_2_outlined
                      : Icons.search,
                ),
                onTap: saving || widget.item.requiresCatalogIdentity
                    ? null
                    : _chooseProduct,
              ),
            ),
            if (widget.item.matchReason.isNotEmpty || selectionConfirmed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  selectionConfirmed
                      ? 'Ръчно избран продукт'
                      : widget.item.matchReason,
                ),
              ),
            if (productId != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Запомни това съвпадение'),
                subtitle: const Text(
                  'Алиасът и кодът са по доставчик. За служители се изпраща предложение за одобрение.',
                ),
                value: rememberMatch,
                onChanged: saving
                    ? null
                    : (v) => setState(() => rememberMatch = v == true),
              ),
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final updated = await widget.onReloadCatalog();
                      if (mounted) {
                        setState(() {
                          products = updated;
                          final candidate = DraftItem.fromJson({
                            ...widget.item.toJson(),
                            for (final e in fields.entries) e.key: e.value.text,
                          });
                          ProductMatcher.prepare(
                            candidate,
                            products,
                            widget.supplier,
                          );
                          productId = candidate.productId;
                          proposedNewProduct = candidate.proposedNewProduct;
                          if (productId != null) {
                            fields['name']!.text = candidate.name;
                          }
                        });
                      }
                    },
              icon: const Icon(Icons.refresh),
              label: const Text('Обнови каталога'),
            ),
            if (widget.catalogAccess != null &&
                !widget.catalogAccess!.available)
              Text(widget.catalogAccess!.message),
            if (widget.item.requiresCatalogIdentity &&
                proposedNewProduct &&
                widget.item.catalogOnFinalize)
              const Text(
                'Нов продукт — ще бъде създаден при общото потвърждение на доставката. Тук не се записват продукти или наличности.',
              ),
            if (widget.item.requiresCatalogIdentity &&
                proposedNewProduct &&
                !widget.item.catalogOnFinalize)
              Text(
                (widget.identityService?.catalog ?? ProductCatalogService())
                        .canManage
                    ? 'Нов продукт. След физическата проверка потвърдете създаването в каталога. Това не добавя количества.'
                    : 'Нов продукт — чака управител. Управителят го създава в „Продукти“ с този доставчик и код. После обновете каталога.',
              ),
            if (productId == null && !widget.item.requiresCatalogIdentity)
              CheckboxListTile(
                title: const Text('Подготви нов продукт с това име'),
                subtitle: const Text(
                  'Без категория. Ще се създаде само при потвърдено сървърно финализиране.',
                ),
                value: proposedNewProduct,
                onChanged: saving
                    ? null
                    : (value) =>
                          setState(() => proposedNewProduct = value == true),
              ),
            for (final entry in fields.entries.where((e) => e.key != 'barcode'))
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextField(
                  controller: entry.value,
                  onChanged: (_) {
                    if (entry.key == 'lot' || entry.key == 'received') {
                      setState(() {});
                    }
                    if (widget.item.requiresCatalogIdentity &&
                        [
                          'name',
                          'supplierCode',
                          'barcode',
                        ].contains(entry.key)) {
                      final candidate = DraftItem.fromJson({
                        ...widget.item.toJson(),
                        for (final e in fields.entries) e.key: e.value.text,
                      });
                      ProductMatcher.prepare(
                        candidate,
                        products,
                        widget.supplier,
                      );
                      setState(() {
                        productId = candidate.productId;
                        proposedNewProduct = candidate.proposedNewProduct;
                      });
                      return;
                    }
                    if ((entry.key == 'name' ||
                            entry.key == 'supplierCode' ||
                            entry.key == 'barcode') &&
                        !selectionConfirmed) {
                      setState(() {
                        productId = null;
                        proposedNewProduct = false;
                      });
                    }
                  },
                  enabled: !saving && widget.item.catalogRequest == null,
                  keyboardType: ['received', 'ordered'].contains(entry.key)
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: labels[entry.key],
                    helperText: entry.key == 'received'
                        ? 'Въведете преброеното; 0 означава неполучена позиция.'
                        : entry.key == 'lot'
                        ? 'Незадължително; празно или 1 се записва като N/A.'
                        : widget.item.uncertainFields.contains(entry.key)
                        ? 'Несигурен OCR резултат — проверете полето.'
                        : widget.item.original.containsKey(entry.key) &&
                              entry.value.text ==
                                  widget.item.original[entry.key]
                        ? 'Автоматично разпознато — проверете с документа.'
                        : 'Ръчно въведена или коригирана стойност.',
                    helperMaxLines: 3,
                    suffixIcon:
                        widget.item.uncertainFields.contains(entry.key) &&
                            (entry.key != 'lot' ||
                                normalizeLotNumber(entry.value.text) != 'N/A')
                        ? const Icon(Icons.help_outline)
                        : null,
                  ),
                ),
              ),
            if (widget.item.original.isNotEmpty)
              ExpansionTile(
                title: const Text('Първоначален OCR резултат'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      widget.item.original.entries
                          .map((e) => '${labels[e.key] ?? e.key}: ${e.value}')
                          .join('\n'),
                    ),
                  ),
                ],
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton.icon(
              onPressed:
                  saving ||
                      (widget.catalogAccess != null &&
                          (!widget.catalogAccess!.available ||
                              (!widget.catalogAccess!.canCreate &&
                                  !widget
                                      .catalogAccess!
                                      .canFinalizeDelivery)) &&
                          widget.item.requiresCatalogIdentity &&
                          productId == null &&
                          parseQuantity(fields['received']!.text) != 0)
                  ? null
                  : () => _save(true),
              icon: saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              label: const Text('Потвърди физическата проверка'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: saving ? null : () => _save(false),
              child: const Text('Запази за по-късно'),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final split = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Две различни партиди'),
                          content: const Text(
                            'Ще се добави отделна позиция. Въведете преброеното количество и срока за всяка партида отново.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Отказ'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Раздели'),
                            ),
                          ],
                        ),
                      );
                      if (split == true && context.mounted) {
                        Navigator.pop(context, 'split');
                      }
                    },
              icon: const Icon(Icons.call_split),
              label: const Text('Раздели на отделни партиди'),
            ),
            TextButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Премахни позицията?'),
                          content: const Text(
                            'Използвайте за погрешно разпознат ред. Снимката остава в черновата.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Отказ'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Премахни'),
                            ),
                          ],
                        ),
                      );
                      if (remove == true && context.mounted) {
                        Navigator.pop(context, 'delete');
                      }
                    },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Премахни погрешен ред'),
            ),
          ],
        ),
      ),
    );
  }
}

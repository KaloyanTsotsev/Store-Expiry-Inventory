import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import 'gtin.dart';
import 'ocr_service.dart';

class ProductMatch {
  final List<RecordModel> products;
  final String reason;
  final bool automatic, conflict;
  const ProductMatch(
    this.products,
    this.reason, {
    this.automatic = false,
    this.conflict = false,
  });
}

class ProductMatcher {
  static bool validSupplierCode(String code) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/\-]{0,127}$').hasMatch(code.trim());

  static ProductMatch supplierIdentity(
    DraftItem item,
    List<RecordModel> products,
    String supplier,
  ) {
    if (supplier.trim().isEmpty || !validSupplierCode(item.supplierCode)) {
      return const ProductMatch(
        [],
        'Уточнете доставчика и артикулния код.',
        conflict: true,
      );
    }
    final matches = products
        .where(
          (p) => (p.data['supplier_identifiers'] as List? ?? [])
              .whereType<Map>()
              .any(
                (m) =>
                    normalizedProductName(m['supplier']?.toString() ?? '') ==
                        normalizedProductName(supplier) &&
                    m['code'] == item.supplierCode.trim(),
              ),
        )
        .toList();
    if (matches.isEmpty) {
      return const ProductMatch(
        [],
        'Нов продукт — потвърдете името и кода преди създаване.',
      );
    }
    final verified =
        matches.length == 1 &&
        active(matches.single) &&
        (matches.single.data['supplier_identifiers'] as List)
            .whereType<Map>()
            .any(
              (m) =>
                  normalizedProductName(m['supplier']?.toString() ?? '') ==
                      normalizedProductName(supplier) &&
                  m['code'] == item.supplierCode.trim() &&
                  m['verified'] == true,
            );
    return ProductMatch(
      matches,
      verified ? 'Потвърден доставчик + артикулен код' : 'Конфликтен, непотвърден или неактивен код — нужна е проверка в каталога.',
      automatic: verified,
      conflict: !verified,
    );
  }

  static String nameKey(String value) =>
      normalizedProductName(value)
          .replaceAll(RegExp(r'[^a-zа-яѝё0-9]+', caseSensitive: false), ' ')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
  static List<String> aliases(RecordModel p) =>
      (p.data['aliases'] as List? ?? []).whereType<String>().toList();
  static bool active(RecordModel p) => p.data['active'] != false;

  static ProductMatch match(
    DraftItem item,
    List<RecordModel> products,
    String supplier,
  ) {
    if (item.requiresCatalogIdentity) {
      return supplierIdentity(item, products, supplier);
    }
    final catalog = products.where(active).toList();
    final barcode = gtinKey(item.barcode);
    final byBarcode = barcode == null
        ? <RecordModel>[]
        : products
              .where(
                (p) => gtinKey(p.data['barcode']?.toString() ?? '') == barcode,
              )
              .toList();
    final byCode = products.where((p) {
      final mappings = p.data['supplier_identifiers'];
      return supplier.trim().isNotEmpty &&
          item.supplierCode.trim().isNotEmpty &&
          mappings is List &&
          mappings.whereType<Map>().any(
            (m) =>
                m['verified'] == true &&
                normalizedProductName(m['supplier']?.toString() ?? '') ==
                    normalizedProductName(supplier) &&
                m['code'] == item.supplierCode.trim(),
          );
    }).toList();
    final ids = {...byBarcode.map((p) => p.id), ...byCode.map((p) => p.id)};
    if (byBarcode.length > 1 || byCode.length > 1 || ids.length > 1) {
      return ProductMatch(
        catalog.where((p) => ids.contains(p.id)).toList(),
        'Конфликтни идентификатори — изберете след проверка.',
        conflict: true,
      );
    }
    if (item.barcode.trim().isNotEmpty && barcode == null) {
      return const ProductMatch(
        [],
        'Невалиден EAN/GTIN — проверете цифрите.',
        conflict: true,
      );
    }
    if ([...byBarcode, ...byCode].any((p) => !active(p))) {
      return ProductMatch(
        [...byBarcode, ...byCode],
        'Идентификаторът сочи неактивен продукт — нужна е проверка.',
        conflict: true,
      );
    }
    if (barcode != null &&
        byCode.any(
          (p) =>
              gtinKey(p.data['barcode']?.toString() ?? '') != null &&
              gtinKey(p.data['barcode']?.toString() ?? '') != barcode,
        )) {
      return ProductMatch(
        byCode,
        'Баркодът и кодът на доставчика си противоречат.',
        conflict: true,
      );
    }
    if (byBarcode.length == 1) {
      return ProductMatch(
        byBarcode,
        'Съвпадение по проверен EAN/GTIN',
        automatic: true,
      );
    }
    if (byCode.length == 1) {
      return ProductMatch(
        byCode,
        'Потвърден доставчик + артикулен код',
        automatic: true,
      );
    }
    final key = nameKey(item.name);
    if (key.isEmpty) {
      return const ProductMatch([], 'Въведете име или изберете продукт.');
    }
    final exact = catalog
        .where(
          (p) => [
            p.data['name']?.toString() ?? '',
            ...aliases(p),
          ].any((name) => nameKey(name) == key),
        )
        .toList();
    if (barcode != null &&
        exact.any(
          (p) =>
              gtinKey(p.data['barcode']?.toString() ?? '') != null &&
              gtinKey(p.data['barcode']?.toString() ?? '') != barcode,
        )) {
      return ProductMatch(
        exact,
        'Името съвпада, но баркодът е различен — проверете продукта.',
        conflict: true,
      );
    }
    if (exact.isNotEmpty) {
      return ProductMatch(
        exact,
        exact.length > 1
            ? 'Нееднозначно име или алиас — проверете продукта.'
            : item.supplierCode.trim().isNotEmpty
            ? 'Името съвпада, но кодът не е потвърден за доставчика — изберете ръчно.'
            : 'Съвпадение по име или потвърден алиас',
        automatic:
            exact.length == 1 &&
            item.supplierCode.trim().isEmpty &&
            !item.uncertainFields.contains('name'),
        conflict: exact.length > 1,
      );
    }
    final scored = [
      for (final p in catalog)
        (
          product: p,
          score: [p.data['name']?.toString() ?? '', ...aliases(p)]
              .map((n) => _similarity(item.name, n))
              .reduce((a, b) => a > b ? a : b),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final fuzzy = scored
        .where((p) => p.score >= .55)
        .take(5)
        .map((p) => p.product)
        .toList();
    return ProductMatch(
      fuzzy,
      fuzzy.isEmpty
          ? 'Няма съвпадение в каталога.'
          : 'Приблизително съвпадение — нужно е ръчно избиране.',
    );
  }

  static double _similarity(String a, String b) {
    String expanded(String input) {
      const short = {
        'кис': 'кисело',
        'мл': 'мляко',
        'кр': 'краве',
        'пр': 'прясно',
        'гр': 'г',
      };
      return nameKey(input).split(' ').map((t) => short[t] ?? t).join(' ');
    }

    final left = expanded(a), right = expanded(b);
    if (left.isEmpty || right.isEmpty) return 0;
    var previous = List.generate(right.length + 1, (i) => i);
    for (var i = 0; i < left.length; i++) {
      final current = [i + 1];
      for (var j = 0; j < right.length; j++) {
        final values = [
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + (left[i] == right[j] ? 0 : 1),
        ];
        current.add(values.reduce((a, b) => a < b ? a : b));
      }
      previous = current;
    }
    return 1 -
        previous.last /
            (left.length > right.length ? left.length : right.length);
  }

  static List<RecordModel> candidates(
    DraftItem item,
    List<RecordModel> products,
    String supplier,
  ) => match(item, products, supplier).products;
  static void prepare(
    DraftItem item,
    List<RecordModel> products,
    String supplier,
  ) {
    if (item.requiresCatalogIdentity) {
      final result = supplierIdentity(item, products, supplier);
      final id = result.automatic ? result.products.single.id : null;
      if (item.productId != id) item.checked = false;
      item.productId = id;
      item.productSelectionConfirmed = result.automatic;
      item.proposedNewProduct =
          !result.conflict && !result.automatic && item.name.trim().isNotEmpty;
      item.matchReason = result.reason;
      if (result.automatic) {
        item.name =
            result.products.single.data['name']?.toString() ?? item.name;
      }
      if (result.automatic && item.catalogRequest != null) {
        final identifiers =
            (item.catalogRequest!['fields'] as Map?)?['supplier_identifiers']
                as List? ??
            [];
        if (identifiers.whereType<Map>().any(
          (m) =>
              normalizedProductName(m['supplier']?.toString() ?? '') ==
                  normalizedProductName(supplier) &&
              m['code'] == item.supplierCode.trim(),
        )) {
          item.catalogRequest = null;
        }
      }
      return;
    }
    if (item.checked &&
        item.productId != null &&
        products.any((p) => p.id == item.productId && active(p))) {
      item.productSelectionConfirmed = true;
    }
    if (item.productId != null &&
        products.any((p) => p.id == item.productId && active(p)) &&
        (item.productSelectionConfirmed || item.matchReason.isEmpty)) {
      return;
    }
    final result = match(item, products, supplier);
    if (item.productId != null) item.checked = false;
    item.productId = null;
    item.matchReason = result.reason;
    item.productSelectionConfirmed = false;
    if (result.automatic) {
      item.checked = false;
      item.productId = result.products.single.id;
      item.name = result.products.single.data['name']?.toString() ?? item.name;
      item.proposedNewProduct = false;
    }
    // Only an explicit employee action may propose a new product. OCR alone
    // must never turn an unmatched or corrupted name into creation intent.
  }
}

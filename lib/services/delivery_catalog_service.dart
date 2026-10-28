import 'dart:convert';

import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import 'product_catalog_service.dart';
import 'product_matcher.dart';

/// Catalog identity only. This service never writes deliveries or stock.
class DeliveryCatalogService {
  final ProductCatalogService catalog;
  DeliveryCatalogService({ProductCatalogService? catalog})
    : catalog = catalog ?? ProductCatalogService();

  Future<RecordModel> confirm({
    required DraftItem item,
    required String supplier,
    required List<RecordModel> products,
    required bool physicallyConfirmed,
    required Future<void> Function() persist,
    bool catalogOnly = false,
  }) async {
    if (!physicallyConfirmed ||
        item.name.trim().isEmpty ||
        (!catalogOnly &&
            (parseQuantity(item.ordered) == null ||
                parseQuantity(item.received) == null ||
                (parseQuantity(item.received)! > 0 &&
                    parseDocumentDate(item.expiry) == null)))) {
      throw StateError(
        'Потвърдете продукта, полученото количество и срока преди запис в каталога.',
      );
    }
    if (item.catalogRequest == null) {
      final match = ProductMatcher.supplierIdentity(item, products, supplier);
      if (match.conflict) throw StateError(match.reason);
      if (match.automatic) {
        final product = match.products.single;
        _assign(item, product);
        return product;
      }
      if (!catalog.canManage) {
        throw StateError(
          'Нов продукт — чака управител. Управителят създава продукта с този доставчик и код в „Продукти“. След това обновете каталога; редът ще се свърже автоматично.',
        );
      }
      if (!await catalog.available()) {
        throw StateError(
          'Създаването изисква одобрен каталог V3. Черновата е запазена.',
        );
      }
      item.catalogRequest = {
        'operation_key': 'delivery-catalog:${newDraftId()}',
        'product_id': '',
        'expected_revision': 0,
        'fields': {
          'name': item.name.trim(),
          // Delivery evidence cannot establish a product GTIN.
          'barcode': '',
          'category': '',
          'active': true,
          'aliases': <String>[],
          'supplier_identifiers': [
            {
              'supplier': supplier.trim(),
              'code': item.supplierCode.trim(),
              'verified': true,
            },
          ],
        },
      };
      item.checked = false;
    }
    if (!catalog.canManage) {
      throw StateError(
        'Запазеното създаване трябва да се повтори от управител.',
      );
    }
    final savedFields = item.catalogRequest!['fields'] as Map;
    if ((savedFields['barcode']?.toString() ?? '').isNotEmpty) {
      throw StateError(
        'Стара каталожна заявка съдържа баркод с непотвърден произход. '
        'Обновете каталога за проверка на резултата; управител трябва да разреши '
        'заявката. Тя няма да бъде изпратена повторно или променена автоматично.',
      );
    }
    final savedIdentity =
        (savedFields['supplier_identifiers'] as List).single as Map;
    if (savedFields['name'] != item.name.trim() ||
        savedIdentity['code'] != item.supplierCode.trim() ||
        savedIdentity['supplier'] != supplier.trim()) {
      throw StateError(
        'Има непотвърден резултат за запазена каталожна заявка. Възстановете нейните име, доставчик и код или обновете каталога.',
      );
    }
    await persist(); // Including retries after an earlier local disk failure.
    final response = await catalog.submit(
      jsonDecode(jsonEncode(item.catalogRequest)) as Map<String, dynamic>,
      proposal: false,
    );
    if (response['status'] != 'saved' || response['product'] is! Map) {
      throw const FormatException(
        'Няма потвърден каталожен запис. Повторете същата заявка.',
      );
    }
    final product = RecordModel.fromJson(
      Map<String, dynamic>.from(response['product'] as Map),
    );
    final identity = ProductMatcher.supplierIdentity(item, [product], supplier);
    if (!identity.automatic || product.id.isEmpty) {
      throw const FormatException(
        'Каталогът не потвърди същия доставчик и код.',
      );
    }
    _assign(item, product);
    item.catalogRequest = null;
    await persist();
    return product;
  }

  void _assign(DraftItem item, RecordModel product) {
    item.productId = product.id;
    item.name = product.data['name']?.toString() ?? item.name;
    item.proposedNewProduct = false;
    item.productSelectionConfirmed = true;
    item.matchReason = 'Потвърден доставчик + артикулен код';
  }
}

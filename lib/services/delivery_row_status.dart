import '../models/delivery_draft.dart';
import 'product_catalog_service.dart';
import 'product_matcher.dart';

class DeliveryRowStatus {
  final String label, detail, action;
  final bool canAdd;
  const DeliveryRowStatus(
    this.label,
    this.detail,
    this.action, {
    this.canAdd = false,
  });
  static DeliveryRowStatus resolve(
    DraftItem item,
    String supplier,
    bool loaded,
    CatalogAccess access,
  ) {
    if (item.productId != null) {
      return const DeliveryRowStatus(
        'Разпознат продукт',
        'Каталожна идентичност; количеството, срокът и партидата са от тази доставка.',
        'Детайли',
      );
    }
    if (supplier.trim().isEmpty) {
      return const DeliveryRowStatus(
        'Нужна корекция',
        'Попълнете доставчика веднъж в „Данни за документа“. OCR артикулът е запазен.',
        'Коригирай',
      );
    }
    if (!ProductMatcher.validSupplierCode(item.supplierCode) ||
        item.name.trim().isEmpty) {
      return const DeliveryRowStatus(
        'Нужна корекция',
        'Проверете името и артикулния код по документа.',
        'Коригирай',
      );
    }
    if (!loaded) {
      return DeliveryRowStatus(
        'Чака управител',
        'Каталожните връзки не са заредени. ${access.message}',
        'Провери данните',
      );
    }
    if (!item.proposedNewProduct && item.requiresCatalogIdentity) {
      return DeliveryRowStatus('Нужна корекция', item.matchReason, 'Коригирай');
    }
    if (access.available && access.canFinalizeDelivery) {
      return const DeliveryRowStatus(
        'Нов продукт',
        'Ще се създаде с доставчика и кода при общото потвърждение на доставката.',
        'Детайли',
      );
    }
    if (!access.available || !access.canCreate) {
      return DeliveryRowStatus(
        'Чака управител',
        'OCR артикул: ${item.name}. ${access.message}',
        'Провери данните',
      );
    }
    return const DeliveryRowStatus(
      'Нов продукт',
      'Името и кодът са от OCR. Добавянето в каталога не създава наличност.',
      'Добави в каталога',
      canAdd: true,
    );
  }
}

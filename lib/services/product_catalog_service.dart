import 'package:pocketbase/pocketbase.dart';

import '../models/delivery_draft.dart';
import 'pocketbase_service.dart';

class CatalogAccess {
  final bool available, canCreate, canFinalizeDelivery;
  final String message;
  final int? statusCode;
  const CatalogAccess({
    required this.available,
    this.canCreate = false,
    this.canFinalizeDelivery = false,
    this.message = '',
    this.statusCode,
  });
}

class ProductCatalogService {
  Future<CatalogAccess> probe() async {
    final pb = PocketBaseService.pb;
    if (!pb.authStore.isValid ||
        pb.authStore.record?.collectionName != 'employees') {
      return const CatalogAccess(
        available: false,
        message: 'Нужна е валидна служителска сесия за проверка на Catalog V3.',
      );
    }
    try {
      final result = await pb
          .send<Map<String, dynamic>>('/api/store/catalog/capabilities')
          .timeout(const Duration(seconds: 10));
      final ready = result['protocol'] == 3 && result['catalog'] == true;
      return CatalogAccess(
        available: ready,
        canCreate: ready && result['can_manage'] == true,
        canFinalizeDelivery:
            ready && result['delivery_catalog_finalize'] == true,
        message: ready && result['delivery_catalog_finalize'] == true
            ? 'Новите OCR артикули се създават при общото потвърждение на доставката.'
            : ready
            ? (result['can_manage'] == true
                  ? 'Каталог V3 е достъпен.'
                  : 'Новите продукти се добавят от управител в „Продукти“, после обновете каталога.')
            : 'Каталог V3 не е активен. Управител трябва да одобри и внедри каталожния backend.',
      );
    } on ClientException catch (e) {
      return CatalogAccess(
        available: false,
        statusCode: e.statusCode,
        message: e.statusCode == 404
            ? 'Каталог V3 не е внедрен (HTTP 404). Управител трябва да одобри каталожния backend. OCR редовете остават в черновата.'
            : e.statusCode == 401 || e.statusCode == 403
            ? 'Няма разрешен достъп до Catalog V3. Проверете служителската сесия и правата.'
            : 'Каталог V3 е недостъпен (HTTP ${e.statusCode}). Черновата и OCR данните са запазени.',
      );
    } catch (_) {
      return const CatalogAccess(
        available: false,
        message: 'Проверката на Catalog V3 не завърши. Опитайте отново; OCR редовете са запазени.',
      );
    }
  }

  bool get canManage =>
      PocketBaseService.pb.authStore.isValid &&
      PocketBaseService.pb.authStore.record?.collectionName == 'employees' &&
      [
        'admin',
        'manager',
      ].contains(PocketBaseService.pb.authStore.record?.data['role']);

  Future<List<RecordModel>> history(String productId) => PocketBaseService.pb
      .collection('product_catalog_audit')
      .getFullList(
        filter: PocketBaseService.pb.filter('product = {:id}', {
          'id': productId,
        }),
        sort: '-created',
        expand: 'actor',
      );
  Future<bool> available() async {
    try {
      final result = await PocketBaseService.pb.send<Map<String, dynamic>>(
        '/api/store/catalog/capabilities',
      );
      return result['protocol'] == 3 && result['catalog'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> submit(
    Map<String, dynamic> body, {
    required bool proposal,
  }) => PocketBaseService.pb.send<Map<String, dynamic>>(
    proposal ? '/api/store/catalog/corrections' : '/api/store/catalog/products',
    method: 'POST',
    body: body,
  );

  Future<List<RecordModel>> corrections(String productId) async =>
      PocketBaseService.pb
          .collection('product_corrections')
          .getFullList(
            filter: PocketBaseService.pb.filter(
              'product = {:id} && status = "pending"',
              {'id': productId},
            ),
            sort: '-created',
          );

  Future<Map<String, dynamic>> confirmMatch({
    required RecordModel product,
    required String alias,
    required String supplier,
    required String code,
  }) => PocketBaseService.pb.send<Map<String, dynamic>>(
    '/api/store/catalog/confirm-match',
    method: 'POST',
    body: {
      'operation_key': 'match:${newDraftId()}',
      'product_id': product.id,
      'expected_revision': product.data['catalog_revision'] ?? 0,
      'alias': alias,
      'supplier': supplier,
      'code': code,
    },
  );

  static String message(Object error) {
    if (error is ClientException) {
      final code = error.response['code'];
      final known = <String, String>{
        'catalog_manager_required':
            'Само управител или администратор може да редактира каталога.',
        'conflicting_barcode':
            'Баркодът е свързан с друг продукт. Проверете двата записа.',
        'conflicting_supplier_identifier':
            'Комбинацията доставчик + код вече сочи друг продукт.',
        'duplicate_product_name':
            'Вече има продукт с това име. Изберете съществуващия запис.',
        'catalog_revision_conflict':
            'Продуктът е променен от друг служител. Отворете го отново.',
        'invalid_name_barcode_or_status':
            'Проверете името и контролния знак на EAN/GTIN баркода.',
      };
      if (known.containsKey(code)) return known[code]!;
      if ([404, 501, 503].contains(error.statusCode)) {
        return 'Редактирането изисква отделно внедрен каталог V3. Данните не са изпратени чрез стария API.';
      }
      if (error.statusCode == 0) {
        return 'Няма потвърден отговор. Повторете със същата запазена заявка.';
      }
    }
    return PocketBaseService.errorMessage(error);
  }
}

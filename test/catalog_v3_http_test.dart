import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';

void main() {
  const url = String.fromEnvironment('PB_V2_TEST_URL');
  test(
    'Real SDK catalog edit, learned match and unchanged V2 finalization',
    () async {
      final uri = Uri.parse(url);
      if (uri.host != '127.0.0.1' || uri.port == 8090) {
        throw StateError('Isolated localhost only');
      }
      final pb = PocketBaseService.pb, previous = PocketBaseService.pb.baseURL;
      try {
        pb.baseURL = url;
        await PocketBaseService.login('manager', 'synthetic-test-only-40.4!');
        final catalog = ProductCatalogService();
        expect(await catalog.available(), isTrue);
        expect(catalog.canManage, isTrue);
        final request = {
          'operation_key': 'sdk:catalog',
          'product_id': '',
          'expected_revision': 0,
          'fields': {
            'name': 'SDK каталог мляко',
            'barcode': '4006381333931',
            'category': 'Млечни',
            'active': true,
            'aliases': <String>[],
            'supplier_identifiers': <Map<String, dynamic>>[],
          },
        };
        final result = await catalog.submit(request, proposal: false);
        final id = result['product']['id'];
        final product = (await PocketBaseService.getProducts()).singleWhere(
          (p) => p.id == id,
        );
        final saved = await catalog.confirmMatch(
          product: product,
          alias: 'СКД МЛЯКО',
          supplier: 'SDK supplier',
          code: '0001',
        );
        expect(saved['product']['id'], id);
        final all = await PocketBaseService.getProducts();
        final item = DraftItem(
          name: 'СКД МЛЯКО',
          supplierCode: '0001',
          ordered: '6',
          received: '6',
          expiry: '08.11.2026',
          original: {'name': 'СКД МЛЯКО'},
        );
        ProductMatcher.prepare(item, all, 'SDK supplier');
        expect(item.productId, id);
        item.checked = true;
        final draft = DeliveryDraft(
          ownerId: pb.authStore.record!.id,
          supplier: 'SDK supplier',
          pages: [
            DraftPage(imagePath: '', recognized: true, items: [item]),
          ],
        );
        final finalizer = PocketBaseDeliveryFinalizer();
        await finalizer.probe();
        await finalizer.prepare(draft, () async {});
        final packet = DeliveryFinalization.request(draft),
            receipt = await finalizer.finalize(
              draft.serverId!,
              DeliveryFinalization.request(draft),
            );
        expect(receipt['status'], 'finalized');
        expect(receipt['lines'][0]['product_id'], id);
        expect(await finalizer.finalize(draft.serverId!, packet), receipt);
      } finally {
        PocketBaseService.logout();
        pb.baseURL = previous;
      }
    },
    skip: url.isEmpty
        ? 'Run via backend/tool/test_backend.py --catalog --flutter'
        : false,
  );
}

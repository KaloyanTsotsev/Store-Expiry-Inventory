import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_matcher.dart';

void main() {
  const url = String.fromEnvironment('PB_V2_TEST_URL');
  test(
    'Real Flutter SDK stages photos and finalizes one atomic V2 delivery without duplicates',
    () async {
      final uri = Uri.parse(url);
      if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port == 8090) {
        throw StateError(
          'Only the isolated localhost test runtime is permitted',
        );
      }
      final pb = PocketBaseService.pb, original = PocketBaseService.pb.baseURL;
      final root = await Directory.systemTemp.createTemp('flutter-v2-sdk-');
      try {
        pb.baseURL = url;
        await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
        final client = PocketBaseDeliveryFinalizer();
        await client.probe();
        expect(client.available, isTrue);
        final file = File('${root.path}/document.png');
        await file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6T8AAAAASUVORK5CYII=',
          ),
        );
        final draft = DeliveryDraft(
          ownerId: pb.authStore.record!.id,
          supplier: 'Synthetic Flutter supplier',
          pages: [
            DraftPage(
              imagePath: file.path,
              recognized: true,
              text: 'Synthetic source OCR',
              barcodes: const [PageBarcode(value: '000123', type: 'CODE_128')],
              items: [
                for (final expiry in ['08.11.2026', '15.11.2026'])
                  DraftItem(
                    name: 'Flutter SDK yoghurt',
                    supplierCode: 'SDK001',
                    ordered: '12',
                    received: '6',
                    expiry: expiry,
                    lot: '1',
                    proposedNewProduct: true,
                    checked: true,
                    original: const {'lot': '1'},
                  ),
              ],
            ),
          ],
        );
        final repository = DraftRepository(rootDirectory: () async => root);
        await repository.save(draft);
        await client.prepare(draft, () => repository.save(draft));
        expect(draft.serverId, isNotNull);
        expect(draft.serverRevision, 2);
        expect(draft.stagingRequest, isNotNull);
        final remoteEvidence = await pb
            .collection('delivery_pages')
            .getFullList(
              filter: pb.filter('delivery = {:id}', {'id': draft.serverId}),
            );
        expect(remoteEvidence, hasLength(1));
        final rawOcr = remoteEvidence.single.data['raw_ocr'] as Map;
        final evidence = jsonDecode(rawOcr['text'] as String);
        expect(evidence['page_id'], draft.pages.single.id);
        expect(evidence['barcodes'][0]['value'], '000123');
        expect(evidence['original_ocr_text'], 'Synthetic source OCR');
        // Prepared-upload retries reuse the original stage and skip the uploaded photo.
        await client.prepare(draft, () => repository.save(draft));
        expect(draft.serverRevision, 2);
        draft.finalizationRequest = DeliveryFinalization.request(draft);
        await repository.save(draft);
        final result = await client.finalize(
          draft.serverId!,
          draft.finalizationRequest!,
        );
        expect(result['status'], 'finalized');
        expect(result['revision'], 3);
        expect(result['lines'], hasLength(2));
        final repeated = await client.finalize(
          draft.serverId!,
          draft.finalizationRequest!,
        );
        expect(repeated, result);
        final batches = await pb
            .collection('batches')
            .getFullList(
              filter: pb.filter('delivery = {:delivery}', {
                'delivery': draft.serverId,
              }),
              sort: 'expiry_date',
            );
        expect(batches, hasLength(2));
        expect(batches[0].id, isNot(batches[1].id));
        expect(batches.map((r) => r.getStringValue('lot_number')), [
          'N/A',
          'N/A',
        ]);
        expect(
          batches.map((r) => r.getStringValue('expiry_date').substring(0, 10)),
          ['2026-11-08', '2026-11-15'],
        );
        expect(
          batches[0].getStringValue('product'),
          batches[1].getStringValue('product'),
        );
        draft.status = 'finalized';
        draft.finalizationReceipt = result;
        draft.serverRevision = result['revision'] as int;
        await repository.save(draft);
        final restored = await repository.load(draft.ownerId, draft.id);
        expect(restored.status, 'finalized');
        expect(restored.checkedCount, 2);
        expect(restored.items.first.original['lot'], '1');
      } finally {
        pb.baseURL = original;
        pb.authStore.clear();
        await root.delete(recursive: true);
      }
    },
    skip: url.isEmpty
        ? 'Run via backend/tool/test_backend.py --flutter'
        : false,
  );
  test(
    'Real SDK employee direct barcode finalization and exact replay',
    () async {
      final pb = PocketBaseService.pb, original = PocketBaseService.pb.baseURL;
      try {
        pb.baseURL = url;
        await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
        final client = PocketBaseDeliveryFinalizer();
        await client.probe();
        final rows = [
          for (var i = 0; i < 3; i++)
            DraftItem(
              name: 'SDK bulk product $i',
              supplierCode: '000SDK-BULK-$i',
              ordered: '',
              received: '8',
              expiry: '22.11.2026',
              lot: 'N/A',
              requiresCatalogIdentity: true,
              proposedNewProduct: true,
              articleBarcode: true,
              checked: true,
            ),
        ];
        final draft = DeliveryDraft(
          ownerId: pb.authStore.record!.id,
          pages: [DraftPage(imagePath: '', recognized: true, items: rows)],
        );
        await client.prepare(draft, () async {});
        final request = {
          ...DeliveryFinalization.request(draft),
          'finalize_by_code': true,
        };
        final receipt = await client.finalize(draft.serverId!, request);
        expect(receipt['status'], 'finalized');
        expect(receipt['lines'], hasLength(3));
        expect(await client.finalize(draft.serverId!, request), receipt);
        for (final line in receipt['lines'] as List) {
          final p = await pb
              .collection('products')
              .getOne(line['product_id'] as String);
          expect(p.getStringValue('barcode'), startsWith('000SDK-BULK-'));
          expect(p.data['supplier_identifiers'] ?? [], isEmpty);
        }
      } finally {
        pb.baseURL = original;
        pb.authStore.clear();
      }
    },
    skip: url.isEmpty
        ? 'Run via backend/tool/test_backend.py --catalog --flutter'
        : false,
  );
  test('Real 37-row Paddle document: correct, save, reuse, dashboard, replay', () async {
    final uri = Uri.parse(url);
    if (uri.host != '127.0.0.1' || uri.port == 8090) {
      throw StateError('Only isolated test PocketBase is permitted');
    }
    final pb = PocketBaseService.pb, original = PocketBaseService.pb.baseURL;
    final root = await Directory.systemTemp.createTemp('paddle-37-sdk-');
    try {
      pb.baseURL = url;
      await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
      final client = PocketBaseDeliveryFinalizer();
      await client.probe();
      final json = jsonDecode(
        File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final rows = PaddleDocumentAdapter().parse(json).items;
      expect(rows, hasLength(37));
      final repo = DraftRepository(rootDirectory: () async => root);
      Future<Map<String, dynamic>> commit(DeliveryDraft draft) async {
        expect(draft.allReady, isTrue);
        // Explicit final Save confirms the displayed data, not the OCR import.
        for (final item in draft.items) {
          item.checked = item.ready;
        }
        await client.prepare(draft, () => repo.save(draft));
        draft.finalizationRequest = {
          ...DeliveryFinalization.request(draft),
          'finalize_by_code': true,
        };
        await repo.save(draft);
        final receipt = await client.finalize(
          draft.serverId!,
          draft.finalizationRequest!,
        );
        draft.finalizationReceipt = receipt;
        draft.status = 'finalized';
        draft.serverRevision = receipt['revision'] as int;
        await repo.save(draft);
        return receipt;
      }

      // A prior delivery establishes one real catalog identity, with its own batch.
      final previous = DraftItem(
        name: 'Каталожно мляко',
        supplierCode: rows.first.supplierCode,
        received: '3',
        expiry: '01.12.2026',
        lot: 'OLD',
        articleBarcode: true,
        proposedNewProduct: true,
      );
      final first = DeliveryDraft(
        ownerId: pb.authStore.record!.id,
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [previous]),
        ],
      );
      final earlier = await commit(first);
      final existingId = (earlier['lines'] as List).single['product_id'];
      final products = await PocketBaseService.getProducts();
      var corrected = 0;
      for (final item in rows) {
        item.articleBarcode = true;
        ProductMatcher.prepare(item, products, '');
        expect(item.checked, isFalse);
        if (parseDocumentDate(item.expiry) == null) {
          expect(item.ready, isFalse);
          // Synthetic employee correction, never inferred from OCR's "1".
          item.edit('expiry', '25.11.2026');
          corrected++;
        }
        expect(item.ready, isTrue, reason: item.validationErrors.join(', '));
      }
      expect(corrected, 14);
      expect(rows.first.productId, existingId);
      expect(rows.first.name, 'Каталожно мляко');
      final draft = DeliveryDraft(
        ownerId: pb.authStore.record!.id,
        pages: [
          DraftPage(
            imagePath: File('test/fixtures/paddle/document.jpg').absolute.path,
            text: jsonEncode(json),
            recognized: true,
            items: rows,
          ),
        ],
      );
      expect(draft.readyCount, 37);
      final receipt = await commit(draft);
      expect(receipt['lines'], hasLength(37));
      expect(
        await client.finalize(draft.serverId!, draft.finalizationRequest!),
        receipt,
      );
      final batches = await pb
          .collection('batches')
          .getFullList(
            filter: pb.filter('delivery = {:id}', {'id': draft.serverId}),
          );
      expect(batches, hasLength(37));
      for (var i = 0; i < rows.length; i++) {
        final saved = (receipt['lines'] as List).singleWhere(
          (line) => line['line_id'] == rows[i].id,
        );
        final product = await pb
            .collection('products')
            .getOne(saved['product_id'] as String);
        final batch = batches.singleWhere((b) => b.id == saved['batch_id']);
        expect(product.getStringValue('barcode'), rows[i].supplierCode);
        expect(batch.get<num>('quantity'), parseQuantity(rows[i].received));
        expect(
          batch.getStringValue('expiry_date').substring(0, 10),
          parseDocumentDate(rows[i].expiry)!.toIso8601String().substring(0, 10),
        );
      }
      final codeMatches = await pb
          .collection('products')
          .getFullList(
            filter: pb.filter('barcode = {:code}', {
              'code': rows.first.supplierCode,
            }),
          );
      expect(codeMatches, hasLength(1));
      final oldBatch = await pb
          .collection('batches')
          .getOne((earlier['lines'] as List).single['batch_id'] as String);
      expect(
        oldBatch.getStringValue('expiry_date').substring(0, 10),
        '2026-12-01',
      );
      expect(oldBatch.get<num>('quantity'), 3);
      final dashboard = await PocketBaseService.getExpiryBatches();
      expect(
        dashboard
            .map((b) => b.id)
            .toSet()
            .containsAll(batches.map((b) => b.id)),
        isTrue,
      );
      final restored = await repo.load(draft.ownerId, draft.id);
      expect(restored.status, 'finalized');
      expect(restored.finalizationReceipt, receipt);
      final remote = await pb.collection('deliveries').getOne(draft.serverId!);
      expect(remote.getStringValue('status'), 'finalized');
    } finally {
      pb.baseURL = original;
      pb.authStore.clear();
      await root.delete(recursive: true);
    }
  }, skip: url.isEmpty ? 'Run via isolated backend harness --flutter' : false);
}

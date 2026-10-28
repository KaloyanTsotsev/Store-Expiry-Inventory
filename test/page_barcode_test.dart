import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/delivery_catalog_service.dart';

import 'delivery_identity_test.dart' as fixtures;

Map<String, dynamic> response() => jsonDecode(
  File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  final adapter = PaddleDocumentAdapter();
  test(
    '37 rows keep article codes; one document barcode belongs only to page',
    () {
      final data = response()
        ..['barcodes'] = [
          {'value': '00012345678905', 'type': 'ITF', 'confidence': 0.91},
        ];
      // Even an upstream row barcode is untrusted evidence, not a catalog GTIN.
      (data['products'] as List).first['barcode'] = '5901234123457';
      final page = DraftPage(id: 'page1', imagePath: 'photo.jpg');
      adapter.applyPageEvidence(page, data);
      page.items = adapter.parse(data).items;
      expect(page.items, hasLength(37));
      expect(page.items.every((i) => i.barcode.isEmpty), isTrue);
      expect(
        page.items.first.supplierCode,
        data['products'][0]['article_code'],
      );
      expect(
        page.items.first.original['paddle_product'],
        contains('5901234123457'),
      );
      expect(page.barcodes.single.value, '00012345678905');
      expect(page.barcodes.single.type, 'ITF');
      final evidence = jsonDecode(page.evidenceText);
      expect(evidence['page_id'], page.id);
      expect(jsonDecode(evidence['original_ocr_text']), data);
      expect(evidence['barcodes'][0]['original']['confidence'], 0.91);
    },
  );
  test(
    'Two photos retain separate barcode evidence across draft serialization',
    () {
      final pages = [
        for (var i = 1; i <= 2; i++) DraftPage(id: 'p$i', imagePath: '$i.jpg'),
      ];
      for (var i = 0; i < 2; i++) {
        adapter.applyPageEvidence(
          pages[i],
          response()..['barcode'] = 'page-code-$i',
        );
      }
      final draft = DeliveryDraft(ownerId: 'test', pages: pages);
      final restored = DeliveryDraft.fromJson(
        jsonDecode(jsonEncode(draft.toJson())),
      );
      expect(restored.pages.map((p) => p.barcodes.single.value), [
        'page-code-0',
        'page-code-1',
      ]);
      expect(restored.pages.map((p) => jsonDecode(p.evidenceText)['page_id']), [
        'p1',
        'p2',
      ]);
    },
  );
  test(
    'Multiple codes keep original values and explicit types; no type guessing',
    () {
      final page = DraftPage(imagePath: 'photo.jpg');
      adapter.applyPageEvidence(
        page,
        response()
          ..['barcodes'] = [
            {'text': ' 000123 ', 'format': 'CODE_128'},
            '5901234123457',
            {'value': 'https://supplier.invalid/doc/1', 'type': 'QR_CODE'},
            {'value': ' ', 'confidence': 95},
          ],
      );
      expect(page.barcodes.map((b) => b.value), [
        ' 000123 ',
        '5901234123457',
        'https://supplier.invalid/doc/1',
      ]);
      expect(page.barcodes[1].type, isNull);
    },
  );
  test('Repeat import replaces evidence without duplicates, preserving raw response', () {
    final page = DraftPage(imagePath: 'photo.jpg');
    final data = response()..['barcodes'] = ['00123', '00123', '00456'];
    for (var i = 0; i < 3; i++) {
      adapter.applyPageEvidence(page, data);
    }
    expect(page.barcodes, hasLength(2));
    expect(jsonDecode(page.text), data);
    adapter.applyPageEvidence(page, response());
    expect(page.barcodes, isEmpty);
    expect(page.evidenceText, page.text);
  });
  test('No barcode is inferred from article codes or free text', () {
    final data = response()..['raw_text'] = ['5901234123457'];
    expect(adapter.pageBarcodes(data), isEmpty);
    final row = fixtures.line();
    ProductMatcher.prepare(row, [fixtures.product('known')], 'А');
    expect(row.productId, 'known');
    expect(row.barcode, isEmpty);
  });
  test(
    'New catalog product stays barcode-empty even with a legacy row barcode',
    () async {
      final item = fixtures.line()..barcode = '5901234123457';
      final catalog = fixtures.Catalog();
      final saved = await DeliveryCatalogService(catalog: catalog).confirm(
        item: item,
        supplier: 'А',
        products: [],
        physicallyConfirmed: true,
        persist: () async {},
      );
      expect(saved.data['barcode'], isEmpty);
      expect(item.original, {'name': 'OCR мляк0'});
      expect(catalog.writes, 1);
      final known = fixtures.product('known')
        ..data['barcode'] = '4006381333931';
      await DeliveryCatalogService(catalog: catalog).confirm(
        item: fixtures.line(),
        supplier: 'А',
        products: [known],
        physicallyConfirmed: true,
        persist: () async {},
      );
      expect(known.data['barcode'], '4006381333931');
      expect(catalog.writes, 1);
    },
  );
  test(
    'Legacy pending request with a barcode is neither mutated nor replayed',
    () async {
      final catalog = fixtures.Catalog(loseFirst: true);
      final item = fixtures.line();
      final service = DeliveryCatalogService(catalog: catalog);
      await expectLater(
        service.confirm(
          item: item,
          supplier: 'А',
          products: [],
          physicallyConfirmed: true,
          persist: () async {},
        ),
        throwsStateError,
      );
      (item.catalogRequest!['fields'] as Map)['barcode'] = '5901234123457';
      final snapshot = jsonEncode(item.catalogRequest);
      await expectLater(
        service.confirm(
          item: item,
          supplier: 'А',
          products: [],
          physicallyConfirmed: true,
          persist: () async {},
        ),
        throwsStateError,
      );
      expect(jsonEncode(item.catalogRequest), snapshot);
      expect(catalog.calls, 1);
    },
  );
}

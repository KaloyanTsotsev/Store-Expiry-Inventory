import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/ocr_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';

class _RealFixtureEngine implements OcrEngine {
  @override
  Future<Map<String, dynamic>> recognize(String path) async => realResponse();
}

class _MemoryDrafts extends DraftRepository {
  @override
  Future<void> save(DeliveryDraft draft) async {}
}

Map<String, dynamic> realResponse() => jsonDecode(
  File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  testWidgets(
    'Editor consumes structured Paddle rows and preserves original document response',
    (tester) async {
      final page = DraftPage(imagePath: 'missing-test-photo.jpg');
      final draft = DeliveryDraft(ownerId: 'test', pages: [page]);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _MemoryDrafts(),
            engine: _RealFixtureEngine(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.text('Разпознай страниците');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(page.items, hasLength(37));
      expect(
        page.items.every((i) => !i.checked && i.received == i.ordered),
        isTrue,
      );
      expect(jsonDecode(page.text), realResponse());
      expect(page.words, isEmpty);
      expect(page.elapsedMs, 29400);
      expect(draft.allReviewed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  final adapter = PaddleDocumentAdapter();
  test('Real PP-OCRv5 JSON: 37 rows, 23 dates/lots; suggested quantities remain unconfirmed', () {
    final response = realResponse();
    final items = adapter.parse(response).items;
    expect(items, hasLength(37));
    expect(
      items.where((i) => parseDocumentDate(i.expiry) != null),
      hasLength(23),
    );
    expect(items.where((i) => i.lot != 'N/A'), hasLength(23));
    expect(
      items.every(
        (i) =>
            i.received == i.ordered &&
            i.difference.isEmpty &&
            !i.checked &&
            !i.proposedNewProduct,
      ),
      isTrue,
    );
    for (var index = 0; index < items.length; index++) {
      expect(
        jsonDecode(items[index].original['paddle_product']!),
        response['products'][index],
      );
      expect(
        DraftItem.fromJson(items[index].toJson()).original,
        items[index].original,
      );
    }
    expect(items[1].expiry, '08.11.2026');
    expect(items[1].lot, 'L08112026');
    expect(items[1].ordered, '12');
    expect(items[3].expiry, isEmpty);
    expect(items[3].lot, 'N/A');
    expect(items[3].original['raw_expiry_batch'], '1 1');
    final draft = DeliveryDraft(
      ownerId: 'test',
      pages: [DraftPage(imagePath: '', recognized: true, items: items)],
    );
    expect(draft.allReviewed, isFalse);
    expect(DeliveryFinalization.errors(draft), isNotEmpty);
  });
  test('Missing/unreliable values never become invented dates, lots, or quantities', () {
    for (final value in [null, '1', '2026-02-31', '08.11.2026']) {
      final item = adapter
          .parse({
            'status': 'ok',
            'engine': 'PaddleOCR PP-OCRv5',
            'products': [
              {
                'name': 'Мляко',
                'article_code': '300001702',
                'expiry_date': value,
                'batch_number': '1',
                'requested_quantity': null,
                'difference': -12,
                'raw_expiry_batch': '08.11.2026 L123',
                'requires_review': false,
              },
            ],
          })
          .items
          .single;
      expect(item.expiry, isEmpty);
      expect(item.lot, 'N/A');
      expect(item.ordered, isEmpty);
      expect(item.received, isEmpty);
      expect(item.supplierCode, '300001702');
      expect(item.checked, isFalse);
    }
    expect(
      adapter.parse({
        'status': 'ok',
        'engine': 'PaddleOCR PP-OCRv5',
        'products': [],
      }).items,
      isEmpty,
    );
    expect(() => adapter.parse({'products': []}), throwsFormatException);
  });
  test('Merged date/lot evidence retained; confirmed catalog mapping changes draft name only', () {
    final items = adapter.parse(realResponse()).items;
    final item = items.firstWhere((i) => i.supplierCode == '900002450');
    expect(item.original['raw_expiry_batch'], '14.11.2026L141126T01');
    expect(item.expiry, '14.11.2026');
    expect(item.lot, 'L141126T01');
    final p = RecordModel.fromJson({
      'id': 'stable-product',
      'name': 'Каталожно име',
      'active': true,
      'supplier_identifiers': [
        {'supplier': 'А', 'code': '900002450', 'verified': true},
      ],
    });
    final original = Map.of(item.original);
    ProductMatcher.prepare(item, [p], 'А');
    expect(item.name, 'Каталожно име');
    expect(item.original, original);
    expect(p.data['name'], 'Каталожно име');
    expect(item.checked, isFalse);
    expect(item.received, item.ordered);
  });
}

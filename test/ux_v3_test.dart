import 'support/legacy_delivery_parser.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/expiry_batch.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/batch_check_repository.dart';

ExpiryBatch batch(String date, {String status = '', int? warning}) =>
    ExpiryBatch.fromRecord(
      RecordModel.fromJson({
        'id': 'batch1',
        'expiry_date': date,
        'status': status,
        'lot_number': 'LOT-A',
        'quantity': 999,
        'expand': {
          'product': {
            'id': 'prod1',
            'name': 'Мляко',
            'expiry_warning_days': ?warning,
          },
        },
      }),
      now: DateTime(2026, 10, 22, 23, 59),
    );
void main() {
  test('Calendar buckets have exact non-overlapping boundaries, no delivered stock inference', () {
    final cases = {
      '2026-10-21': ExpiryBucket.expired,
      '2026-10-22': ExpiryBucket.today,
      '2026-10-23': ExpiryBucket.week,
      '2026-10-29': ExpiryBucket.week,
      '2026-10-30': ExpiryBucket.month,
      '2026-11-21': ExpiryBucket.month,
      '2026-11-22': ExpiryBucket.later,
    };
    for (final entry in cases.entries) {
      expect(batch(entry.key).bucket, entry.value);
    }
    expect(batch('2026-10-23').days, 1);
    expect(batch('2026-10-25').days, 3); // DST weekend: calendar days.
    expect(batch('2026-02-29').bucket, ExpiryBucket.unknown);
    expect(ExpiryBatch.dateOnly('2028-02-29'), DateTime.utc(2028, 2, 29));
    expect(batch('2026-10-21', warning: 0).label, contains('отстрани'));
    expect(batch('2026-10-21').label, isNot(contains('намаление')));
    expect(batch('2026-10-25', warning: 2).alert, isFalse);
    expect(batch('2026-10-25', warning: 7).alert, isTrue);
    expect(batch('2026-10-23', status: 'closed').closed, isTrue);
    expect(batch('2026-10-23').productName, 'Мляко');
  });
  test('Every editable field unchecks a reviewed row; legacy fields survive round trip', () {
    for (final field in [
      'name',
      'supplierCode',
      'ordered',
      'received',
      'expiry',
      'lot',
    ]) {
      final item = DraftItem(
        name: 'Мляко',
        received: '2',
        expiry: '23.10.2026',
        lot: 'A',
        productId: 'p',
        unit: 'old',
        difference: '-1',
        checked: true,
      );
      item.edit(field, 'changed');
      expect(item.checked, isFalse, reason: field);
      expect(DraftItem.fromJson(item.toJson()).unit, 'old');
    }
    final proposed = DraftItem(
      name: 'Нов продукт',
      received: '2',
      expiry: '23.10.2026',
      lot: 'A',
      proposedNewProduct: true,
    );
    expect(proposed.validationErrors, isEmpty);
    expect(proposed.checked, isFalse);
  });
  test('Product matching refuses ambiguous names and never treats article as barcode', () {
    final products = [
      RecordModel.fromJson({'id': 'p1', 'name': 'Мляко', 'barcode': '90001'}),
      RecordModel.fromJson({'id': 'p2', 'name': 'Мляко'}),
    ];
    final ambiguous = DraftItem(name: 'Мляко');
    ProductMatcher.prepare(ambiguous, products, 'Доставчик');
    expect(ambiguous.productId, isNull);
    expect(ambiguous.proposedNewProduct, isFalse);
    final newItem = DraftItem(name: 'Сирене', supplierCode: '90001');
    ProductMatcher.prepare(newItem, products, 'Доставчик');
    expect(newItem.productId, isNull);
    expect(newItem.proposedNewProduct, isFalse);
    newItem.productId = 'p2';
    newItem.productSelectionConfirmed = true;
    ProductMatcher.prepare(newItem, products, 'Доставчик');
    expect(newItem.productId, 'p2');
    final mapped = RecordModel.fromJson({
      'id': 'p3',
      'name': 'Точно име',
      'supplier_identifiers': [
        {'verified': true, 'supplier': 'Доставчик', 'code': '90001'},
      ],
    });
    final code = DraftItem(name: 'OCR име', supplierCode: '90001');
    ProductMatcher.prepare(code, [mapped], 'Доставчик');
    expect(code.productId, 'p3');
    code.productId = null;
    ProductMatcher.prepare(code, [mapped], 'Друг');
    expect(code.productId, isNull);
  });
  test(
    'Five columns parse without Unit or Difference and only prefill quantities',
    () {
      final words = <OcrWord>[];
      final headings = [
        'Артикул',
        'Наименование',
        'Заявени',
        'Годност',
        'Партида',
      ];
      final lefts = [10.0, 170.0, 500.0, 600.0, 800.0];
      for (var i = 0; i < 5; i++) {
        words.add(OcrWord(headings[i], 99, lefts[i], 10, lefts[i] + 80, 30));
      }
      for (var row = 0; row < 2; row++) {
        final values = [
          '900000${row + 1}',
          'Тестово мляко',
          row == 0 ? '12' : 'неясно',
          '23.10.2026',
          'L23',
        ];
        for (var i = 0; i < 5; i++) {
          words.add(
            OcrWord(
              values[i],
              99,
              lefts[i],
              70.0 + row * 40,
              lefts[i] + 80,
              90.0 + row * 40,
            ),
          );
        }
      }
      final result = DeliveryTableParser().parse(words, 1000);
      expect(result.items, hasLength(2));
      expect(result.items.first.received, '12');
      expect(result.items.last.received, isEmpty);
      expect(result.items.first.checked, isFalse);
      expect(result.items.first.unit, isEmpty);
      expect(result.items.first.name, 'Тестово мляко');
    },
  );
  test('Pending checks reject duplicate operations and invalid waste; owner separated', () async {
    final root = await Directory.systemTemp.createTemp('expiry-check-');
    try {
      final repo = BatchCheckRepository(rootDirectory: () async => root);
      await expectLater(
        repo.prepare(
          owner: 'employee1',
          batch: batch('2026-10-21'),
          kind: 'waste',
          quantity: '2',
        ),
        throwsArgumentError,
      );
      final first = repo.prepare(
        owner: 'employee1',
        batch: batch('2026-10-21'),
        kind: 'waste',
        quantity: '2',
        reason: 'Изтекъл',
      );
      final duplicate = repo.prepare(
        owner: 'employee1',
        batch: batch('2026-10-21'),
        kind: 'none',
        quantity: '0',
      );
      await expectLater(duplicate, throwsStateError);
      await first;
      final pending = await repo.list('employee1');
      expect(pending, hasLength(1));
      expect(pending.single['sync_status'], 'not_sent');
      expect(await repo.list('employee2'), isEmpty);
      await repo.cancel('employee2', pending.single['operation_key'] as String);
      expect(await repo.list('employee1'), hasLength(1));
      await repo.cancel('employee1', pending.single['operation_key'] as String);
      expect(await repo.list('employee1'), isEmpty);
      await expectLater(
        repo.prepare(
          owner: 'employee1',
          batch: batch('2026-10-21', status: 'closed'),
          kind: 'none',
          quantity: '0',
        ),
        throwsArgumentError,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/models/expiry_batch.dart';
import 'package:pocketbase/pocketbase.dart';

DraftItem received({String lot = '', String expiry = '08.11.2026'}) =>
    DraftItem(
      name: 'Кисело мляко',
      productId: 'product1',
      received: '6',
      ordered: '12',
      expiry: expiry,
      lot: lot,
      original: {'lot': lot, 'name': 'Кисело мляко'},
      uncertainFields: const ['lot'],
    );
void main() {
  test('Missing and placeholder lots become N/A without a validation or review warning', () {
    for (final raw in ['', ' ', '\t', '1', ' 1 ', 'N/A', 'n/a']) {
      final item = received(lot: raw);
      expect(item.lot, 'N/A', reason: raw);
      expect(item.toJson()['lot'], 'N/A');
      expect(item.toJson()['uncertainFields'], isNot(contains('lot')));
      expect(item.original['lot'], raw);
      expect(item.validationErrors, isEmpty);
      expect(item.uncertainFields, isNot(contains('lot')));
      expect(item.unclear, isFalse);
      expect(item.checked, isFalse);
      item.checked = true;
      final draft = DeliveryDraft(
        ownerId: 'employee1',
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [item]),
        ],
      );
      expect(draft.allReviewed, isTrue);
      item.edit('received', '5');
      expect(item.checked, isFalse);
      expect(draft.allReviewed, isFalse);
    }
  });
  test('Real lots remain editable; missing lot never relaxes expiry and quantity validation', () {
    for (final raw in ['L1', '01', '1A', 'LOT-A', '  L23  ']) {
      final item = received(lot: raw);
      expect(item.lot, raw.trim());
      item.checked = true;
      item.edit('lot', 'REAL-2');
      expect(item.lot, 'REAL-2');
      expect(item.checked, isFalse);
      item.edit('lot', '');
      expect(item.lot, 'N/A');
    }
    for (final expiry in ['', '1', '31.02.2026']) {
      expect(
        received(expiry: expiry).validationErrors.join(),
        contains('Невалиден срок'),
      );
    }
    final item = received();
    item.received = '';
    expect(item.validationErrors, isNotEmpty);
  });
  test('Legacy JSON normalizes lot without overwriting original OCR or checked state', () {
    final original = received(lot: 'L1');
    final json = {
      ...original.toJson(),
      'lot': '1',
      'original': {'lot': '1'},
      'checked': true,
    };
    json.remove('sourceRowId');
    final loaded = DraftItem.fromJson(json);
    expect(loaded.lot, 'N/A');
    expect(loaded.original['lot'], '1');
    expect(loaded.id, original.id);
    expect(loaded.sourceRowId, original.id);
    expect(loaded.checked, isTrue);
    expect(loaded.validationErrors, isEmpty);
    final saved = DraftItem.fromJson(loaded.toJson());
    expect(saved.lot, 'N/A');
    expect(saved.original['lot'], '1');
  });
  test('Two expiry groups with same product and N/A remain separate with source provenance', () {
    final first = received(lot: '1');
    final second = DraftItem(
      sourceRowId: first.sourceRowId,
      name: first.name,
      productId: first.productId,
      received: '6',
      expiry: '15.11.2026',
      lot: '',
      original: first.original,
    );
    final page = DraftPage(
      imagePath: 'document-photo.jpg',
      recognized: true,
      items: [first, second],
      text: 'original OCR document',
    );
    final document = DeliveryDraft(ownerId: 'employee1', pages: [page]);
    final reopened = DeliveryDraft.fromJson(document.toJson());
    final groups = reopened.items.toList();
    expect(groups, hasLength(2));
    expect(groups.map((i) => i.lot), ['N/A', 'N/A']);
    expect(groups[0].id, isNot(groups[1].id));
    expect(groups[0].sourceRowId, groups[1].sourceRowId);
    expect(groups.map((i) => i.expiry), ['08.11.2026', '15.11.2026']);
    expect(groups.every((i) => i.original['lot'] == '1'), isTrue);
    expect(reopened.id, document.id);
    expect(reopened.pages.single.id, page.id);
    expect(reopened.pages.single.imagePath, 'document-photo.jpg');
  });
  test('Dashboard missing lots display N/A and records retain their own PocketBase IDs', () {
    final records = [
      for (final id in ['batch1', 'batch2'])
        ExpiryBatch.fromRecord(
          RecordModel.fromJson({
            'id': id,
            'lot_number': id == 'batch1' ? '1' : '',
            'expiry_date': '2026-11-08',
          }),
          now: DateTime(2026, 10, 22),
        ),
    ];
    expect(records.map((r) => r.lot), ['N/A', 'N/A']);
    expect(records.map((r) => r.id), ['batch1', 'batch2']);
  });
}

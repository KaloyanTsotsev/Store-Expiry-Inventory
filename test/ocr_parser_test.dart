import 'support/legacy_delivery_parser.dart';

import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic table fixture: no names, addresses or identifiers of real people.
List<OcrWord> syntheticTable() => [
  for (var row = 0; row < 2; row++) ...[
    OcrWord('SUP00000$row', 95, 30, 100 + row * 40, 145, 120 + row * 40),
    OcrWord('Тестово мляко', 95, 180, 100 + row * 40, 400, 120 + row * 40),
    OcrWord('12', 95, 575, 100 + row * 40, 600, 120 + row * 40),
    OcrWord('бройка', 95, 620, 100 + row * 40, 680, 120 + row * 40),
    OcrWord(
      row == 0 ? '08.11.2026' : '1',
      70,
      700,
      100 + row * 40,
      800,
      120 + row * 40,
    ),
    OcrWord(
      row == 0 ? 'LOT-A' : '1',
      80,
      830,
      100 + row * 40,
      900,
      120 + row * 40,
    ),
    OcrWord('-2', 95, 975, 100 + row * 40, 995, 120 + row * 40),
  ],
];

void main() {
  test(
    'OCR keeps empty original lot while using N/A without missing-lot warnings',
    () {
      final rows = DeliveryTableParser()
          .parse(
            syntheticTable().where((w) => w.text != 'LOT-A').toList(),
            1100,
          )
          .items;
      expect(rows, hasLength(2));
      expect(rows.first.lot, 'N/A');
      expect(rows.first.original['lot'], '');
      expect(rows.first.uncertainFields, isNot(contains('lot')));
      expect(rows.last.lot, 'N/A');
      expect(rows.last.original['lot'], '1');
    },
  );

  test(
    'Missing top codes and a missing bottom unit do not shift neighboring rows',
    () {
      final words = <OcrWord>[];
      for (var row = 0; row < 8; row++) {
        void word(String text, double left, double right) {
          final y = 100 + row * 40 - .025 * (left + right) / 2;
          words.add(OcrWord(text, 95, left, y - 10, right, y + 10, line: row));
        }

        if (row > 1) word('SUP00000$row', 30, 145);
        word('Продукт $row', 180, 400);
        word('${row + 1}', 575, 600);
        if (row < 7) word('бройка', 620, 680);
        word('08.11.2026', 700, 800);
        word('LOT-$row', 830, 900);
        word('0', 975, 995);
      }
      final rows = DeliveryTableParser().parse(words, 1100).items;
      expect(rows, hasLength(8));
      for (var row = 0; row < rows.length; row++) {
        expect(rows[row].name, 'Продукт $row');
        expect(rows[row].ordered, '${row + 1}');
        expect(rows[row].lot, 'LOT-$row');
      }
    },
  );
  test(
    'Strict dates reject placeholder, invalid calendar dates and OCR typos',
    () {
      for (final input in [
        '1',
        '31.02.2026',
        '13.17.2026',
        '08.11 2026',
        '2026-11-08',
      ]) {
        expect(parseDocumentDate(input), isNull, reason: input);
      }
      expect(parseDocumentDate('29.02.2028'), DateTime(2028, 2, 29));
      expect(parseDocumentDate('29.02.2026'), isNull);
    },
  );
  test('Parser separates columns, preserves supplier code, prefills receipt without confirming', () {
    final rows = DeliveryTableParser().parse(syntheticTable(), 1100).items;
    expect(rows, hasLength(2));
    expect(rows[0].supplierCode, 'SUP000000');
    expect(rows[0].name, 'Тестово мляко');
    expect(rows[0].ordered, '12');
    expect(rows[0].difference, isEmpty);
    expect(rows[0].unit, 'бройка');
    expect(rows[0].original['unit'], 'бройка');
    expect(rows[0].original['difference'], '-2');
    expect(rows[0].received, '12');
    expect(rows[0].productId, isNull);
    expect(rows[0].checked, isFalse);
    expect(rows[1].uncertainFields, contains('expiry'));
    expect(rows[1].lot, 'N/A');
    expect(rows[1].original['lot'], '1');
    expect(rows[1].uncertainFields, isNot(contains('lot')));
    // Equal names remain separate rows and can describe different batches.
    expect(rows[0].id, isNot(rows[1].id));
  });
  test(
    'Zero receipt is a reviewed non-delivered item, never an active batch',
    () {
      final item = DraftItem(name: 'Тестов продукт', received: '0');
      expect(item.validationErrors, isEmpty);
      item.received = '-1';
      expect(item.validationErrors, isNotEmpty);
      item.received = '10';
      expect(item.validationErrors.join(), contains('продукт от каталога'));
      expect(item.validationErrors.join(), contains('Невалиден срок'));
      expect(parseQuantity('1,5'), 1.5);
      expect(parseQuantity('NaN'), isNull);
      expect(parseQuantity('Infinity'), isNull);
    },
  );
  test('No table produces an explicit note and no invented rows', () {
    final result = DeliveryTableParser().parse([], 1000);
    expect(result.items, isEmpty);
    expect(result.note, contains('не е разпозната'));
  });
  test('Duplicate page is flagged without merging distinct batches', () {
    final first = DraftPage(
      imagePath: 'a',
      items: [for (var i = 0; i < 8; i++) DraftItem(name: 'Мляко вид $i')],
    );
    final second = DraftPage(
      imagePath: 'b',
      items: [for (var i = 0; i < 8; i++) DraftItem(name: 'Мляко вид $i')],
    );
    expect(DeliveryTableParser().mayBeDuplicate(first, second), isTrue);
    expect(first.items, hasLength(8));
    expect(second.items, hasLength(8));
  });
}

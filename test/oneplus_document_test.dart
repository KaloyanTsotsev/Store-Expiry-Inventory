import 'support/legacy_delivery_parser.dart';

import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';

import 'support/tesseract_tsv.dart';
import 'support/structured_document_parser.dart';

import 'package:expiry_tracker/models/delivery_draft.dart';

TesseractTsv readDocument() => TesseractTsv.parse(
  File('test/fixtures/oneplus6/ocr-layout.tsv').readAsStringSync(),
);

void main() {
  test(
    'All four supplied files retain exact bytes and both OCR text baselines',
    () {
      const directory = 'test/fixtures/oneplus6';
      final manifest = jsonDecode(
        File('$directory/manifest.json').readAsStringSync(),
      ) as Map;
      for (final entry in manifest.entries) {
        final bytes = File('$directory/${entry.key}').readAsBytesSync();
        expect(bytes.length, entry.value['bytes']);
        expect(sha256.convert(bytes).toString(), entry.value['sha256']);
      }
      final codePattern = RegExp(r'\b[359]00\d{6}\b');
      final psm6 = File('$directory/ocr-test.txt').readAsStringSync();
      final psm3 = File('$directory/ocr-psm3.txt').readAsStringSync();
      expect(codePattern.allMatches(psm6), hasLength(6));
      expect(codePattern.allMatches(psm3), hasLength(37));
      // Text files are evidence, not a source for invented word coordinates.
      expect(psm3, contains('300003484'));
      expect(psm3, contains('500003936'));
    },
  );
  test(
    'Real TSV decodes 449 words and excludes all empty confidence-95 boxes',
    () {
      final source = File('test/fixtures/oneplus6/ocr-layout.tsv')
          .readAsStringSync();
      final records = source.trimRight().split('\n').skip(1).toList();
      expect(records, hasLength(713));
      final tsv = readDocument();
      expect(tsv.words, hasLength(449));
      expect(tsv.width, 2264);
      expect(tsv.height, 3152);
      expect(tsv.words.every((w) => w.text.trim().isNotEmpty), isTrue);
      final original = records
          .map((r) => r.trimRight().split('\t'))
          .where(
            (c) => c.length >= 12 && c[0] == '5' && c[11].trim().isNotEmpty,
          )
          .toList();
      expect(tsv.words.map((w) => w.text), original.map((c) => c[11]));
      final code = tsv.words.firstWhere((w) => w.text == '900001678');
      expect(code.left, 169);
      expect(code.top, 687);
      expect(code.right, 318);
      expect(code.confidence, closeTo(71.760612, .000001));
    },
  );
  test(
    'Real table retains all 37 article rows including lost first product name',
    () {
      final tsv = readDocument();
      final result = StructuredDocumentParser().parse(tsv.words, tsv.width);
      // Hand checked against the photographed article column. OCR errors and
      // geometric cell noise remain explicit; no guessed 300/500 -> 900 repair.
      const codes = [
        '900001678',
        '900001702',
        '900001713',
        '900001717',
        '900001723',
        '900001730',
        '1 900001731',
        '900001746',
        '900001747',
        '900001762',
        '900001811',
        '900002352',
        '900002446',
        'Ъ 900002450',
        '900003478',
        '300003484',
        '900003583',
        '500003936',
        '900003988',
        '900004987',
        '900004989',
        '900005460',
        '900005601',
        '900005602',
        '900005603',
        '900006151',
        '900006176',
        '900006392',
        '900006610',
        '900006614',
        '900006636',
        '& 900007255',
        '900007257',
        '900008383',
        '900008393',
        '900008397',
        '900008429',
      ];
      expect(result.items.map((i) => i.supplierCode), codes);
      final first = result.items.first;
      expect(first.name, isEmpty);
      expect(first.uncertainFields, contains('name'));
      expect(first.validationErrors, contains('Липсва име на продукта.'));
      expect(first.ordered, '2');
      expect(first.expiry, '10.03.2027');
      expect(first.lot, 'L2');
      expect(result.items.last.supplierCode, '900008429');
      expect(
        result.items.every((i) => !i.checked && !i.proposedNewProduct),
        isTrue,
      );
      expect(result.items.every((i) => i.difference.isEmpty), isTrue);
      final milk = result.items[1];
      expect(milk.name, 'Верея Кисело мляко 4.5%, 400гр');
      expect(milk.received, '12');
      expect(milk.expiry, '08.11.2026');
      expect(milk.lot, 'L08112026');
      expect(milk.original['difference'], '0');
      final damagedQty = result.items.firstWhere(
        (i) => i.supplierCode.contains('900001731'),
      );
      expect(damagedQty.original['ordered'], '2 ”');
      expect(damagedQty.received, isEmpty);
      expect(damagedQty.uncertainFields, contains('ordered'));
      for (final item in result.items) {
        expect(DraftItem.fromJson(item.toJson()).original, item.original);
        if (item.original['expiry'] == '1') {
          expect(parseDocumentDate(item.expiry), isNull);
          expect(item.uncertainFields, contains('expiry'));
        }
        if (item.original['lot'] == '1') {
          expect(item.lot, 'N/A');
          expect(item.uncertainFields, isNot(contains('lot')));
        }
      }
      expect(
        result.items.firstWhere((i) => i.supplierCode == '900001730').expiry,
        '04.052027',
      );
      expect(
        result.items.firstWhere((i) => i.supplierCode == '900008393').expiry,
        '22.12,2026',
      );
      expect(parseDocumentDate('04.052027'), isNull);
      expect(parseDocumentDate('22.12,2026'), isNull);
    },
  );
  test('Blank high-confidence words cannot create or shift table cells', () {
    final tsv = readDocument();
    final parser = StructuredDocumentParser();
    final baseline = parser.parse(tsv.words, tsv.width).items;
    final noisy = parser.parse([
      ...tsv.words,
      const OcrWord('   ', 95, 100, 800, 2200, 2400),
      const OcrWord('', 95, 0, 0, 2264, 3152),
    ], tsv.width).items;
    expect(noisy.map((i) => i.original), baseline.map((i) => i.original));
    expect(
      DeliveryTableParser().parse(tsv.words, tsv.width).items,
      hasLength(37),
    );
  });
}

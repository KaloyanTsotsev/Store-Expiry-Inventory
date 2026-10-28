import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/gtin.dart';
import 'package:expiry_tracker/services/product_matcher.dart';

import 'support/structured_document_parser.dart';

import 'package:expiry_tracker/services/ocr_service.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';
import 'package:expiry_tracker/screens/product_form_screen.dart';
import 'package:expiry_tracker/theme/app_theme.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/delivery_item_screen.dart';
import 'package:expiry_tracker/services/draft_repository.dart';

RecordModel product(
  String id, {
  String name = 'Кисело мляко 3.6% 400 г',
  String barcode = '',
  List<String> aliases = const [],
  List<Map<String, dynamic>> codes = const [],
  bool active = true,
}) => RecordModel.fromJson({
  'id': id,
  'name': name,
  'barcode': barcode,
  'category': 'Млечни',
  'active': active,
  'aliases': aliases,
  'supplier_identifiers': codes,
  'catalog_revision': 3,
});

class _Ocr extends OcrEngine {
  _Ocr({this.fail = false});
  final bool fail;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> recognize(String imagePath) async {
    calls++;
    if (fail) throw StateError('OCR unavailable');
    return {
      'status': 'ok',
      'engine': 'PaddleOCR PP-OCRv5',
      'products': [],
      'words': [],
      'width': 100,
      'height': 100,
      'elapsedMs': 4,
    };
  }
}

class _Catalog extends ProductCatalogService {
  _Catalog({this.manager = true});
  final bool manager;
  Map<String, dynamic>? submitted;
  bool? proposed;
  @override
  bool get canManage => manager;
  @override
  Future<List<RecordModel>> corrections(String productId) async => [];
  @override
  Future<List<RecordModel>> history(String productId) async => [];
  @override
  Future<Map<String, dynamic>> submit(
    Map<String, dynamic> body, {
    required bool proposal,
  }) async {
    submitted = body;
    proposed = proposal;
    return {
      'status': proposal ? 'pending' : 'saved',
      'product': {'id': body['product_id']},
    };
  }
}

class _Drafts extends DraftRepository {
  @override
  Future<void> save(DeliveryDraft draft) async {}
}

void main() {
  test('Verified supplier code uses catalog name and keeps physical checks and raw OCR', () {
    final p = product(
      'p',
      codes: [
        {'supplier': 'А', 'code': '900001678', 'verified': true},
      ],
    );
    final item = DraftItem(
      name: 'млЯк0',
      supplierCode: '900001678',
      received: '6',
      expiry: '1',
      lot: '1',
      original: {'name': 'млЯк0', 'lot': '1'},
    );
    ProductMatcher.prepare(item, [p], 'А');
    expect(item.name, p.data['name']);
    expect(item.original['name'], 'млЯк0');
    expect(item.productId, 'p');
    expect(item.checked, isFalse);
    expect(item.lot, 'N/A');
    expect(item.validationErrors, isNotEmpty);
    final restored = DraftItem.fromJson(item.toJson());
    expect(restored.original, item.original);
    for (final prefix in ['300', '500']) {
      final wrong = DraftItem(
        name: p.data['name'],
        supplierCode: '${prefix}001678',
      );
      ProductMatcher.prepare(wrong, [p], 'А');
      expect(wrong.productId, isNull);
      expect(wrong.proposedNewProduct, isFalse);
      expect(wrong.supplierCode, '${prefix}001678');
    }
    final unknown = DraftItem(name: 'нечетливо име', uncertainFields: ['name']);
    ProductMatcher.prepare(unknown, [p], 'А');
    expect(unknown.proposedNewProduct, isFalse);
  });
  test('Optional row readings survive draft persistence without replacing original TSV', () {
    final page = DraftPage(
      imagePath: 'photo.jpg',
      text: '300001678',
      refinements: [
        {
          'text': '900001678',
          'requiresReview': true,
          'box': [0, 10, 100, 30],
        },
      ],
    );
    final restored = DraftPage.fromJson(page.toJson());
    expect(restored.text, '300001678');
    expect(restored.refinements.single['text'], '900001678');
    expect(restored.refinements.single['requiresReview'], isTrue);
  });
  testWidgets(
    'Alternative row readings are visible for review without marking products checked',
    (tester) async {
      final page = DraftPage(
        imagePath: 'missing-test-photo.jpg',
        recognized: true,
        refinements: [
          {
            'text': '900001678 Мляко',
            'box': [0, 10, 100, 30],
          },
        ],
      );
      final draft = DeliveryDraft(ownerId: 'test', pages: [page]);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            engine: _Ocr(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = find.text(
        'Алтернативни OCR прочити — проверете по снимката',
      );
      await tester.scrollUntilVisible(
        title,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.text('900001678 Мляко'), findsOneWidget);
      expect(draft.allReviewed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Catalog editor adapts to 320px and 200 percent text in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: ProductFormScreen(
                product: product(
                  'long',
                  name: 'Дълго продуктово име с марка и разфасовка',
                ),
                catalog: _Catalog(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Запази продукта'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'OCR failure permits explicit manual processing on the same original photo',
    (tester) async {
      final photo = DraftPage(
        imagePath: 'missing-test-photo.jpg',
        error: 'OCR unavailable',
      );
      final draft = DeliveryDraft(ownerId: 'test', pages: [photo]);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            engine: _Ocr(fail: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final manual = find.text('Въведи ръчно за тази страница');
      await tester.scrollUntilVisible(
        manual,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(manual);
      await tester.pumpAndSettle();
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(find.byType(DeliveryItemScreen), findsOneWidget);
      expect(draft.pages, hasLength(1));
      expect(photo.imagePath, 'missing-test-photo.jpg');
      expect(photo.recognized, isTrue);
      expect(photo.error, isNull);
      expect(photo.items.single.expiry, isEmpty);
      expect(photo.items.single.received, isEmpty);
      expect(draft.allReviewed, isFalse);
      expect(photo.layoutNote, contains('Ръчно'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('GTIN uses exact digits and checksum; supplier articles never become barcode', () {
    for (final code in [
      '4006381333931',
      '96385074',
      '036000291452',
      '00036000291452',
    ]) {
      expect(gtinKey(code), isNotNull, reason: code);
    }
    for (final code in [
      '90001',
      '4006381333932',
      '4OO6381333931',
      '',
      '1234567',
    ]) {
      expect(gtinKey(code), isNull, reason: code);
    }
    final p = product('p', barcode: '4006381333931');
    expect(
      ProductMatcher.match(
        DraftItem(name: 'Съвсем различно', supplierCode: '4006381333931'),
        [p],
        'Доставчик',
      ).automatic,
      isFalse,
    );
    expect(
      ProductMatcher.match(
        DraftItem(name: 'OCR грешка', barcode: '4006381333931'),
        [p],
        '',
      ).products.single.id,
      'p',
    );
  });
  test('Verified supplier code is scoped and takes priority over names', () {
    final p = product(
      'p',
      codes: [
        {'supplier': 'Доставчик А', 'code': '00012', 'verified': true},
      ],
    );
    final other = product('other', name: 'OCR име');
    final item = DraftItem(name: 'OCR име', supplierCode: '00012');
    expect(
      ProductMatcher.match(item, [p, other], 'Доставчик А').products.single.id,
      'p',
    );
    expect(ProductMatcher.match(item, [p], 'Доставчик Б').automatic, isFalse);
    expect(
      ProductMatcher.match(item, [
        product(
          'u',
          codes: [
            {'supplier': 'Доставчик А', 'code': '00012', 'verified': false},
          ],
        ),
      ], 'Доставчик А').automatic,
      isFalse,
    );
  });
  test('Conflicting barcode, supplier code, aliases and inactive identifiers stop automatic matching', () {
    final a = product(
      'a',
      barcode: '4006381333931',
      aliases: ['КИС МЛ 3.6 400'],
    );
    final b = product(
      'b',
      name: 'Друг',
      barcode: '4006381333931',
      codes: [
        {'supplier': 'А', 'code': '1', 'verified': true},
      ],
      aliases: ['КИС МЛ 3.6 400'],
    );
    expect(
      ProductMatcher.match(DraftItem(barcode: '4006381333931'), [
        a,
        b,
      ], '').conflict,
      isTrue,
    );
    expect(
      ProductMatcher.match(
        DraftItem(barcode: '4006381333931', supplierCode: '1'),
        [
          a,
          product(
            'b',
            name: 'Друг',
            codes: [
              {'supplier': 'А', 'code': '1', 'verified': true},
            ],
          ),
        ],
        'А',
      ).conflict,
      isTrue,
    );
    expect(
      ProductMatcher.match(DraftItem(name: 'КИС МЛ 3.6 400'), [
        a,
        b,
      ], '').conflict,
      isTrue,
    );
    expect(
      ProductMatcher.match(DraftItem(barcode: '4006381333931'), [
        product('inactive', barcode: '4006381333931', active: false),
      ], '').conflict,
      isTrue,
    );
    expect(
      ProductMatcher.match(
        DraftItem(name: a.data['name'], barcode: '96385074'),
        [a],
        '',
      ).conflict,
      isTrue,
    );
  });
  test('Bulgarian English, abbreviations and OCR typos are suggestions until alias approval', () {
    for (final pair in [
      ('КИС МЛ 3.6 400', 'Кисело мляко 3.6% 400 г'),
      ('Kinder Pingul Milk', 'Kinder Pingui Milk'),
      ('Кисело мляк0 400 г', 'Кисело мляко 400 г'),
    ]) {
      final item = DraftItem(name: pair.$1);
      final p = product('p', name: pair.$2);
      final result = ProductMatcher.match(item, [p], '');
      expect(result.products.single.id, 'p');
      expect(result.automatic, isFalse);
      final learned = product('p', name: pair.$2, aliases: [pair.$1]);
      expect(ProductMatcher.match(item, [learned], '').automatic, isTrue);
    }
  });
  test('Manual catalog ID survives OCR text correction and draft roundtrip without rewriting original', () {
    final item = DraftItem(
      name: 'OCR име',
      productId: 'p',
      productSelectionConfirmed: true,
      checked: true,
      original: {'name': 'OCR име'},
    );
    item.edit('name', 'Корекция');
    expect(item.productId, 'p');
    expect(item.checked, isFalse);
    final reopened = DraftItem.fromJson(item.toJson());
    ProductMatcher.prepare(reopened, [product('p')], '');
    expect(reopened.productId, 'p');
    expect(reopened.original['name'], 'OCR име');
  });
  test('Generic invoice columns preserve only observed values and invalid expiry remains unconfirmed', () {
    final words = <OcrWord>[];
    final headings = [
      'Код',
      'Наименование',
      'Баркод',
      'Количество',
      'Мярка',
      'Годност',
      'Партида',
    ];
    final columns = [10.0, 150.0, 400.0, 580.0, 690.0, 780.0, 920.0];
    for (var i = 0; i < headings.length; i++) {
      words.add(OcrWord(headings[i], 99, columns[i], 10, columns[i] + 70, 30));
    }
    for (var row = 0; row < 2; row++) {
      final values = [
        '00012',
        'Kinder Мляко',
        row == 0 ? '4006381333931' : '4OO6381333931',
        row == 0 ? '6' : '?',
        'бр.',
        row == 0 ? '08.11.2026' : '31.02.2026',
        '1',
      ];
      for (var i = 0; i < values.length; i++) {
        words.add(
          OcrWord(
            values[i],
            95,
            columns[i],
            70 + row * 40,
            columns[i] + 70,
            90 + row * 40,
          ),
        );
      }
    }
    final rows = StructuredDocumentParser().parse(words, 1100).items;
    expect(rows, hasLength(2));
    expect(rows.first.barcode, '4006381333931');
    expect(rows.first.unit, 'бр.');
    expect(rows.first.supplierCode, '00012');
    expect(rows.first.checked, isFalse);
    expect(rows.last.barcode, isEmpty);
    expect(rows.last.ordered, isEmpty);
    expect(rows.last.expiry, isEmpty);
    expect(rows.last.original['expiry'], '31.02.2026');
    expect(rows.last.validationErrors, isNotEmpty);
    expect(rows.last.lot, 'N/A');
  });
  for (final manager in [true, false]) {
    testWidgets(
      'Existing product ${manager ? 'edit' : 'proposal'} retains ID and routes through catalog role API',
      (tester) async {
        final api = _Catalog(manager: manager), p = product('stable');
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProductFormScreen(product: p, catalog: api),
                    ),
                  ),
                  child: const Text('Отвори'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Отвори'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).first,
          'Коригирано мляко',
        );
        final save = find.text(
          manager ? 'Запази продукта' : 'Изпрати предложение',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(api.submitted!['product_id'], 'stable');
        expect(api.submitted!['expected_revision'], 3);
        expect(api.proposed, !manager);
        expect(api.submitted!['fields']['name'], 'Коригирано мляко');
        expect(find.text('Отвори'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'Catalog blocks duplicate names and invalid GTIN without sending writes',
    (tester) async {
      final api = _Catalog();
      await tester.pumpWidget(
        MaterialApp(
          home: ProductFormScreen(
            catalog: api,
            products: [product('existing')],
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextFormField).first,
        'Кисело мляко 3.6% 400 г',
      );
      await tester.ensureVisible(find.text('Запази продукта'));
      await tester.tap(find.text('Запази продукта'));
      await tester.pumpAndSettle();
      expect(api.submitted, isNull);
      expect(find.textContaining('Възможен дубликат:'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextFormField).at(1));
      await tester.enterText(find.byType(TextFormField).at(1), '90001');
      await tester.ensureVisible(find.text('Запази продукта'));
      await tester.tap(find.text('Запази продукта'));
      await tester.pumpAndSettle();
      expect(api.submitted, isNull);
      expect(find.text('Невалиден GTIN-8/12/13/14'), findsOneWidget);
    },
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/login_screen.dart';
import 'package:expiry_tracker/screens/products_screen.dart';
import 'package:expiry_tracker/screens/product_form_screen.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/paddle_document_adapter.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';
import 'package:expiry_tracker/services/product_matcher.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/theme/app_theme.dart';

class _Catalog extends ProductCatalogService {
  _Catalog(this.access);
  final CatalogAccess access;
  int writes = 0;
  @override
  bool get canManage => access.canCreate;
  @override
  Future<bool> available() async => access.available;
  @override
  Future<CatalogAccess> probe() async => access;
  @override
  Future<Map<String, dynamic>> submit(
    Map<String, dynamic> body, {
    required bool proposal,
  }) async {
    writes++;
    return {
      'status': 'saved',
      'product': {'id': 'cat000000000001', ...body['fields'] as Map},
    };
  }
}

class _Drafts extends DraftRepository {
  @override
  Future<void> save(DeliveryDraft draft) async {}
}

DraftItem row() => DraftItem(
  name: 'OCR мляко',
  supplierCode: '900001702',
  ordered: '12',
  received: '12',
  requiresCatalogIdentity: true,
  expiry: '08.11.2026',
);
const ready = CatalogAccess(available: true, canCreate: true);

class _BulkFinalizer implements DeliveryFinalizer {
  int prepares = 0, commits = 0;
  Map<String, dynamic>? packet;
  @override
  bool get available => true;
  @override
  Future<void> prepare(
    DeliveryDraft draft,
    Future<void> Function() persist,
  ) async {
    prepares++;
    expect(draft.allReviewed, isTrue);
    draft.serverId = 'bulkdelivery';
    draft.serverRevision = 1;
    await persist();
  }

  @override
  Future<Map<String, dynamic>> finalize(
    String id,
    Map<String, dynamic> request,
  ) async {
    commits++;
    packet = request;
    return {
      'delivery_id': id,
      'revision': 2,
      'status': 'finalized',
      'lines': [],
    };
  }
}

void main() {
  testWidgets(
    'Employee checks 37 new OCR rows and confirms once; no per-product writes or dialogs',
    (tester) async {
      final finalizer = _BulkFinalizer();
      final rows = [
        for (var i = 0; i < 37; i++)
          row()
            ..supplierCode = '000$i'
            ..name = 'Нов продукт $i',
      ];
      final draft = DeliveryDraft(
        ownerId: 'test',
        supplier: 'А',
        pages: [
          DraftPage(
            imagePath: '',
            recognized: true,
            items: rows.take(20).toList(),
          ),
          DraftPage(
            imagePath: '',
            recognized: true,
            items: rows.skip(20).toList(),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            catalogLoader: () async => [],
            finalizer: finalizer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        rows.every(
          (i) => i.articleBarcode && i.productId == null && !i.checked,
        ),
        isTrue,
      );
      expect(find.text('Добави в каталога'), findsNothing);
      expect(find.text('Избери всички'), findsNothing);
      expect(draft.readyCount, 37);
      expect(finalizer.commits, 0);
      await tester.tap(find.text('Запази доставката'));
      await tester.pumpAndSettle();
      expect(finalizer.commits, 1);
      expect(finalizer.packet!['finalize_by_code'], isTrue);
      expect(finalizer.packet!.containsKey('catalog_confirmed'), isFalse);
      expect(
        (finalizer.packet!['lines'] as List).first['supplier_code'],
        '0000',
      );
      expect(finalizer.packet!['lines'], hasLength(37));
      expect(draft.status, 'finalized');
      expect(tester.takeException(), isNull);
    },
  );
  test('Bulk eligibility does not waive physical validation, conflicts or pending requests', () {
    final item = row()..catalogOnFinalize = true;
    ProductMatcher.prepare(item, [], 'А');
    expect(item.validationErrors, isEmpty);
    expect(item.checked, isFalse);
    item.expiry = '1';
    expect(item.validationErrors, isNotEmpty);
    item.expiry = '08.11.2026';
    item.proposedNewProduct = false;
    expect(item.validationErrors, isNotEmpty);
    item.proposedNewProduct = true;
    item.supplierCode = '';
    expect(item.validationErrors, isNotEmpty);
  });

  testWidgets(
    'Catalog list edits the selected stable ID instead of opening a blank create form',
    (tester) async {
      final p = RecordModel.fromJson({
        'id': 'stable-id',
        'name': 'Познат продукт',
        'active': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ProductsScreen(
            catalog: _Catalog(ready),
            loader: () async => [p],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Познат продукт'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProductFormScreen>(find.byType(ProductFormScreen))
            .product
            ?.id,
        'stable-id',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('New OCR code can be reviewed without a supplier or approval', (
    tester,
  ) async {
    final item = row();
    final draft = DeliveryDraft(
      ownerId: 'test',
      pages: [
        DraftPage(imagePath: '', recognized: true, items: [item]),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DeliveryEditorScreen(
          draft: draft,
          repository: _Drafts(),
          catalogLoader: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Нов продукт'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Чака управител'), findsNothing);
    expect(find.text('Добави в каталога'), findsNothing);
    expect(item.articleBarcode, isTrue);
    expect(item.proposedNewProduct, isTrue);
    expect(item.validationErrors, isEmpty);
    expect(item.checked, isFalse);
  });
  testWidgets(
    'Existing barcode is recognized inline; select and deselect work',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final item = row();
      final p = RecordModel.fromJson({
        'id': 'p',
        'name': 'Каталожно име',
        'barcode': '900001702',
        'active': true,
        'supplier_identifiers': [
          {'supplier': 'А', 'code': '900001702', 'verified': true},
        ],
      });
      final draft = DeliveryDraft(
        ownerId: 'test',
        supplier: 'А',
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [item]),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            catalogLoader: () async => [p],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Избери всички'), findsNothing);
      expect(item.ready, isTrue);
      expect(item.checked, isFalse);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('finish-delivery')))
            .onPressed,
        isNotNull,
      );
      await tester.scrollUntilVisible(
        find.text('Разпознат продукт'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(item.productId, 'p');
      expect(item.name, 'Каталожно име');
      expect(find.text('Необходим е избор на продукт'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test('Real 37-row document retains separate quantities; missing backend never creates stock', () {
    final data = jsonDecode(
      File('test/fixtures/paddle/http-test-v2.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = PaddleDocumentAdapter().parse(data).items;
    for (final item in rows) {
      ProductMatcher.prepare(item, [], 'А');
    }
    expect(rows, hasLength(37));
    expect(rows.every((i) => i.received == i.ordered && !i.checked), isTrue);
    expect(rows.every((i) => i.productId == null), isTrue);
  });
  testWidgets(
    'StoreFlow login stays readable in both themes at 320px and 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness),
            home: const MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2)),
              child: LoginScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Вход'));
        expect(find.text('StoreFlow'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}

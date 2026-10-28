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
import 'package:expiry_tracker/services/delivery_row_status.dart';
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
const missing = CatalogAccess(
  available: false,
  statusCode: 404,
  message: 'Каталог V3 не е внедрен (HTTP 404). Нужно е одобрено внедряване от управител.',
);

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
      final catalog = _Catalog(
        const CatalogAccess(available: true, canFinalizeDelivery: true),
      );
      final finalizer = _BulkFinalizer();
      final rows = [
        for (var i = 0; i < 37; i++)
          row()
            ..supplierCode = 'CODE$i'
            ..name = 'Нов продукт $i',
      ];
      final draft = DeliveryDraft(
        ownerId: 'test',
        supplier: 'А',
        pages: [DraftPage(imagePath: '', recognized: true, items: rows)],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            catalog: catalog,
            catalogLoader: () async => [],
            finalizer: finalizer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        rows.every(
          (i) => i.catalogOnFinalize && i.productId == null && !i.checked,
        ),
        isTrue,
      );
      expect(find.text('Добави в каталога'), findsNothing);
      final mark = find.widgetWithText(
        FilledButton,
        'Маркирай всички — проверени',
      );
      await tester.scrollUntilVisible(
        mark,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(mark);
      await tester.pumpAndSettle();
      final check = find.byType(CheckboxListTile).last;
      await tester.tap(check);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Потвърди всички'));
      await tester.pumpAndSettle();
      expect(draft.checkedCount, 37);
      expect(catalog.writes, 0);
      expect(finalizer.commits, 0);
      await tester.tap(find.text('Приключи доставката'));
      await tester.pumpAndSettle();
      expect(find.text('Приключване на доставката'), findsOneWidget);
      expect(finalizer.commits, 0);
      await tester.tap(find.text('Потвърди и приключи'));
      await tester.pumpAndSettle();
      expect(finalizer.commits, 1);
      expect(finalizer.packet!['catalog_confirmed'], isTrue);
      expect(finalizer.packet!['lines'], hasLength(37));
      expect(catalog.writes, 0);
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
  test('Statuses distinguish missing supplier, absent backend, employee and ready manager', () {
    final item = row();
    ProductMatcher.prepare(item, [], 'А');
    expect(
      DeliveryRowStatus.resolve(item, '', true, ready).label,
      'Нужна корекция',
    );
    expect(
      DeliveryRowStatus.resolve(item, 'А', true, missing).label,
      'Чака управител',
    );
    expect(
      DeliveryRowStatus.resolve(
        item,
        'А',
        true,
        const CatalogAccess(available: true),
      ).canAdd,
      isFalse,
    );
    expect(
      DeliveryRowStatus.resolve(item, 'А', true, ready).label,
      'Нов продукт',
    );
    expect(DeliveryRowStatus.resolve(item, 'А', true, ready).canAdd, isTrue);
    final p = RecordModel.fromJson({
      'id': 'p',
      'name': 'Каталожно име',
      'active': true,
      'supplier_identifiers': [
        {'supplier': 'А', 'code': '900001702', 'verified': true},
      ],
    });
    ProductMatcher.prepare(item, [p], 'А');
    expect(
      DeliveryRowStatus.resolve(item, 'А', true, missing).label,
      'Разпознат продукт',
    );
    expect(item.received, '12');
    expect(item.checked, isFalse);
  });
  for (final access in [
    ready,
    missing,
    const CatalogAccess(available: true, message: 'Чака управител'),
  ]) {
    testWidgets(
      'Inline OCR row works without picker; available=${access.available}, create=${access.canCreate}',
      (tester) async {
        final item = row();
        final catalog = _Catalog(access);
        final draft = DeliveryDraft(
          ownerId: 'test',
          supplier: 'А',
          pages: [
            DraftPage(imagePath: '', recognized: true, items: [item]),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: DeliveryEditorScreen(
              draft: draft,
              repository: _Drafts(),
              catalog: catalog,
              catalogLoader: () async => [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final status = find.text(
          access.canCreate ? 'Нов продукт' : 'Чака управител',
        );
        await tester.scrollUntilVisible(
          status,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Необходим е избор на продукт'), findsNothing);
        expect(find.text('Продукт / още'), findsNothing);
        final received = find.byKey(ValueKey('${item.id}_received'));
        await tester.scrollUntilVisible(
          received,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(received);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(received).controller!.text, '12');
        expect(item.received, '12');
        expect(item.checked, isFalse);
        if (access.canCreate) {
          await tester.scrollUntilVisible(
            find.text('Добави в каталога'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(find.text('Добави в каталога'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Добави в каталога'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(catalog.writes, 0);
          await tester.tap(find.text('Потвърди добавянето'));
          await tester.pumpAndSettle();
          expect(catalog.writes, 1);
          expect(item.productId, 'cat000000000001');
          expect(item.checked, isFalse);
        } else {
          expect(find.text('Добави в каталога'), findsNothing);
          expect(catalog.writes, 0);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Existing supplier code is recognized inline; mark-all is a visible Material button',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final item = row();
      final p = RecordModel.fromJson({
        'id': 'p',
        'name': 'Каталожно име',
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
            catalog: _Catalog(ready),
            catalogLoader: () async => [p],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mark = find.widgetWithText(
        FilledButton,
        'Маркирай всички — проверени',
      );
      await tester.scrollUntilVisible(
        mark,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(mark).onPressed, isNotNull);
      expect(tester.getSize(mark).height, greaterThanOrEqualTo(48));
      await tester.tap(mark);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Потвърди всички'),
            )
            .onPressed,
        isNull,
      );
      expect(item.checked, isFalse);
      await tester.tap(find.text('Отказ'));
      await tester.pumpAndSettle();
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
    expect(
      rows.every(
        (i) => !DeliveryRowStatus.resolve(i, 'А', true, missing).canAdd,
      ),
      isTrue,
    );
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

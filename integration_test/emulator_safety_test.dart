import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/main.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/product_form_screen.dart';
import 'package:expiry_tracker/screens/products_screen.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/widgets/expiry_dashboard.dart';
import 'package:expiry_tracker/theme/app_theme.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const boundary = Key('safety-preview');
  final checks = <String>[];
  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
        .toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/emulator_report',
    );
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
  }

  void passed(String name) {
    checks.add(name);
    debugPrint('EMULATOR SAFETY PASS: $name');
  }

  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          key: UniqueKey(),
          theme: AppTheme.build(Brightness.dark),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(target), alignment: .25);
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (ready()) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Timed out waiting for server-backed UI state');
  }

  testWidgets(
    'Expiry handling, rollback, deletion safety and themes on emulator',
    (tester) async {
      final pb = PocketBaseService.pb;
      if (pb.baseURL != 'http://127.0.0.1:18090' ||
          !const bool.fromEnvironment('OCR_TEST_APP')) {
        throw StateError('Isolated emulator only');
      }
      await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
      final owner = pb.authStore.record!.id, repo = DraftRepository();
      final product =
          (await pb
                  .collection('products')
                  .getFullList(
                    filter: pb.filter('barcode={:code}', {
                      'code': 'MD-Overdue',
                    }),
                  ))
              .single;
      var old =
          (await pb
                  .collection('batches')
                  .getFullList(
                    filter: pb.filter('product={:id}', {'id': product.id}),
                  ))
              .where(
                (b) =>
                    b.getStringValue('status') == 'active' &&
                    DateTime.parse(b.getStringValue('expiry_date'))
                        .isBefore(DateTime.now()),
              )
              .firstOrNull;
      if (old == null) {
        final seed = DeliveryDraft(
          ownerId: owner,
          pages: [
            DraftPage(
              imagePath: '',
              recognized: true,
              items: [
                DraftItem(
                  name: product.getStringValue('name'),
                  supplierCode: product.getStringValue('barcode'),
                  productId: product.id,
                  articleBarcode: true,
                  received: '3',
                  expiry: formatDocumentDate(
                    DateTime.now().subtract(const Duration(days: 1)),
                  ),
                  checked: true,
                ),
              ],
            ),
          ],
        );
        final seeder = PocketBaseDeliveryFinalizer();
        await seeder.probe();
        await seeder.prepare(seed, () => repo.save(seed));
        final seeded = await seeder.finalize(seed.serverId!, {
          ...DeliveryFinalization.request(seed),
          'finalize_by_code': true,
        });
        old = await pb
            .collection('batches')
            .getOne((seeded['lines'] as List).single['batch_id'] as String);
      }
      final expiredId = old.id;
      final future = DeliveryDraft(
        ownerId: owner,
        pages: [
          DraftPage(
            imagePath: '',
            recognized: true,
            items: [
              DraftItem(
                name: product.getStringValue('name'),
                supplierCode: product.getStringValue('barcode'),
                productId: product.id,
                articleBarcode: true,
                received: '3',
                expiry: formatDocumentDate(
                  DateTime.now().add(const Duration(days: 20)),
                ),
                checked: true,
              ),
            ],
          ),
        ],
      );
      final client = PocketBaseDeliveryFinalizer();
      await client.probe();
      await client.prepare(future, () => repo.save(future));
      final packet = {
        ...DeliveryFinalization.request(future),
        'finalize_by_code': true,
      };
      final receipt = await client.finalize(future.serverId!, packet);
      final newId = (receipt['lines'] as List).single['batch_id'];
      final movementsBefore =
          (await pb.collection('stock_movements').getFullList()).length;
      await show(
        tester,
        Scaffold(
          body: ExpiryDashboard(ownerId: owner, employeeName: 'Тест служител'),
        ),
      );
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Търси продукт',
      );
      await tester.enterText(search, 'Overdue');
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final remove = find.widgetWithText(TextButton, 'Премахни от списъка');
      await reveal(tester, remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отказ'));
      await tester.pumpAndSettle();
      expect(
        (await pb.collection('batches').getOne(expiredId))
            .getStringValue('status'),
        'active',
      );
      await reveal(tester, remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Потвърди'));
      await tester.pumpAndSettle();
      await expectLater(
        pb.collection('batches').getOne(expiredId),
        throwsA(
          isA<ClientException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      expect(
        (await pb.collection('batches').getOne(newId as String))
            .getStringValue('status'),
        'active',
      );
      expect(
        (await pb.collection('stock_movements').getFullList()).length,
        movementsBefore,
      );
      expect(
        (await pb.collection('products').getOne(product.id))
            .getStringValue('barcode'),
        'MD-Overdue',
      );
      await PocketBaseService.login('manager', 'synthetic-test-only-40.4!');
      final fromOtherSession = await PocketBaseService.getExpiryBatches();
      expect(fromOtherSession.any((b) => b.id == expiredId), isFalse);
      expect(fromOtherSession.any((b) => b.id == newId), isTrue);
      passed(
        'Expired handling: cancel does nothing; confirm hides only selected batch across sessions; product, other expiry and movements preserved',
      );
      await shot(tester, '08-expiry-handled');

      await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
      final faultCode = 'EMU-FAULT-${DateTime.now().millisecondsSinceEpoch}';
      final fault = DeliveryDraft(
        ownerId: owner,
        pages: [
          DraftPage(
            imagePath: '',
            recognized: true,
            items: [
              DraftItem(
                name: 'Контролиран rollback',
                supplierCode: faultCode,
                received: '13',
                articleBarcode: true,
                proposedNewProduct: true,
                expiry: formatDocumentDate(
                  DateTime.now().add(const Duration(days: 30)),
                ),
              ),
            ],
          ),
        ],
      );
      await repo.save(fault);
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DeliveryEditorScreen(draft: fault, repository: repo),
                ),
              ),
              child: const Text('Rollback тест'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Rollback тест'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finish-delivery')));
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () =>
            fault.finalizationRequest != null &&
            tester
                    .widget<FilledButton>(
                      find.byKey(const Key('finish-delivery')),
                    )
                    .onPressed !=
                null,
      );
      expect(fault.status, 'draft');
      expect(fault.finalizationReceipt, isNull);
      expect(fault.finalizationRequest, isNotNull);
      expect(
        await pb
            .collection('products')
            .getFullList(
              filter: pb.filter('barcode={:code}', {'code': faultCode}),
            ),
        isEmpty,
      );
      expect(
        await pb
            .collection('batches')
            .getFullList(
              filter: pb.filter('delivery={:id}', {'id': fault.serverId}),
            ),
        isEmpty,
      );
      expect((await repo.load(owner, fault.id)).items.single.received, '13');
      await shot(tester, '09-transaction-rollback');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final delete = find.widgetWithText(TextButton, 'Изтрий чернова');
      await reveal(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Потвърди'));
      await tester.pumpAndSettle();
      expect((await repo.list(owner)).any((d) => d.id == fault.id), isFalse);
      passed(
        'Injected receipt failure rolls back all inventory, shows an error and keeps frozen draft; confirmed discard deletes unfinished server/local draft safely',
      );

      await PocketBaseService.login('manager', 'synthetic-test-only-40.4!');
      await show(tester, const ProductsScreen());
      final productSearch = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'Търси име или баркод',
      );
      await tester.enterText(productSearch, 'MD-Overdue');
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () => find
            .widgetWithText(ListTile, product.getStringValue('name'))
            .evaluate()
            .isNotEmpty,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, product.getStringValue('name')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormScreen), findsOneWidget);
      final deleteProduct = find.text('Изтрий продукт');
      await waitFor(tester, () => deleteProduct.evaluate().isNotEmpty);
      await reveal(tester, deleteProduct);
      await tester.tap(deleteProduct);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Изтрий'));
      await tester.pumpAndSettle();
      expect(
        (await pb.collection('products').getOne(product.id)).id,
        product.id,
      );
      await waitFor(
        tester,
        () => find
            .textContaining('Не може да бъде изтрит.')
            .evaluate()
            .isNotEmpty,
      );
      await shot(tester, '10-unsafe-delete-blocked');
      passed(
        'Deleting a product with inventory/history is refused without cascade deletion',
      );

      await tester.pumpWidget(
        const RepaintBoundary(key: boundary, child: MyApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ThemeMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Светла'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(TextField).first)).brightness,
        Brightness.light,
      );
      await shot(tester, '11-light-theme');
      await tester.tap(find.byType(ThemeMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Тъмна'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(TextField).first)).brightness,
        Brightness.dark,
      );
      await shot(tester, '12-dark-theme');
      passed(
        'Real Android light/dark theme switching and readable StoreFlow login',
      );
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/emulator_report',
      );
      await File('${dir.path}/safety.json').writeAsString(
        jsonEncode({'checks': checks, 'production_contacted': false}),
      );
      binding.reportData = {'checks': checks, 'production_contacted': false};
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:expiry_tracker/main.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/home_screen.dart';
import 'package:expiry_tracker/screens/products_screen.dart';
import 'package:expiry_tracker/screens/product_form_screen.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/deliveries_screen.dart';
import 'package:expiry_tracker/screens/known_product_batch_screen.dart';
import 'package:expiry_tracker/services/page_capture_service.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/theme/app_theme.dart';
import 'package:expiry_tracker/widgets/expiry_date_field.dart';

class _RecordedDocument implements PageCapture {
  _RecordedDocument(this.path);
  final String path;
  @override
  Future<List<XFile>> camera() async => [XFile(path)];
  @override
  Future<List<XFile>> gallery({required bool multiple}) async => [XFile(path)];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const boundary = Key('emulator-preview');
  final checks = <String>[];
  Future<void> reveal(WidgetTester tester, Finder field) async {
    await tester.scrollUntilVisible(
      field,
      400,
      maxScrolls: 200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(field),
      alignment: .25,
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 15 && field.hitTestable().evaluate().isEmpty; i++) {
      final center = tester.getCenter(field);
      await tester.drag(
        find.byType(ListView).first,
        Offset(0, center.dy < 150 ? 250 : -250),
      );
      await tester.pumpAndSettle();
    }
    expect(field.hitTestable(), findsOneWidget);
  }

  Future<void> edit(WidgetTester tester, Finder field, String text) async {
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Future<void> tapButton(WidgetTester tester, Finder button) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String label,
  ) async {
    for (var i = 0; i < 450; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (ready()) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Timed out waiting for $label');
  }

  Future<void> preview(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final render = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundary),
    );
    final picture = await render.toImage(pixelRatio: 1.5);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/emulator_report',
    );
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  }

  void passed(String name) {
    checks.add(name);
    debugPrint('EMULATOR PASS: $name');
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

  Finder textField(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );

  testWidgets('Isolated emulator app acceptance', (tester) async {
    final pb = PocketBaseService.pb;
    final runId = DateTime.now().millisecondsSinceEpoch.toString();
    final newCode = '000-EMU-$runId';
    final newName = 'Емулатор продукт $runId';
    if (pb.baseURL != 'http://127.0.0.1:18090' ||
        !const bool.fromEnvironment('OCR_TEST_APP')) {
      throw StateError(
        'Only a separately identified emulator app and isolated reversed backend are allowed',
      );
    }
    await tester.pumpWidget(
      const RepaintBoundary(key: boundary, child: MyApp()),
    );
    await tester.pumpAndSettle();
    await preview(tester, '01-login');
    await edit(tester, textField('Потребителско име'), 'owner');
    await tester.pumpAndSettle();
    await edit(tester, textField('Парола'), 'wrong-synthetic-password');
    await tester.pumpAndSettle();
    await tapButton(tester, find.widgetWithText(FilledButton, 'Вход'));
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => find.textContaining('Неуспешен вход').evaluate().isNotEmpty,
      'invalid login response',
    );
    expect(pb.authStore.isValid, isFalse);
    await edit(tester, textField('Парола'), 'synthetic-test-only-40.4!');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(textField('Потребителско име')).controller!.text,
      'owner',
    );
    expect(
      tester.widget<TextField>(textField('Парола')).controller!.text,
      'synthetic-test-only-40.4!',
    );
    await preview(tester, '01b-login-retry');
    await tapButton(tester, find.widgetWithText(FilledButton, 'Вход'));
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => find.byType(HomeScreen).evaluate().isNotEmpty,
      'employee home',
    );
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(pb.authStore.record!.id, 'emp000000000001');
    passed(
      'Actual login: invalid credentials rejected; employee authenticated',
    );
    await preview(tester, '02-dashboard');

    await PocketBaseService.login('manager', 'synthetic-test-only-40.4!');
    await show(tester, const ProductsScreen());
    await tester.tap(find.text('Нов продукт'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductFormScreen), findsOneWidget);
    await edit(tester, find.byType(TextFormField).at(0), newName);
    await tester.pumpAndSettle();
    await edit(tester, find.byType(TextFormField).at(1), newCode);
    await tester.pumpAndSettle();
    await edit(tester, find.byType(TextFormField).at(2), 'Млечни');
    await tester.pumpAndSettle();
    await preview(tester, '03-product-form');
    await tester.ensureVisible(find.text('Запази продукта'));
    await tester.tap(find.text('Запази продукта'));
    await tester.pumpAndSettle();
    final created = await pb
        .collection('products')
        .getFullList(filter: pb.filter('barcode={:code}', {'code': newCode}));
    expect(created, hasLength(1));
    expect(created.single.getStringValue('name'), newName);
    passed(
      'Manager minimal product form: real catalog persistence and exact code with leading zeroes',
    );

    await PocketBaseService.login('owner', 'synthetic-test-only-40.4!');
    final owner = pb.authStore.record!.id;
    final repository = DraftRepository();
    final imageResponse = await http.get(
      Uri.parse('http://127.0.0.1:18765/document.jpg'),
    );
    expect(imageResponse.statusCode, 200);
    final photo = File(
      '${(await getTemporaryDirectory()).path}/emulator-document.jpg',
    );
    await photo.writeAsBytes(imageResponse.bodyBytes);
    final draft = DeliveryDraft(ownerId: owner);
    await repository.save(draft);
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryEditorScreen(
                  draft: draft,
                  repository: repository,
                  capture: _RecordedDocument(photo.path),
                ),
              ),
            ),
            child: const Text('Отвори OCR тест'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Отвори OCR тест'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Избери снимки'));
    await tester.pumpAndSettle();
    await waitFor(tester, () => draft.items.length == 37, 'OCR 37 rows');
    expect(draft.items, hasLength(37));
    expect(draft.readyCount, 23);
    expect(find.text('Необходим е избор на продукт'), findsNothing);
    passed(
      'Real JPEG -> authenticated PocketBase proxy -> recorded 37-row Paddle response; 14 missing dates correctly rejected',
    );
    await preview(tester, '04-ocr-review');

    final first = draft.items.first;
    final quantity = find.byKey(ValueKey('${first.id}_received'));
    await tester.scrollUntilVisible(
      quantity,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(tester, quantity);
    await tester.tap(quantity);
    await tester.pumpAndSettle();
    final before = first.received;
    final input = find.byKey(const Key('quantity-correction-input'));
    await edit(tester, input, '1');
    await tester.pumpAndSettle();
    await tester.pump();
    expect(first.received, before);
    expect(find.byType(AlertDialog), findsOneWidget);
    await edit(tester, input, '15');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
    await tester.pumpAndSettle();
    expect(first.received, '15');
    final replacement = formatDocumentDate(
      DateTime.now().add(const Duration(days: 40)),
    ).replaceAll('.', '');
    for (final row
        in draft.items
            .where((i) => parseDocumentDate(i.expiry) == null)
            .toList()) {
      final field = find.descendant(
        of: find.byKey(ValueKey('${row.id}_expiry')),
        matching: find.byType(TextField),
      );
      await tester.scrollUntilVisible(
        field,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await reveal(tester, field);
      await edit(tester, field, replacement);
      await tester.pumpAndSettle();
      await tester.pump();
      expect(row.ready, isTrue);
    }
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(draft.readyCount, 37);
    final save = find.byKey(const Key('finish-delivery'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    passed(
      'Quantity 1→15 stays editable until Done; all 14 manual numeric dates normalize and become Ready without checking',
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => draft.status == 'finalized',
      'atomic finalization',
    );
    expect(draft.status, 'finalized');
    final receipt = draft.finalizationReceipt!;
    expect(receipt['lines'], hasLength(37));
    final batches = await pb
        .collection('batches')
        .getFullList(
          filter: pb.filter('delivery={:id}', {'id': draft.serverId}),
        );
    expect(batches, hasLength(37));
    final finalizer = PocketBaseDeliveryFinalizer();
    await finalizer.probe();
    expect(
      await finalizer.finalize(draft.serverId!, draft.finalizationRequest!),
      receipt,
    );
    expect(
      await pb
          .collection('batches')
          .getFullList(
            filter: pb.filter('delivery={:id}', {'id': draft.serverId}),
          ),
      hasLength(37),
    );
    expect(
      (await repository.list(owner))
          .where((d) => d.id == draft.id)
          .single
          .status,
      'finalized',
    );
    passed(
      'One Save commits 37 batches/products/movements; finalized receipt and replay without duplicate stock',
    );
    await show(tester, const HomeScreen());
    final visible = await PocketBaseService.getExpiryBatches();
    expect(
      visible.map((b) => b.id).toSet().containsAll(batches.map((b) => b.id)),
      isTrue,
    );
    await preview(tester, '05-expiry-dashboard-after-save');

    final code = first.supplierCode;
    final matched = await pb
        .collection('products')
        .getFullList(filter: pb.filter('barcode={:code}', {'code': code}));
    expect(matched, hasLength(1));
    await show(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => KnownProductBatchScreen(ownerId: owner),
              ),
            ),
            child: const Text('Нов срок'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Нов срок'));
    await tester.pumpAndSettle();
    await edit(tester, textField('Баркод'), code);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Намери в PocketBase'));
    await tester.pumpAndSettle();
    final expiry = find.descendant(
      of: find.byType(ExpiryDateField),
      matching: find.byType(TextField),
    );
    await edit(
      tester,
      expiry,
      formatDocumentDate(DateTime.now().add(const Duration(days: 45)))
          .replaceAll('.', ''),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('Отказ'));
    await tester.pumpAndSettle();
    await edit(tester, textField('Количество'), '8');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Потвърди и запиши срока'));
    await tester.tap(find.text('Потвърди и запиши срока'));
    await tester.pumpAndSettle();
    final sameProduct = await pb
        .collection('batches')
        .getFullList(
          filter: pb.filter('product={:id}', {'id': matched.single.id}),
        );
    expect(sameProduct, hasLength(2));
    expect(
      sameProduct.map((b) => b.getStringValue('expiry_date')).toSet(),
      hasLength(2),
    );
    expect(
      await pb
          .collection('products')
          .getFullList(filter: pb.filter('barcode={:code}', {'code': code})),
      hasLength(1),
    );
    passed(
      'Barcode-first manual batch, editable numeric date, existing calendar, separate second expiry without duplicate product',
    );

    final local = DeliveryDraft(
      ownerId: owner,
      supplier: 'Емулатор чернова',
      pages: [
        DraftPage(
          imagePath: '',
          recognized: true,
          items: [
            DraftItem(
              name: 'Чернова продукт',
              supplierCode: '000-EMU-DRAFT',
              received: '2',
              expiry: formatDocumentDate(
                DateTime.now().add(const Duration(days: 20)),
              ),
              articleBarcode: true,
              proposedNewProduct: true,
            ),
          ],
        ),
      ],
    );
    await repository.save(local);
    await show(tester, const DeliveriesScreen());
    await tester.tap(find.text('Емулатор чернова'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Запази чернова'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await repository.load(owner, local.id)).items.single.received, '2');
    await tester.tap(find.byTooltip('Изтрий чернова'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Изтрий'));
    await tester.pumpAndSettle();
    expect(
      (await repository.list(owner)).any((d) => d.id == local.id),
      isFalse,
    );
    passed(
      'Actual local draft save, reopen, back navigation and confirmed deletion',
    );

    await show(tester, const HomeScreen());
    await preview(tester, '07-final-home');
    final report = Directory(
      '${(await getApplicationSupportDirectory()).path}/emulator_report',
    );
    await File('${report.path}/checks.json').writeAsString(
      jsonEncode({
        'checks': checks,
        'production_contacted': false,
        'ocr_provider': 'recorded Paddle response',
        'delivery_id': draft.serverId,
      }),
    );
    binding.reportData = {'checks': checks, 'production_contacted': false};
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

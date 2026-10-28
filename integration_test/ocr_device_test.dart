import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:expiry_tracker/main.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/home_screen.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/ocr_service.dart';
import 'package:expiry_tracker/services/page_capture_service.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pocketbase/pocketbase.dart';

class _LocalFiles implements PageCapture {
  final List<String> files;
  _LocalFiles(this.files);
  @override
  Future<List<XFile>> camera() async => [XFile(files.first)];
  @override
  Future<List<XFile>> gallery({required bool multiple}) async =>
      (multiple ? files : files.take(1)).map(XFile.new).toList();
}

class _StructuredEngine implements OcrEngine {
  @override
  Future<Map<String, dynamic>> recognize(String path) async => {
    'status': 'ok',
    'engine': 'PaddleOCR PP-OCRv5',
    'products': [
      {
        'article_code': 'TEST01',
        'name': 'Тестов продукт',
        'requested_quantity': 2,
        'expiry_date': null,
        'batch_number': null,
        'requires_review': true,
      },
    ],
    'processing_seconds': 0,
  };
}

class _QueuedEngine implements OcrEngine {
  int calls = 0;
  Completer<Map<String, dynamic>> pending = Completer();
  @override
  Future<Map<String, dynamic>> recognize(String path) {
    calls++;
    return pending.future;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> preview(WidgetTester tester, String name, Key key) async {
    // A real device may still have a scroll frame waiting to paint.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    binding.reportData ??= {};
    final previews =
        binding.reportData!.putIfAbsent('previews', () => <dynamic>[]) as List;
    previews.add({'name': name, 'bytes': data!.buffer.asUint8List()});
  }

  const inputs = [
    String.fromEnvironment(
      'OCR_INPUT_1',
      defaultValue: '/data/user/0/com.expiry_tracker.expiry_tracker.ocrtest/files/ocr_test/page1.jpg',
    ),
    String.fromEnvironment(
      'OCR_INPUT_2',
      defaultValue: '/data/user/0/com.expiry_tracker.expiry_tracker.ocrtest/files/ocr_test/page2.jpg',
    ),
  ];

  testWidgets(
    'Multiple imported pages persist with injected structured Paddle response',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ocr-integration-');
      final repository = DraftRepository(rootDirectory: () async => root);
      final draft = DeliveryDraft(ownerId: 'testemployee');
      await repository.save(draft);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          home: RepaintBoundary(
            key: const Key('editor-preview'),
            child: DeliveryEditorScreen(
              draft: draft,
              repository: repository,
              capture: _LocalFiles(inputs),
              engine: _StructuredEngine(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Избери снимки'));
      await tester.pumpAndSettle();
      expect(draft.pages, hasLength(2));
      // OCR starts automatically after choosing/capturing pages.
      expect(draft.pages.every((p) => p.recognized && p.error == null), isTrue);
      final reopened = await repository.load(draft.ownerId, draft.id);
      expect(reopened.pages, hasLength(2));
      expect(reopened.items.length, 2);
      expect(reopened.checkedCount, 0);
      await tester.scrollUntilVisible(
        find.text('Снимайте. Проверете. Запазете черновата.'),
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await preview(tester, 'delivery-dark', const Key('editor-preview'));
      await tester.pumpWidget(const SizedBox.shrink());
      await root.delete(recursive: true);
    },
  );

  testWidgets(
    'Repeated taps run once; failed OCR retries without losing the photo',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ocr-retry-');
      final repository = DraftRepository(rootDirectory: () async => root);
      final draft = DeliveryDraft(
        ownerId: 'testemployee',
        pages: [DraftPage(imagePath: inputs.first)],
      );
      final engine = _QueuedEngine();
      await repository.save(draft);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          home: DeliveryEditorScreen(
            draft: draft,
            repository: repository,
            engine: engine,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.text('Разпознай страниците');
      await tester.scrollUntilVisible(
        button,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.tap(button);
      expect(engine.calls, 1);
      engine.pending.completeError(StateError('Synthetic OCR failure'));
      await tester.pumpAndSettle();
      expect(draft.pages.single.error, contains('Synthetic OCR failure'));
      expect(draft.pages.single.imagePath, inputs.first);
      engine.pending = Completer();
      await tester.ensureVisible(button);
      await tester.tap(button);
      expect(engine.calls, 2);
      engine.pending.complete({
        'status': 'ok',
        'engine': 'PaddleOCR PP-OCRv5',
        'products': [],
        'words': [],
        'width': 100,
        'height': 100,
        'elapsedMs': 1,
      });
      await tester.pumpAndSettle();
      expect(draft.pages.single.error, isNull);
      expect(
        (await repository.load(
          draft.ownerId,
          draft.id,
        )).pages.single.recognized,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await root.delete(recursive: true);
    },
  );

  testWidgets('Theme selection is persisted by the real Android plugin', (
    tester,
  ) async {
    final controller = ThemeController.instance;
    final original = controller.value;
    await tester.pumpWidget(const MyApp());
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      await controller.select(mode);
      await tester.pumpAndSettle();
      final reopened = ThemeController();
      await reopened.load();
      expect(reopened.value, mode);
      reopened.dispose();
    }
    await controller.select(original);
  });

  testWidgets('Home renders in dark and light themes', (tester) async {
    PocketBaseService.pb.authStore.save(
      'test-only',
      RecordModel.fromJson({
        'id': 'previewemployee',
        'collectionName': 'employees',
        'name': 'Служител',
      }),
    );
    for (final brightness in [Brightness.dark, Brightness.light]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness),
          home: const RepaintBoundary(
            key: Key('home-preview'),
            child: HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Сканирай доставка'), findsOneWidget);
      await preview(
        tester,
        'home-${brightness.name}',
        const Key('home-preview'),
      );
    }
    PocketBaseService.logout();
  });
}

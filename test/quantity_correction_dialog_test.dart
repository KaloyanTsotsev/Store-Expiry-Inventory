import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/widgets/bulk_review_row.dart';
import 'package:expiry_tracker/widgets/quantity_correction_dialog.dart';

class _Drafts extends DraftRepository {
  int saves = 0;
  @override
  Future<void> save(DeliveryDraft draft) async {
    saves++;
  }
}

void main() {
  final input = find.byKey(const Key('quantity-correction-input'));

  Future<void> open(
    WidgetTester tester,
    DraftItem item,
    VoidCallback changed, {
    bool correctionsOnly = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, update) => correctionsOnly && item.ready
                  ? const Text('Редът е готов')
                  : BulkReviewRow(
                      item: item,
                      enabled: true,
                      automaticValidation: true,
                      productLabel: 'Нов продукт',
                      onChanged: () {
                        changed();
                        update(() {});
                      },
                      onDetails: () {},
                    ),
            ),
          ),
        ),
      ),
    );
    final field = find.byKey(ValueKey('${item.id}_received'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.byType(QuantityCorrectionDialog), findsOneWidget);
  }

  DraftItem row(String quantity) => DraftItem(
    name: 'Мляко',
    supplierCode: '000123',
    received: quantity,
    expiry: '25.11.2026',
    articleBarcode: true,
    proposedNewProduct: true,
  );

  testWidgets(
    'Correction filter keeps the editor open while typing and enables Save only after confirmation',
    (tester) async {
      final item = row('');
      final repository = _Drafts();
      final draft = DeliveryDraft(
        ownerId: 'employee1',
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [item]),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: repository,
            catalogLoader: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('За корекция: 1 • Отвори'));
      await tester.pumpAndSettle();
      final field = find.byKey(ValueKey('${item.id}_received'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      final before = repository.saves;
      final save = find.byKey(const Key('finish-delivery'));
      for (final text in ['1', '15']) {
        await tester.enterText(input, text);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(QuantityCorrectionDialog), findsOneWidget);
        expect(item.received, '');
        expect(repository.saves, before);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
      await tester.pumpAndSettle();
      expect(item.received, '15');
      expect(item.ready, isTrue);
      expect(find.byType(QuantityCorrectionDialog), findsNothing);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final finalValue in ['15', '125']) {
    testWidgets(
      'Typing $finalValue digit by digit never commits until Готово',
      (tester) async {
        final item = row('');
        var changes = 0;
        await open(tester, item, () => changes++, correctionsOnly: true);
        for (var i = 1; i <= finalValue.length; i++) {
          await tester.enterText(input, finalValue.substring(0, i));
          await tester.pump();
          expect(find.byType(QuantityCorrectionDialog), findsOneWidget);
          expect(item.received, '');
          expect(item.ready, isFalse);
          expect(changes, 0);
        }
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byType(QuantityCorrectionDialog), findsOneWidget);
        expect(changes, 0);
        await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
        await tester.pumpAndSettle();
        expect(item.received, finalValue);
        expect(item.ready, isTrue);
        expect(changes, 1);
        expect(find.text('Редът е готов'), findsOneWidget);
        expect(find.byType(QuantityCorrectionDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'Backspace edits a local value; cancel preserves quantity and confirmation',
    (tester) async {
      final item = row('125')..checked = true;
      var changes = 0;
      await open(tester, item, () => changes++);
      // Android sends the full editing value for deletions, just as for inserts.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '12',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '12');
      expect(item.received, '125');
      await tester.tap(find.text('Отказ'));
      await tester.pumpAndSettle();
      expect(item.received, '125');
      expect(item.checked, isTrue);
      expect(changes, 0);
      final field = find.byKey(ValueKey('${item.id}_received'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '125');
      await tester.enterText(input, '12');
      await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
      await tester.pumpAndSettle();
      expect(item.received, '12');
      expect(item.checked, isFalse);
      expect(item.ready, isTrue);
      expect(changes, 1);
    },
  );

  for (final invalid in ['', '0', '-2', '1..5', 'NaN', '1x', 'Infinity']) {
    testWidgets(
      'Invalid quantity "$invalid" stays editable and does not commit',
      (tester) async {
        final item = row('8');
        var changes = 0;
        await open(tester, item, () => changes++);
        await tester.enterText(input, invalid);
        await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
        await tester.pumpAndSettle();
        expect(find.byType(QuantityCorrectionDialog), findsOneWidget);
        expect(
          find.text('Въведете валидно положително количество.'),
          findsOneWidget,
        );
        expect(item.received, '8');
        expect(changes, 0);
        await tester.enterText(input, '2,5');
        await tester.pump();
        expect(
          find.text('Въведете валидно положително количество.'),
          findsNothing,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Готово'));
        await tester.pumpAndSettle();
        expect(item.received, '2,5');
        expect(item.ready, isTrue);
        expect(changes, 1);
      },
    );
  }
}

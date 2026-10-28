import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/theme/app_theme.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'A50: sticky finalization, summary and missing backend preserve real local draft',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('finalization-ui-');
      final repository = DraftRepository(rootDirectory: () async => root);
      final draft = DeliveryDraft(
        ownerId: 'deviceemployee',
        pages: [
          DraftPage(
            imagePath: '',
            recognized: true,
            items: [
              for (var i = 0; i < 12; i++)
                DraftItem(
                  name: 'Тестов продукт $i',
                  ordered: '12',
                  received: '6',
                  expiry: '08.11.2026',
                  lot: 'N/A',
                  proposedNewProduct: true,
                  checked: true,
                ),
            ],
          ),
        ],
      );
      try {
        await repository.save(draft);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(Brightness.dark),
            home: DeliveryEditorScreen(draft: draft, repository: repository),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const Key('finish-delivery'));
        final rect = tester.getRect(button);
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(find.text('Проверени 12 от 12 продукта'), findsOneWidget);
        await tester.drag(find.byType(ListView).first, const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(tester.getRect(button), rect);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Позиции: 12'), findsOneWidget);
        expect(find.text('Разлика: -6.00'), findsNWidgets(12));
        expect(find.text(backendV2Required), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Потвърди и приключи'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Назад към проверката'));
        await tester.pumpAndSettle();
        final reopened = await repository.load(draft.ownerId, draft.id);
        expect(reopened.status, 'draft');
        expect(reopened.checkedCount, 12);
        expect(reopened.finalizationRequest, isNull);
        expect(reopened.items.every((item) => item.lot == 'N/A'), isTrue);
        binding.reportData ??= {};
        binding.reportData!['sticky_summary_backend_gate_persistence'] =
            'passed';
        debugPrint(
          'A50_FINALIZATION: pinned action, 12-row summary, backend gate and persisted checks PASS',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets('A50: invalid positive expiry keeps finalization disabled', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('finalization-invalid-');
    final repository = DraftRepository(rootDirectory: () async => root);
    final draft = DeliveryDraft(
      ownerId: 'deviceemployee',
      pages: [
        DraftPage(
          imagePath: '',
          recognized: true,
          items: [
            DraftItem(
              name: 'Тестов продукт',
              ordered: '6',
              received: '6',
              expiry: '1',
              lot: 'N/A',
              proposedNewProduct: true,
              checked: true,
            ),
          ],
        ),
      ],
    );
    try {
      await repository.save(draft);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.light),
          home: DeliveryEditorScreen(draft: draft, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('finish-delivery')))
            .onPressed,
        isNull,
      );
      expect(find.text('Проверени 0 от 1 продукта'), findsOneWidget);
      binding.reportData ??= {};
      binding.reportData!['invalid_positive_expiry'] = 'passed';
      debugPrint(
        'A50_FINALIZATION: invalid positive expiry blocks finalization PASS',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await root.delete(recursive: true);
    }
  });
}

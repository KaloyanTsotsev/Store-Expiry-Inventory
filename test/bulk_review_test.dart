import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/widgets/bulk_review_row.dart';

void main() {
  testWidgets(
    'N/A lot is optional, has no warning and can be manually replaced or cleared',
    (tester) async {
      final item = DraftItem(
        name: 'Мляко',
        received: '6',
        expiry: '08.11.2026',
        productId: 'p',
        lot: '1',
        uncertainFields: const ['lot'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, update) => BulkReviewRow(
                  item: item,
                  enabled: true,
                  productLabel: 'Продукт',
                  onChanged: () => update(() {}),
                  onDetails: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final lot = find.byKey(ValueKey('${item.id}_lot'));
      await tester.ensureVisible(lot);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(lot).controller!.text, 'N/A');
      expect(find.byIcon(Icons.help_outline), findsNothing);
      await tester.ensureVisible(find.text('Проверено'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(item.checked, isTrue);
      await tester.ensureVisible(lot);
      await tester.pumpAndSettle();
      await tester.enterText(lot, 'LOT-NEW');
      await tester.pump();
      expect(item.lot, 'LOT-NEW');
      expect(item.checked, isFalse);
      await tester.enterText(lot, '');
      await tester.pump();
      expect(item.lot, 'N/A');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<TextField>(lot).controller!.text, 'N/A');
      expect(find.byIcon(Icons.help_outline), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Inline quantity editing unchecks only that row and preserves neighboring rows',
    (tester) async {
      final items = [
        for (var i = 0; i < 2; i++)
          DraftItem(
            name: 'Мляко $i',
            received: '12',
            ordered: '12',
            expiry: '23.10.2026',
            lot: 'A',
            productId: 'p$i',
            checked: true,
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, update) => Column(
                  children: [
                    for (final item in items)
                      BulkReviewRow(
                        key: ValueKey(item.id),
                        item: item,
                        enabled: true,
                        productLabel: 'Избран продукт',
                        onChanged: () => update(() {}),
                        onDetails: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final received = find.byKey(ValueKey('${items.first.id}_received'));
      await tester.ensureVisible(received);
      await tester.enterText(received, '10');
      await tester.pump();
      expect(items.first.received, '10');
      expect(items.first.checked, isFalse);
      expect(items.last.checked, isTrue);
      expect(items.last.received, '12');
      await tester.ensureVisible(find.text('Проверено').first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(items.first.checked, isTrue);
      expect(find.text('Мерна единица'), findsNothing);
      expect(find.text('Разлика от документа'), findsNothing);
      items.first.lot = '1';
      items.first.checked = false;
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

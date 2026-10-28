import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/screens/delivery_item_screen.dart';
import 'package:expiry_tracker/services/delivery_catalog_service.dart';
import 'package:expiry_tracker/services/product_matcher.dart';

import 'delivery_identity_test.dart' show Catalog, line;

void main() {
  for (final manager in [true, false]) {
    testWidgets(
      manager
          ? 'Manager explicitly confirms catalog creation before checking row'
          : 'Employee sees manager approval path without an unrelated product picker or write',
      (tester) async {
        final catalog = Catalog(manager: manager), item = line();
        ProductMatcher.prepare(item, [], 'А');
        var saves = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: DeliveryItemScreen(
              item: item,
              imagePath: '',
              supplier: 'А',
              products: const [],
              onReloadCatalog: () async => [],
              onSave: () async {
                saves++;
              },
              identityService: DeliveryCatalogService(catalog: catalog),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Изберете продукт от каталога'), findsNothing);
        expect(catalog.writes, 0);
        final confirm = find.text('Потвърди физическата проверка');
        await tester.scrollUntilVisible(
          confirm,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(confirm);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        if (manager) {
          expect(find.text('Потвърди нов каталожен продукт'), findsOneWidget);
          expect(catalog.writes, 0);
          expect(item.checked, isFalse);
          await tester.tap(find.text('Потвърди създаването'));
          await tester.pumpAndSettle();
          expect(catalog.writes, 1);
          expect(item.checked, isTrue);
          expect(item.productId, 'cat000000000001');
          expect(item.received, '12');
          expect(saves, greaterThanOrEqualTo(2));
        } else {
          expect(catalog.calls, 0);
          expect(item.checked, isFalse);
          expect(item.productId, isNull);
          expect(
            find.textContaining('Нов продукт — чака управител.'),
            findsWidgets,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

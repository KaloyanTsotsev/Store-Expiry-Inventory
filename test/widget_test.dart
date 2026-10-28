import 'package:expiry_tracker/main.dart';
import 'package:expiry_tracker/screens/home_screen.dart';
import 'package:expiry_tracker/screens/product_form_screen.dart';
import 'package:expiry_tracker/services/pocketbase_service.dart';
import 'package:expiry_tracker/services/product_catalog_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

class _ManagerCatalog extends ProductCatalogService {
  @override
  bool get canManage => true;
}

void main() {
  tearDown(PocketBaseService.logout);

  testWidgets('Empty login stays on login and explains required fields', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('Вход'));
    await tester.tap(find.text('Вход'));
    await tester.pump();
    expect(find.text('Въведете потребителско име и парола.'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('Blank product name cannot be submitted', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ProductFormScreen(catalog: _ManagerCatalog())),
    );
    await tester.enterText(find.byType(TextFormField).first, '   ');
    await tester.ensureVisible(find.text('Запази продукта'));
    await tester.tap(find.text('Запази продукта'));
    await tester.pump();
    expect(find.text('Въведете име на продукта'), findsOneWidget);
  });

  testWidgets('Home falls back to username and logout clears session', (
    tester,
  ) async {
    PocketBaseService.pb.authStore.save(
      'test',
      RecordModel.fromJson({
        'id': 'employee1',
        'collectionName': 'employees',
        'name': '',
        'username': 'shop-admin',
      }),
    );
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    expect(find.text('Здравей, shop-admin!'), findsOneWidget);
    await tester.tap(find.byTooltip('Изход'));
    await tester.pumpAndSettle();
    expect(PocketBaseService.pb.authStore.token, isEmpty);
    expect(PocketBaseService.pb.authStore.record, isNull);
    expect(find.text('Вход'), findsOneWidget);
  });
}

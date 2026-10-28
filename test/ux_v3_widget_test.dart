import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/models/expiry_batch.dart';
import 'package:expiry_tracker/services/batch_check_repository.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/widgets/expiry_dashboard.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/screens/delivery_item_screen.dart';

class _Checks extends BatchCheckRepository {
  final commands = <Map<String, dynamic>>[];
  @override
  Future<List<Map<String, dynamic>>> list(String owner) async =>
      List.of(commands);
  @override
  Future<void> prepare({
    required String owner,
    required ExpiryBatch batch,
    required String kind,
    required String quantity,
    String reason = '',
  }) async {
    commands.add({'batch': batch.id, 'kind': kind, 'operation_key': 'testkey'});
  }
}

class _Drafts extends DraftRepository {
  int saves = 0;
  @override
  Future<void> save(DeliveryDraft draft) async {
    saves++;
  }
}

ExpiryBatch _batch(String id, int days, {String status = ''}) => ExpiryBatch(
  id: id,
  productName: id,
  lot: 'A',
  status: status,
  expiry: DateTime.utc(2026, 10, 22).add(Duration(days: days)),
  days: days,
  revision: 1,
  warningDays: 7,
  customWarning: false,
);
void main() {
  testWidgets(
    'Detail confirmation saves a staged product and returns to the inline review',
    (tester) async {
      final item = DraftItem(
        name: 'Нов продукт',
        received: '2',
        expiry: '23.10.2026',
        lot: 'A',
        proposedNewProduct: true,
      );
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DeliveryItemScreen(
                      item: item,
                      imagePath: '',
                      products: const [],
                      onReloadCatalog: () async => [],
                      onSave: () async {
                        saves++;
                      },
                    ),
                  ),
                ),
                child: const Text('Отвори'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Отвори'));
      await tester.pumpAndSettle();
      final confirm = find.text('Потвърди физическата проверка');
      await tester.scrollUntilVisible(
        confirm,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(item.checked, isTrue);
      expect(saves, 1);
      expect(find.text('Отвори'), findsOneWidget);
      expect(find.byType(DeliveryItemScreen), findsNothing);
    },
  );

  testWidgets(
    'Mark-all requires physical declaration and cannot mark invalid rows',
    (tester) async {
      final valid = DraftItem(
        name: 'Мляко',
        received: '2',
        expiry: '23.10.2026',
        lot: 'A',
        proposedNewProduct: true,
      );
      final invalid = DraftItem(
        name: 'Неясен',
        received: '2',
        expiry: '1',
        lot: '1',
      );
      final draft = DeliveryDraft(
        ownerId: 'employee1',
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [valid, invalid]),
        ],
      );
      final repository = _Drafts();
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(draft: draft, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Маркирай всички — проверени'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Маркирай всички — проверени'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Потвърди всички');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(valid.checked, isFalse);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(valid.checked, isTrue);
      expect(invalid.checked, isFalse);
      expect(draft.allReviewed, isFalse);
      expect(repository.saves, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Dashboard sorts real supplied batches, hides closed, and keeps unsent checks visible',
    (tester) async {
      final repo = _Checks();
      final key = GlobalKey<ExpiryDashboardState>();
      var fail = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExpiryDashboard(
              key: key,
              ownerId: 'employee1',
              employeeName: 'Тест',
              checkRepository: repo,
              loadBatches: () async {
                if (fail) throw StateError('offline');
                return [
                  _batch('future', 5),
                  _batch('expired', -1),
                  _batch('closed', -2, status: 'closed'),
                ];
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.batches.map((b) => b.id), ['expired', 'future']);
      expect(find.byKey(const ValueKey('batch-closed')), findsNothing);
      final none = find.descendant(
        of: find.byKey(const ValueKey('batch-expired')),
        matching: find.text('Няма останали'),
      );
      await tester.scrollUntilVisible(
        none,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(none);
      await tester.pumpAndSettle();
      expect(repo.commands, isEmpty);
      await tester.tap(find.text('Потвърди и запази заявка'));
      await tester.pumpAndSettle();
      expect(repo.commands.single['kind'], 'none');
      expect(find.byKey(const ValueKey('batch-expired')), findsOneWidget);
      expect(
        find.text(
          'Неизпратена проверка на този телефон. Не е отразена в PocketBase.',
        ),
        findsOneWidget,
      );
      fail = true;
      await key.currentState!.refresh();
      await tester.pump();
      expect(key.currentState!.batches, hasLength(2));
      expect(key.currentState!.error, contains('offline'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

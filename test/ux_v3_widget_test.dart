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
  Future<void> setRetry(String owner, String key, {String? failure}) async {
    for (final command in commands.where((c) => c['operation_key'] == key)) {
      command['sync_status'] = failure == null ? 'not_sent' : 'retry_required';
      command['sync_error'] = failure;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> list(String owner) async =>
      List.of(commands);
  @override
  Future<void> cancel(String owner, String operationKey) async {
    commands.removeWhere((c) => c['operation_key'] == operationKey);
  }

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
    'Automatic validation distinguishes ready rows without selection or writes',
    (tester) async {
      final valid = DraftItem(
        supplierCode: '00012',
        name: 'Мляко',
        ordered: '2',
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
      expect(valid.ready, isTrue);
      expect(invalid.ready, isFalse);
      expect(valid.checked, isFalse);
      expect(draft.readyCount, 1);
      expect(draft.allReady, isFalse);
      expect(find.text('Избери всички'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('finish-delivery')))
            .onPressed,
        isNull,
      );
      expect(repository.saves, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Dashboard sorts real supplied batches, hides closed, and keeps unsent checks visible',
    (tester) async {
      final repo = _Checks();
      final key = GlobalKey<ExpiryDashboardState>();
      var fail = false;
      var handled = false;
      var online = false;
      var capability = false;
      var attemptedSends = 0;
      var successfulSends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExpiryDashboard(
              key: key,
              ownerId: 'employee1',
              employeeName: 'Тест',
              checkRepository: repo,
              checkHandlingCapability: () async {
                if (!capability) throw StateError('route unavailable');
              },
              sendHandling: (_, command) async {
                attemptedSends++;
                if (!online) throw StateError('offline');
                expect(command['batch'], 'expired');
                successfulSends++;
                handled = true;
              },
              loadBatches: () async {
                if (fail) throw StateError('offline');
                return [
                  _batch('future', 5),
                  if (!handled) _batch('expired', -1),
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
        matching: find.text('Премахни от списъка'),
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
      await tester.tap(find.text('Потвърди'));
      await tester.pumpAndSettle();
      expect(repo.commands.single['kind'], 'delete_batch');
      expect(attemptedSends, 0);
      expect(find.byKey(const ValueKey('batch-expired')), findsOneWidget);
      expect(
        find.text(
          'Неизпратена проверка на този телефон. Не е отразена в PocketBase.',
        ),
        findsOneWidget,
      );
      capability = true;
      fail = true;
      await key.currentState!.refresh();
      await tester.pump();
      expect(key.currentState!.batches, hasLength(2));
      expect(key.currentState!.error, contains('offline'));
      online = true;
      fail = false;
      expect(attemptedSends, 0); // A blocked request is not retried forever.
      await repo.setRetry('employee1', 'testkey');
      await Future.wait([
        key.currentState!.refresh(),
        key.currentState!.refresh(),
      ]);
      await tester.pumpAndSettle();
      expect(successfulSends, 1);
      expect(repo.commands, isEmpty);
      expect(key.currentState!.batches.map((b) => b.id), ['future']);
      expect(find.byKey(const ValueKey('batch-expired')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

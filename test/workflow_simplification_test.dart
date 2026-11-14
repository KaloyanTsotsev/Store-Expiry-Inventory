import 'dart:async';
import 'dart:io';

import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/models/expiry_batch.dart';
import 'package:expiry_tracker/services/batch_check_repository.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/widgets/bulk_review_row.dart';
import 'package:expiry_tracker/widgets/expiry_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

class Checks extends BatchCheckRepository {
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
    commands.add({
      'batch': batch.id,
      'employee': owner,
      'operation_key': 'key',
      'kind': kind,
      'expected_revision': batch.revision,
      'sync_status': 'not_sent',
    });
  }

  @override
  Future<void> cancel(String owner, String operationKey) async =>
      commands.clear();
  @override
  Future<void> setRetry(String owner, String key, {String? failure}) async {
    for (final c in commands) {
      c['sync_status'] = failure == null ? 'not_sent' : 'retry_required';
      c['sync_error'] = failure;
    }
  }
}

ExpiryBatch batch(String id, int days) => ExpiryBatch(
  id: id,
  productName: 'Мляко',
  barcode: '0000123',
  lot: 'N/A',
  status: 'active',
  expiry: DateTime(2026, 11, 13).add(Duration(days: days)),
  days: days,
  revision: 1,
  warningDays: 7,
  customWarning: false,
  quantity: 12,
);

void main() {
  testWidgets(
    'Lost delete response can be retried even after target disappears from list',
    (tester) async {
      final repo = Checks();
      var records = [batch('first', 30)];
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExpiryDashboard(
              ownerId: 'employee',
              employeeName: 'Тест',
              checkRepository: repo,
              loadBatches: () async => records,
              sendHandling: (_, c) async {
                attempts++;
                records = [];
                if (attempts == 1) {
                  throw TimeoutException('response lost after server commit');
                }
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.text('Премахни от списъка');
      await tester.scrollUntilVisible(
        action,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.textContaining('изтрита окончателно'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Потвърди'));
      await tester.pumpAndSettle();
      expect(repo.commands, hasLength(1));
      expect(repo.commands.single['sync_status'], 'retry_required');
      final details = find.byTooltip('Подробности за синхронизацията');
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Повтори'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(repo.commands, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final days in [-3, 30]) {
    testWidgets(
      'Handling $days days changes only selected batch after server success',
      (tester) async {
        final repo = Checks();
        var records = [batch('first', days), batch('second', days + 7)];
        final key = GlobalKey<ExpiryDashboardState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ExpiryDashboard(
                key: key,
                ownerId: 'employee',
                employeeName: 'Тест',
                checkRepository: repo,
                loadBatches: () async => records,
                sendHandling: (_, c) async {
                  expect(c['batch'], 'first');
                  records = records.where((b) => b.id != c['batch']).toList();
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.descendant(
          of: find.byKey(const ValueKey('batch-first')),
          matching: find.text('Премахни от списъка'),
        );
        await tester.scrollUntilVisible(
          action,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(repo.commands, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Потвърди'));
        await tester.pumpAndSettle();
        expect(key.currentState!.batches.single.id, 'second');
        expect(repo.commands, isEmpty);
        // Another phone closes the sibling; foreground polling reflects the server.
        records = [];
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(key.currentState!.batches, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final fault in [404, 401, 409, 0]) {
    testWidgets(
      'Failure $fault keeps batch visible and durable request, no automatic retry loop',
      (tester) async {
        final repo = Checks();
        var attempts = 0;
        final key = GlobalKey<ExpiryDashboardState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ExpiryDashboard(
                key: key,
                ownerId: 'employee',
                employeeName: 'Тест',
                checkRepository: repo,
                loadBatches: () async => [batch('first', 30)],
                sendHandling: (_, c) async {
                  attempts++;
                  if (fault == 0) throw TimeoutException('offline');
                  throw ClientException(statusCode: fault);
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.text('Премахни от списъка');
        await tester.scrollUntilVisible(
          action,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Потвърди'));
        await tester.pumpAndSettle();
        expect(attempts, 1);
        expect(repo.commands.single['sync_status'], 'retry_required');
        expect(key.currentState!.syncError, isNotEmpty);
        expect(key.currentState!.batches, hasLength(1));
        await key.currentState!.refresh();
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(attempts, 1);
        expect(repo.commands, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('Future handling commands persist, duplicate is rejected and retry survives restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'storeflow-handling-',
    );
    try {
      final repo = BatchCheckRepository(rootDirectory: () async => directory);
      await repo.prepare(
        owner: 'employee',
        batch: batch('future', 30),
        kind: 'delete_batch',
        quantity: '0',
      );
      await expectLater(
        repo.prepare(
          owner: 'employee',
          batch: batch('future', 30),
          kind: 'delete_batch',
          quantity: '0',
        ),
        throwsStateError,
      );
      final command = (await repo.list('employee')).single;
      await repo.setRetry(
        'employee',
        command['operation_key'] as String,
        failure: 'offline',
      );
      final restored = BatchCheckRepository(
        rootDirectory: () async => directory,
      );
      expect(
        (await restored.list('employee')).single['sync_status'],
        'retry_required',
      );
      expect(
        (await restored.list('employee')).single['expiry_date'],
        '2026-12-13',
      );
      await restored.setRetry('employee', command['operation_key'] as String);
      expect(
        (await restored.list('employee')).single['sync_status'],
        'not_sent',
      );
      expect(await restored.list('another_employee'), isEmpty);
      await restored.cancel('employee', command['operation_key'] as String);
      await restored.prepare(
        owner: 'employee',
        batch: batch('legacy', 30),
        kind: 'handled',
        quantity: '0',
      );
      expect((await restored.list('employee')).single['kind'], 'handled');
      // Only a fresh explicit confirmation replaces the old close-only intent.
      await restored.prepare(
        owner: 'employee',
        batch: batch('legacy', 30),
        kind: 'delete_batch',
        quantity: '0',
      );
      expect((await restored.list('employee')).single['kind'], 'delete_batch');
    } finally {
      // Only this test-created temporary directory is removed.
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'Not received toggle preserves OCR evidence, permits missing expiry and creates zero line',
    (tester) async {
      final item = DraftItem(
        id: 'row',
        name: 'Мляко',
        supplierCode: '0000123',
        received: '12',
        ordered: '12',
        expiry: '',
        articleBarcode: true,
        proposedNewProduct: true,
      );
      expect(item.ready, isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, update) => SingleChildScrollView(
                child: BulkReviewRow(
                  item: item,
                  enabled: true,
                  automaticValidation: true,
                  productLabel: 'Нов продукт',
                  onDetails: () {},
                  onChanged: () => update(() {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(item.ready, isTrue);
      expect(item.received, '0');
      expect(item.ordered, '12');
      expect(item.checked, isFalse);
      final draft = DeliveryDraft(
        id: 'draft',
        ownerId: 'employee',
        pages: [
          DraftPage(id: 'page', imagePath: '', recognized: true, items: [item]),
        ],
      );
      expect(DeliveryFinalization.lines(draft).single['received_quantity'], 0);
      expect(DeliveryFinalization.lines(draft).single['expiry_date'], '');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(item.received, '');
      expect(item.ready, isFalse);
    },
  );
}

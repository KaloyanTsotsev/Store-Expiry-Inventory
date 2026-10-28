import 'package:expiry_tracker/models/expiry_batch.dart';
import 'package:expiry_tracker/services/batch_check_repository.dart';
import 'package:expiry_tracker/theme/app_theme.dart';
import 'package:expiry_tracker/widgets/expiry_batch_card.dart';
import 'package:expiry_tracker/widgets/expiry_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

class _Checks extends BatchCheckRepository {
  @override
  Future<List<Map<String, dynamic>>> list(String owner) async => [];
}

ExpiryBatch batch(
  String id,
  int? days, {
  String? name,
  int warning = 7,
  String lot = 'N/A',
}) => ExpiryBatch(
  id: id,
  productName: name ?? id,
  lot: lot,
  status: 'active',
  expiry: days == null
      ? null
      : DateTime.utc(2026, 10, 22).add(Duration(days: days)),
  days: days,
  revision: 1,
  warningDays: warning,
  customWarning: warning != 7,
  quantity: 6,
);

Future<void> dashboard(WidgetTester tester, List<ExpiryBatch> records) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(Brightness.dark),
      home: Scaffold(
        body: ExpiryDashboard(
          ownerId: 'test',
          employeeName: 'Тест',
          checkRepository: _Checks(),
          loadBatches: () async => records,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Summary counts disjoint batches with product warning thresholds and unknown dates',
    (tester) async {
      await dashboard(tester, [
        batch('expired', -1),
        batch('today', 0),
        batch('soon', 12, warning: 14),
        batch('healthy', 3, warning: 2),
        batch('unknown', null),
      ]);
      for (final entry in {
        'expired': '1',
        'soon': '2',
        'healthy': '1',
      }.entries) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('summary-${entry.key}')),
            matching: find.text(entry.value),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.text('1 партида без валидна дата — за проверка'),
        findsOneWidget,
      );
      expect(
        find.text('Количествата са от доставките, не текуща наличност.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Filters and product search combine; sort reverses dates with unknown last',
    (tester) async {
      await dashboard(tester, [
        batch('unknown', null),
        batch('milk', 3, name: 'Кисело мляко'),
        batch('expired', -2),
        batch('today', 0),
        batch('healthy', 40),
      ]);
      await show(tester, find.byKey(const ValueKey('filter-expired')));
      await tester.tap(find.byKey(const ValueKey('filter-expired')));
      await tester.pumpAndSettle();
      expect(find.text('1 от 5 партиди'), findsOneWidget);
      await show(tester, find.byType(ExpiryBatchCard).first);
      expect(
        tester
            .widget<ExpiryBatchCard>(find.byType(ExpiryBatchCard).first)
            .batch
            .id,
        'expired',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('filter-soon')));
      await tester.tap(find.byKey(const ValueKey('filter-soon')));
      await tester.pumpAndSettle();
      expect(find.text('2 от 5 партиди'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('batch-search')),
        'МЛЯКО',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 от 5 партиди'), findsOneWidget);
      await show(tester, find.byType(ExpiryBatchCard).first);
      expect(
        tester
            .widget<ExpiryBatchCard>(find.byType(ExpiryBatchCard).first)
            .batch
            .id,
        'milk',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('batch-search')));
      await tester.enterText(
        find.byKey(const ValueKey('batch-search')),
        'несъществуващ',
      );
      await tester.pumpAndSettle();
      await show(tester, find.text('Няма партиди по тези критерии.'));
      await tester.tap(find.text('Покажи всички'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('batch-sort')));
      await tester.tap(find.byKey(const ValueKey('batch-sort')));
      await tester.pumpAndSettle();
      await show(tester, find.byType(ExpiryBatchCard).first);
      expect(
        tester
            .widget<ExpiryBatchCard>(find.byType(ExpiryBatchCard).first)
            .batch
            .id,
        'healthy',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Batch card reads real quantity without invented unit or stock claim',
    (tester) async {
      final record = RecordModel.fromJson({
        'id': 'batch',
        'quantity': 2.5,
        'expiry_date': '2026-11-08',
        'lot_number': '',
        'expand': {
          'product': {'id': 'product', 'name': 'Мляко'},
        },
      });
      final model = ExpiryBatch.fromRecord(record, now: DateTime(2026, 10, 22));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.light),
          home: Scaffold(
            body: ExpiryBatchCard(
              batch: model,
              actions: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      expect(find.text('08.11.2026'), findsOneWidget);
      expect(find.text('17'), findsOneWidget);
      expect(find.text('N/A'), findsOneWidget);
      expect(find.text('Количество от доставка'), findsOneWidget);
      expect(find.text('2.5'), findsOneWidget);
      expect(find.textContaining('наличност'), findsNothing);
      expect(find.text('2.5 бр.'), findsNothing);
    },
  );

  testWidgets(
    'Missing quantity and date stay unknown, while an available unit is displayed',
    (tester) async {
      for (final data in [
        <String, dynamic>{},
        {'quantity': 3, 'unit': 'кг'},
      ]) {
        final model = ExpiryBatch.fromRecord(
          RecordModel.fromJson({'id': 'batch', ...data}),
          now: DateTime(2026, 10, 22),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ExpiryBatchCard(
                batch: model,
                actions: const SizedBox.shrink(),
              ),
            ),
          ),
        );
        expect(find.text('Срок за проверка'), findsOneWidget);
        expect(find.text(data.isEmpty ? 'Няма данни' : '3 кг'), findsOneWidget);
      }
    },
  );

  testWidgets(
    'Long product and lot names fit a 320px phone with large text in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const name =
          'Кисело мляко с дълго продуктово наименование, марка, разфасовка и допълнителна информация';
      for (final brightness in Brightness.values) {
        for (final days in [-3, 0, 2, 40, null]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.build(brightness),
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: ExpiryBatchCard(
                      batch: batch(
                        'long',
                        days,
                        name: name,
                        lot: 'LOT20261022ABCDEFGHIJKLMNOP1234567890',
                      ),
                      actions: Wrap(
                        children: [
                          TextButton(
                            onPressed: () {},
                            child: const Text('Няма останали'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(name), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: '$brightness / $days days',
          );
        }
      }
    },
  );

  testWidgets(
    'Full dashboard adapts to narrow width and 200% text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: ExpiryDashboard(
                  ownerId: 'test',
                  employeeName: 'Служител с дълго име',
                  checkRepository: _Checks(),
                  loadBatches: () async => [batch('expired', -1)],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await show(tester, find.text('Няма останали'));
        expect(tester.takeException(), isNull);
      }
    },
  );
}

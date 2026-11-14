import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/known_product_batch_screen.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

class _Drafts extends DraftRepository {
  @override
  Future<void> save(DeliveryDraft draft) async {}
}

class _Finalizer implements DeliveryFinalizer {
  Map<String, dynamic>? request;
  @override
  bool get available => true;
  @override
  Future<void> prepare(
    DeliveryDraft draft,
    Future<void> Function() persist,
  ) async {
    draft.serverId = 'delivery';
    draft.serverRevision = 1;
    await persist();
  }

  @override
  Future<Map<String, dynamic>> finalize(
    String serverId,
    Map<String, dynamic> packet,
  ) async {
    request = packet;
    return {'delivery_id': serverId, 'revision': 2, 'status': 'finalized'};
  }
}

void main() {
  testWidgets(
    'Exact lookup reuses product ID; invalid inputs never send; lot is optional',
    (tester) async {
      final finalizer = _Finalizer();
      final queries = <String>[];
      final known = RecordModel.fromJson({
        'id': 'product1',
        'name': 'Existing yogurt',
        'barcode': '00123',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('Open'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => KnownProductBatchScreen(
                    ownerId: 'employee',
                    repository: _Drafts(),
                    finalizer: finalizer,
                    lookup: (code) async {
                      queries.add(code);
                      return code == '00123' ? known : null;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '00999');
      await tester.tap(find.text('Намери в PocketBase'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '00123');
      await tester.tap(find.text('Намери в PocketBase'));
      await tester.pumpAndSettle();
      expect(queries, ['00999', '00123']);
      expect(find.text('Existing yogurt'), findsOneWidget);
      expect(find.text('Баркод: 00123'), findsOneWidget);
      expect(find.text('Доставчик'), findsNothing);
      final confirm = find.text('Потвърди и запиши срока');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(finalizer.request, isNull);
      await tester.tap(find.byTooltip('Избери дата от календара'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Избери'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        isNotEmpty,
      );
      await tester.enterText(find.byType(TextField).at(1), '20/11/26');
      await tester.pump();
      expect(find.text('Разчетена дата: 20.11.2026'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(2), '3');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final line = (finalizer.request!['lines'] as List).single as Map;
      expect(line['product_id'], 'product1');
      expect(line['proposed_new'], isFalse);
      expect(line['expiry_date'], '2026-11-20');
      expect(line['received_quantity'], 3);
      expect(line['lot_number'], 'N/A');
      expect(line['checked'], isTrue);
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/services/delivery_finalization_service.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';

DeliveryDraft reviewedDraft({int count = 1}) => DeliveryDraft(
  ownerId: 'employee1',
  serverId: 'serverdelivery1',
  serverRevision: 3,
  pages: [
    DraftPage(
      imagePath: '',
      recognized: true,
      items: [
        for (var i = 0; i < count; i++)
          DraftItem(
            name: 'Кисело мляко $i',
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

class _Repository extends DraftRepository {
  final snapshots = <Map<String, dynamic>>[];
  bool failReceipt = false;
  @override
  Future<void> save(DeliveryDraft draft) async {
    if (failReceipt && draft.status == 'finalized') {
      throw StateError('disk full');
    }
    snapshots.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(draft.toJson())) as Map),
    );
  }
}

class _Finalizer implements DeliveryFinalizer {
  @override
  Future<void> prepare(
    DeliveryDraft draft,
    Future<void> Function() persist,
  ) async {}
  @override
  bool get available => true;
  final requests = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function()? handler;
  @override
  Future<Map<String, dynamic>> finalize(
    String id,
    Map<String, dynamic> request,
  ) async {
    requests.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(request)) as Map),
    );
    return handler?.call() ??
        {'delivery_id': id, 'status': 'finalized', 'revision': 4, 'lines': []};
  }
}

Future<void> _editor(
  WidgetTester tester,
  DeliveryDraft draft,
  _Repository repository, {
  DeliveryFinalizer? finalizer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryEditorScreen(
                  draft: draft,
                  repository: repository,
                  finalizer: finalizer,
                ),
              ),
            ),
            child: const Text('Dashboard'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Dashboard'));
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('finish-delivery')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Потвърди и приключи'));
  await tester.pump();
}

void main() {
  test('Small decimal discrepancies remain visible in the final summary', () {
    expect(DeliveryFinalization.differenceText(1.235, 1.234), '0.001');
    expect(DeliveryFinalization.differenceText(6, 12), '-6.00');
    expect(DeliveryFinalization.differenceText(0, 0), '0.00');
  });
  test('Finalization requires reviewed rows, valid quantities and positive-receipt expiry', () {
    final draft = reviewedDraft();
    expect(DeliveryFinalization.errors(draft), isEmpty);
    final item = draft.items.single;
    item.checked = false;
    expect(DeliveryFinalization.errors(draft), isNotEmpty);
    item.checked = true;
    item.received = 'NaN';
    expect(DeliveryFinalization.errors(draft), isNotEmpty);
    item.received = '6';
    item.expiry = '1';
    expect(DeliveryFinalization.errors(draft), isNotEmpty);
    item.received = '0';
    expect(DeliveryFinalization.errors(draft), isEmpty);
    item.ordered = 'неясно';
    expect(DeliveryFinalization.errors(draft), isNotEmpty);
    expect(
      DeliveryFinalization.errors(DeliveryDraft(ownerId: 'employee1')),
      isNotEmpty,
    );
  });
  test('Packet keeps independent N/A expiry groups, stable operation and source IDs', () {
    final draft = reviewedDraft(count: 2);
    draft.items.last.expiry = '15.11.2026';
    final packet = DeliveryFinalization.request(draft);
    expect(packet['operation_key'], 'finalize:serverdelivery1');
    expect(packet['expected_revision'], 3);
    final rows = packet['lines'] as List;
    expect(rows.map((r) => r['lot_number']), ['N/A', 'N/A']);
    expect(rows.map((r) => r['expiry_date']), ['2026-11-08', '2026-11-15']);
    expect(rows[0]['line_id'], isNot(rows[1]['line_id']));
    expect(rows[0]['source_row_id'], draft.items.first.sourceRowId);
    draft.finalizationRequest = packet;
    final restored = DeliveryDraft.fromJson(
      jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>,
    );
    expect(restored.finalizationRequest, packet);
    expect(restored.serverId, draft.serverId);
  });
  test('Default production client cannot send finalization requests', () async {
    final client = PocketBaseDeliveryFinalizer();
    expect(client.available, isFalse);
    await expectLater(client.finalize('serverdelivery1', {}), throwsStateError);
  });
  testWidgets(
    'Sticky button stays visible on long list; unavailable backend cannot confirm success',
    (tester) async {
      final draft = reviewedDraft(count: 20);
      final repo = _Repository();
      await _editor(tester, draft, repo);
      final button = find.byKey(const Key('finish-delivery'));
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      final before = tester.getRect(button);
      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(tester.getRect(button), before);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Позиции: 20'), findsOneWidget);
      expect(find.text('Разлика: -6.00'), findsNWidgets(20));
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
      expect(draft.status, 'draft');
      expect(draft.finalizationRequest, isNull);
      expect(draft.checkedCount, 20);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Unchecked or invalid expiry disables sticky button', (
    tester,
  ) async {
    final draft = reviewedDraft();
    draft.items.single.expiry = '1';
    await _editor(tester, draft, _Repository());
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('finish-delivery')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Double tap sends once, persists packet first, then saves receipt and returns',
    (tester) async {
      final draft = reviewedDraft();
      final repo = _Repository();
      final client = _Finalizer();
      final result = Completer<Map<String, dynamic>>();
      client.handler = () => result.future;
      await _editor(tester, draft, repo, finalizer: client);
      final button = find.byKey(const Key('finish-delivery'));
      final press = tester.widget<FilledButton>(button).onPressed!;
      press();
      press();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Потвърди и приключи'),
      );
      await tester.pump();
      expect(client.requests, hasLength(1));
      expect(repo.snapshots.last['finalizationRequest'], isNotNull);
      expect(draft.status, 'draft');
      result.complete({
        'delivery_id': draft.serverId,
        'status': 'finalized',
        'revision': 4,
        'lines': [],
      });
      await tester.pumpAndSettle();
      expect(draft.status, 'finalized');
      expect(repo.snapshots.last['status'], 'finalized');
      expect(find.byType(DeliveryEditorScreen), findsNothing);
      expect(find.text('Dashboard'), findsOneWidget);
    },
  );
  testWidgets(
    'Lost response keeps reviewed data and exact request; retry uses same key and snapshot',
    (tester) async {
      final draft = reviewedDraft();
      final repo = _Repository();
      final client = _Finalizer();
      client.handler = () async {
        if (client.requests.length == 1) throw ClientException(statusCode: 0);
        return {
          'delivery_id': draft.serverId,
          'status': 'finalized',
          'revision': 4,
        };
      };
      await _editor(tester, draft, repo, finalizer: client);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(draft.status, 'draft');
      expect(draft.checkedCount, 1);
      expect(draft.items.single.received, '6');
      expect(draft.finalizationRequest, isNotNull);
      expect(find.textContaining('Има подготвена заявка'), findsOneWidget);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(client.requests, hasLength(2));
      expect(client.requests[0], client.requests[1]);
      expect(draft.status, 'finalized');
    },
  );
  testWidgets(
    'Disk failure after committed result retries local save without another server request',
    (tester) async {
      final draft = reviewedDraft();
      final repo = _Repository()..failReceipt = true;
      final client = _Finalizer();
      await _editor(tester, draft, repo, finalizer: client);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(draft.status, 'finalized');
      expect(draft.finalizationReceipt, isNotNull);
      expect(client.requests, hasLength(1));
      expect(find.text('Запази потвърждението'), findsOneWidget);
      repo.failReceipt = false;
      await tester.tap(find.byKey(const Key('finish-delivery')));
      await tester.pumpAndSettle();
      expect(client.requests, hasLength(1));
      expect(repo.snapshots.last['finalizationReceipt'], isNotNull);
      expect(find.byType(DeliveryEditorScreen), findsNothing);
    },
  );
}

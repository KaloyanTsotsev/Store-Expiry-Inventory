import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expiry_tracker/models/delivery_draft.dart';
import 'package:expiry_tracker/screens/delivery_editor_screen.dart';
import 'package:expiry_tracker/services/draft_repository.dart';
import 'package:expiry_tracker/widgets/expiry_date_field.dart';

class _Drafts extends DraftRepository {
  @override
  Future<void> save(DeliveryDraft draft) async {}
}

void main() {
  const formatter = BulgarianDateInputFormatter();
  TextEditingValue value(String text, [int? cursor]) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: cursor ?? text.length),
  );

  test('Numeric date typing, mid-string edits, separator deletion and explicit formats', () {
    var typed = value('');
    for (final digit in '25112026'.split('')) {
      typed = formatter.formatEditUpdate(typed, value('${typed.text}$digit'));
    }
    expect(typed.text, '25.11.2026');
    expect(typed.selection.extentOffset, 10);
    final replaced = formatter.formatEditUpdate(typed, value('26.11.2026', 2));
    expect(replaced.text, '26.11.2026');
    expect(replaced.selection.extentOffset, 2);
    final deleted = formatter.formatEditUpdate(
      value('25.11.2026', 3),
      value('2511.2026', 2),
    );
    expect(deleted.text, '21.12.026');
    expect(deleted.selection.extentOffset, 1);
    for (final text in [
      '25.11.2026',
      '25/11/2026',
      '25-11-2026',
      '25112026',
      '2026-11-25',
      '25.11.26',
    ]) {
      final formatted = formatter.formatEditUpdate(value(''), value(text));
      expect(parseDocumentDate(formatted.text), DateTime(2026, 11, 25));
    }
    for (final text in ['31022026', '29022025', '251120', '1', '25.11']) {
      expect(parseDocumentDate(text), isNull);
    }
    expect(parseDocumentDate('29022024'), DateTime(2024, 2, 29));
  });

  testWidgets(
    'Correcting a date enables Save immediately, without checking or selecting',
    (tester) async {
      final item = DraftItem(
        name: 'Мляко',
        supplierCode: '000123',
        received: '12',
        expiry: '1',
        articleBarcode: true,
        proposedNewProduct: true,
      );
      final draft = DeliveryDraft(
        ownerId: 'employee1',
        pages: [
          DraftPage(imagePath: '', recognized: true, items: [item]),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryEditorScreen(
            draft: draft,
            repository: _Drafts(),
            catalogLoader: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('finish-delivery'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.text('За корекция: 1 • Отвори'));
      await tester.pumpAndSettle();
      final date = find.descendant(
        of: find.byKey(ValueKey('${item.id}_expiry')),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(date);
      await tester.enterText(date, '25112026');
      await tester.pumpAndSettle();
      expect(item.expiry, '25.11.2026');
      expect(item.ready, isTrue);
      expect(item.checked, isFalse);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(find.text('Провери и запази'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

import 'package:expiry_tracker/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Password starts hidden and toggles without losing text; Bulgarian accessible actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        final password = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Парола',
        );
        TextField field() => tester.widget<TextField>(password);
        expect(field().obscureText, isTrue);
        expect(find.byIcon(Icons.visibility), findsOneWidget);
        await tester.ensureVisible(password);
        await tester.enterText(password, 'StoreFlow 123!');
        await tester.pumpAndSettle();
        final controller = field().controller;
        final selection = controller!.selection;
        final show = find.byTooltip('Покажи паролата');
        expect(find.bySemanticsLabel('Покажи паролата'), findsOneWidget);
        await tester.tap(show);
        await tester.pumpAndSettle();
        expect(field().obscureText, isFalse);
        expect(field().controller, same(controller));
        expect(controller.text, 'StoreFlow 123!');
        expect(controller.selection, selection);
        expect(find.byIcon(Icons.visibility_off), findsOneWidget);
        final hide = find.byTooltip('Скрий паролата');
        expect(find.bySemanticsLabel('Скрий паролата'), findsOneWidget);
        await tester.tap(hide);
        await tester.pumpAndSettle();
        expect(field().obscureText, isTrue);
        expect(controller.text, 'StoreFlow 123!');
        expect(controller.selection, selection);
        expect(find.byTooltip('Покажи паролата'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );
}

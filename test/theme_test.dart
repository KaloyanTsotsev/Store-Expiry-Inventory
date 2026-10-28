import 'package:expiry_tracker/theme/app_theme.dart';
import 'package:expiry_tracker/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Theme mode survives controller recreation including System', () async {
    String? persisted;
    ThemeController controller() => ThemeController(
      read: () async => persisted,
      write: (value) async {
        persisted = value;
      },
    );
    final first = controller();
    expect(first.value, ThemeMode.dark);
    for (final mode in ThemeMode.values) {
      await first.select(mode);
      final reopened = controller();
      await reopened.load();
      expect(reopened.value, mode);
      reopened.dispose();
    }
    first.dispose();
  });
  testWidgets('Both themes render existing Login with Bulgarian controls', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness),
          home: const LoginScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        Theme.of(tester.element(find.text('Вход'))).brightness,
        brightness,
      );
    }
  });
}

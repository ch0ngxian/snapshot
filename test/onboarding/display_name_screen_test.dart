import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/onboarding/display_name_screen.dart';

void main() {
  group('DisplayNameScreen', () {
    testWidgets('rejects empty input with an error', (tester) async {
      String? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayNameScreen(onContinue: (name) => captured = name),
        ),
      );

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text("Pick a name your friends will recognize."),
          findsOneWidget);
      expect(captured, isNull);
    });

    testWidgets('trims whitespace and forwards the name on success',
        (tester) async {
      String? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayNameScreen(onContinue: (name) => captured = name),
        ),
      );

      await tester.enterText(find.byType(TextField), '  Alex  ');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(captured, 'Alex');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/onboarding/consent_screen.dart';

void main() {
  group('ConsentScreen', () {
    testWidgets('finish button is disabled until checkbox is checked',
        (tester) async {
      var accepted = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ConsentScreen(onAccepted: () => accepted = true),
        ),
      );

      final finishButton = find.widgetWithText(FilledButton, 'Finish setup');
      expect(tester.widget<FilledButton>(finishButton).onPressed, isNull);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      expect(tester.widget<FilledButton>(finishButton).onPressed, isNotNull);

      await tester.tap(finishButton);
      await tester.pump();

      expect(accepted, isTrue);
    });

    testWidgets('shows the consent text from the plan', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ConsentScreen(onAccepted: () {})),
      );

      expect(find.textContaining('numeric representation'), findsOneWidget);
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(find.textContaining('delete your data any time'), findsOneWidget);
    });
  });
}

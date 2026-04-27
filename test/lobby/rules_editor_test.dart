import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/lobby/rules_editor.dart';
import 'package:snapshot/models/lobby.dart';

Future<void> _pump(
  WidgetTester tester, {
  required LobbyRules value,
  required ValueChanged<LobbyRules> onChanged,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RulesEditor(
          value: value,
          onChanged: onChanged,
          enabled: enabled,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the current rule values', (tester) async {
    await _pump(
      tester,
      value: const LobbyRules(
        startingLives: 3,
        durationSeconds: 600,
        immunitySeconds: 10,
      ),
      onChanged: (_) {},
    );
    expect(find.text('3'), findsOneWidget); // lives
    expect(find.text('10 min'), findsOneWidget); // duration
    expect(find.text('10s'), findsOneWidget); // immunity
  });

  testWidgets('increment buttons emit a new LobbyRules', (tester) async {
    LobbyRules? observed;
    await _pump(
      tester,
      value: LobbyRules.defaults,
      onChanged: (next) => observed = next,
    );
    await tester.tap(find.byTooltip('Increase Lives'));
    await tester.pump();
    expect(observed?.startingLives, 4);
  });

  testWidgets('decrement is disabled at the lower bound', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      value: const LobbyRules(
        startingLives: RulesEditor.minLives,
        durationSeconds: 600,
        immunitySeconds: 10,
      ),
      onChanged: (_) => calls++,
    );
    expect(_iconButton(tester, 'Decrease Lives').onPressed, isNull);
    await tester.tap(find.byTooltip('Decrease Lives'));
    expect(calls, 0);
  });

  testWidgets('increment is disabled at the upper bound', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      value: const LobbyRules(
        startingLives: RulesEditor.maxLives,
        durationSeconds: 600,
        immunitySeconds: 10,
      ),
      onChanged: (_) => calls++,
    );
    expect(_iconButton(tester, 'Increase Lives').onPressed, isNull);
  });

  testWidgets('all stepper buttons are disabled when enabled=false',
      (tester) async {
    await _pump(
      tester,
      value: LobbyRules.defaults,
      onChanged: (_) {},
      enabled: false,
    );
    for (final tooltip in const [
      'Increase Lives',
      'Decrease Lives',
      'Increase Duration',
      'Decrease Duration',
      'Increase Immunity',
      'Decrease Immunity',
    ]) {
      expect(
        _iconButton(tester, tooltip).onPressed,
        isNull,
        reason: '$tooltip should be disabled',
      );
    }
  });
}

IconButton _iconButton(WidgetTester tester, String tooltip) {
  // `IconButton.tooltip` renders an inner Tooltip widget, so find.byTooltip
  // matches the Tooltip — not the button. Walk up to the IconButton.
  return tester.widget<IconButton>(
    find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(IconButton),
    ),
  );
}

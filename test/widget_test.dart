import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/main.dart';

void main() {
  testWidgets('placeholder home renders the demo button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SnapshotApp());

    expect(find.text('Snapshot — Phase 0'), findsOneWidget);
    expect(find.text('Try onboarding (demo mode)'), findsOneWidget);
  });
}

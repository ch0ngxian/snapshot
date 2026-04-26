import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/models/user_profile.dart';
import 'package:snapshot/onboarding/onboarding_flow.dart';
import 'package:snapshot/services/testing/fake_auth_bootstrap.dart';
import 'package:snapshot/services/testing/in_memory_user_repository.dart';

void main() {
  testWidgets(
    'name → selfie → consent writes a UserProfile and signals onComplete',
    (tester) async {
      final auth = FakeAuthBootstrap(fixedUid: 'user-flow-1');
      final users = InMemoryUserRepository();
      final fakeBytes = Uint8List.fromList(List.generate(64, (i) => i));

      UserProfile? completed;

      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingFlow(
            auth: auth,
            users: users,
            embedder: const FakeFaceEmbedder(),
            now: () => DateTime.utc(2026, 4, 26),
            pickerOverride: () async => fakeBytes,
            onComplete: (p) => completed = p,
          ),
        ),
      );

      // Step 1: name
      await tester.enterText(find.byType(TextField), 'Alex');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Step 2: selfie (picker override returns deterministic bytes)
      expect(find.text('Selfie'), findsOneWidget);
      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      // Step 3: consent
      expect(find.text('How your data is used'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Finish setup'));
      await tester.pumpAndSettle();

      expect(completed, isNotNull);
      expect(completed!.uid, 'user-flow-1');
      expect(completed!.displayName, 'Alex');
      expect(completed!.embeddingModelVersion, 'fake-v1');
      expect(completed!.faceEmbedding.length, 128);
      expect(completed!.createdAt, DateTime.utc(2026, 4, 26));

      final stored = await users.get('user-flow-1');
      expect(stored, isNotNull);
      expect(stored!.displayName, 'Alex');
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/main.dart';
import 'package:snapshot/services/tag_repository.dart';
import 'package:snapshot/services/testing/fake_auth_bootstrap.dart';
import 'package:snapshot/services/testing/in_memory_active_lobby_store.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';
import 'package:snapshot/services/testing/in_memory_tag_repository.dart';
import 'package:snapshot/services/testing/in_memory_user_repository.dart';
import 'package:snapshot/services/testing/noop_fcm_registrar.dart';
import 'package:snapshot/services/testing/noop_tag_push_listener.dart';

void main() {
  testWidgets(
    'SnapshotApp routes a new user into onboarding',
    (tester) async {
      await tester.pumpWidget(
        SnapshotApp(
          auth: FakeAuthBootstrap(),
          users: InMemoryUserRepository(),
          lobbies: InMemoryLobbyRepository(currentUid: 'fake'),
          tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
          fcm: NoopFcmRegistrar(),
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          buildTagPushListener: (_) => NoopTagPushListener(),
        ),
      );

      // First frame is the boot splash — the FutureBuilder is still resolving.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      // No profile in the repo, so we land on the first onboarding screen.
      expect(find.text('Your name'), findsOneWidget);
    },
  );
}

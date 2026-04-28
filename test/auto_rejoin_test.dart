import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/lobby/round_screen.dart';
import 'package:snapshot/lobby/waiting_room_screen.dart';
import 'package:snapshot/main.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/models/user_profile.dart';
import 'package:snapshot/services/tag_repository.dart';
import 'package:snapshot/services/testing/fake_auth_bootstrap.dart';
import 'package:snapshot/services/testing/in_memory_active_lobby_store.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';
import 'package:snapshot/services/testing/in_memory_tag_repository.dart';
import 'package:snapshot/services/testing/in_memory_user_repository.dart';
import 'package:snapshot/services/testing/noop_fcm_registrar.dart';
import 'package:snapshot/services/testing/noop_tag_push_listener.dart';

UserProfile _profileFor(String uid) => UserProfile(
      uid: uid,
      displayName: 'Alice',
      faceEmbedding: Float32List(128),
      embeddingModelVersion: 'fake-v1',
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  testWidgets('relaunching with a saved waiting lobby resumes into WaitingRoomScreen',
      (tester) async {
    const uid = 'host-1';
    final users = InMemoryUserRepository()..save(_profileFor(uid));
    final lobbies = InMemoryLobbyRepository(currentUid: uid)
      ..registerProfile(uid, displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await lobbies.createLobby();
    // A second player joins so the lobby has the realistic two-player
    // waiting state — not strictly required for the test, just lifelike.
    lobbies.currentUid = 'joiner-1';
    await lobbies.joinLobby(created.code);
    lobbies.currentUid = uid;

    final activeLobbies = InMemoryActiveLobbyStore(current: created.lobbyId);

    await tester.pumpWidget(
      SnapshotApp(
        auth: FakeAuthBootstrap(fixedUid: uid),
        users: users,
        lobbies: lobbies,
        tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
        fcm: NoopFcmRegistrar(),
        embedder: const FakeFaceEmbedder(),
        activeLobbies: activeLobbies,
        buildTagPushListener: (_) => NoopTagPushListener(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WaitingRoomScreen), findsOneWidget);
    expect(activeLobbies.current, created.lobbyId);

    addTearDown(lobbies.dispose);
  });

  testWidgets('relaunching with a saved active lobby resumes into RoundScreen',
      (tester) async {
    const uid = 'host-1';
    final users = InMemoryUserRepository()..save(_profileFor(uid));
    final lobbies = InMemoryLobbyRepository(currentUid: uid)
      ..registerProfile(uid, displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await lobbies.createLobby();
    lobbies.currentUid = 'joiner-1';
    await lobbies.joinLobby(created.code);
    lobbies.currentUid = uid;
    await lobbies.startRound(
      created.lobbyId,
      const LobbyRules(
        startingLives: 3,
        durationSeconds: 600,
        immunitySeconds: 10,
      ),
    );

    final activeLobbies = InMemoryActiveLobbyStore(current: created.lobbyId);

    await tester.pumpWidget(
      SnapshotApp(
        auth: FakeAuthBootstrap(fixedUid: uid),
        users: users,
        lobbies: lobbies,
        tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
        fcm: NoopFcmRegistrar(),
        embedder: const FakeFaceEmbedder(),
        activeLobbies: activeLobbies,
        buildTagPushListener: (_) => NoopTagPushListener(),
      ),
    );
    // RoundScreen runs a 1Hz periodic timer, so pumpAndSettle would loop —
    // pump enough microtasks + frames to land on RoundScreen instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(RoundScreen), findsOneWidget);
    expect(activeLobbies.current, created.lobbyId);

    addTearDown(lobbies.dispose);
  });

  testWidgets('relaunching with a saved ENDED lobby clears the hint and lands on home',
      (tester) async {
    const uid = 'host-1';
    final users = InMemoryUserRepository()..save(_profileFor(uid));
    final lobbies = InMemoryLobbyRepository(currentUid: uid)
      ..registerProfile(uid, displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await lobbies.createLobby();
    lobbies.currentUid = 'joiner-1';
    await lobbies.joinLobby(created.code);
    lobbies.currentUid = uid;
    await lobbies.startRound(created.lobbyId, LobbyRules.defaults);
    await lobbies.endRound(created.lobbyId);

    final activeLobbies = InMemoryActiveLobbyStore(current: created.lobbyId);

    await tester.pumpWidget(
      SnapshotApp(
        auth: FakeAuthBootstrap(fixedUid: uid),
        users: users,
        lobbies: lobbies,
        tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
        fcm: NoopFcmRegistrar(),
        embedder: const FakeFaceEmbedder(),
        activeLobbies: activeLobbies,
        buildTagPushListener: (_) => NoopTagPushListener(),
      ),
    );
    await tester.pumpAndSettle();

    // Home screen — the "Create lobby" CTA is the load-bearing tell.
    expect(find.text('Create lobby'), findsOneWidget);
    expect(find.byType(WaitingRoomScreen), findsNothing);
    expect(find.byType(RoundScreen), findsNothing);
    expect(activeLobbies.current, isNull);

    addTearDown(lobbies.dispose);
  });

  testWidgets('relaunching with no saved lobby goes straight to home',
      (tester) async {
    const uid = 'host-1';
    final users = InMemoryUserRepository()..save(_profileFor(uid));
    final lobbies = InMemoryLobbyRepository(currentUid: uid)
      ..registerProfile(uid, displayName: 'Alice');

    final activeLobbies = InMemoryActiveLobbyStore();

    await tester.pumpWidget(
      SnapshotApp(
        auth: FakeAuthBootstrap(fixedUid: uid),
        users: users,
        lobbies: lobbies,
        tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
        fcm: NoopFcmRegistrar(),
        embedder: const FakeFaceEmbedder(),
        activeLobbies: activeLobbies,
        buildTagPushListener: (_) => NoopTagPushListener(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Create lobby'), findsOneWidget);
    expect(find.byType(WaitingRoomScreen), findsNothing);

    addTearDown(lobbies.dispose);
  });
}

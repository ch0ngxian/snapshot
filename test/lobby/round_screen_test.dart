import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/camera/round_camera.dart';
import 'package:snapshot/camera/testing/fake_round_camera.dart';
import 'package:snapshot/face/face_embedder.dart';
import 'package:snapshot/face/no_face_detected_exception.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/lobby/round_results_screen.dart';
import 'package:snapshot/lobby/round_screen.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/models/lobby_player.dart';
import 'package:snapshot/services/lobby_repository.dart';
import 'package:snapshot/services/tag_repository.dart';
import 'package:snapshot/services/testing/in_memory_active_lobby_store.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';
import 'package:snapshot/services/testing/in_memory_tag_repository.dart';

Future<({InMemoryLobbyRepository repo, String lobbyId})> _activeLobby({
  int durationSeconds = 60,
}) async {
  final repo = InMemoryLobbyRepository(currentUid: 'host-1')
    ..registerProfile('host-1', displayName: 'Alice')
    ..registerProfile('joiner-1', displayName: 'Bob');
  final created = await repo.createLobby();
  repo.currentUid = 'joiner-1';
  await repo.joinLobby(created.code);
  repo.currentUid = 'host-1';
  await repo.startRound(
    created.lobbyId,
    LobbyRules(
      startingLives: 3,
      durationSeconds: durationSeconds,
      immunitySeconds: 10,
    ),
  );
  return (repo: repo, lobbyId: created.lobbyId);
}

/// Pump enough times for microtasks + a few animation frames to settle,
/// but not far enough to trip [RoundScreen]'s 1 Hz countdown ticker.
/// `pumpAndSettle` would otherwise loop forever — every tick scheduled
/// by the periodic timer keeps re-arming the settle-loop.
Future<void> _settleShortOf1s(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Bytes the [FakeFaceEmbedder] hashes deterministically — content
/// doesn't matter as long as it's non-empty (the fake hashes anything).
final Uint8List _fakeJpegBytes = Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]);

/// Factory that hands the screen a [FakeRoundCamera] preloaded with
/// [bytes] on shutter capture. Returning a single instance per call is
/// fine — the screen only constructs one camera per mount.
RoundCamera Function() _fakeCameraReturning(Uint8List? bytes) {
  return () => FakeRoundCamera(framePayload: bytes);
}

void main() {
  testWidgets('renders countdown, lives hearts, and alive count', (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime(2026, 1, 1, 12));
    final now = DateTime(2026, 1, 1, 12, 0, 30);
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // 60s round, 30s elapsed → 30s remaining.
    expect(find.text('00:30'), findsOneWidget);
    // 3 starting lives, none lost yet → 3 filled hearts, 0 outlines.
    expect(find.byIcon(Icons.favorite), findsNWidgets(3));
    expect(find.byIcon(Icons.favorite_border), findsNothing);
    // Opponents-alive badge: 1 opponent.
    expect(find.text('1'), findsOneWidget);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets('shutter → hit → toast shows + lives reflect', (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue([
      const TagSubmission(
        result: TagResult.hit,
        retainPhoto: false,
        tagId: '__placeholder__',
        victimLivesRemaining: 2,
        eliminated: false,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);

    expect(tags.submissions, hasLength(1));
    expect(tags.submissions.single.lobbyId, ctx.lobbyId);
    expect(tags.submissions.single.modelVersion, 'fake-v1');
    expect(tags.submissions.single.embeddingLength, 128);
    expect(find.textContaining('Hit'), findsOneWidget);
    expect(find.textContaining('2 lives'), findsOneWidget);
    // retainPhoto was false → no upload.
    expect(tags.uploads, isEmpty);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets('tap-to-fire bottom zone fires the same as the shutter',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue([
      const TagSubmission(
        result: TagResult.noMatch,
        retainPhoto: false,
        tagId: '__placeholder__',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.tapToFireKey));
    await _settleShortOf1s(tester);

    expect(tags.submissions, hasLength(1));
    expect(find.textContaining('No match'), findsOneWidget);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'shutter → no_match (borderline / retainPhoto=true) → photo is uploaded',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue([
      const TagSubmission(
        result: TagResult.noMatch,
        retainPhoto: true,
        tagId: '__placeholder__',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);

    expect(find.textContaining('No match'), findsOneWidget);
    expect(tags.uploads, hasLength(1));
    expect(tags.uploads.single.lobbyId, ctx.lobbyId);
    // tagId echoed back from the submission round-trips through the repo.
    expect(tags.uploads.single.tagId, tags.submissions.single.tagId);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'shutter → no face detected → local toast, submitTag is NOT called',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(
            throwOnEmbed: NoFaceDetectedException(),
          ),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);

    expect(find.textContaining('No face detected'), findsOneWidget);
    expect(tags.submissions, isEmpty);
    expect(tags.uploads, isEmpty);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'shutter → camera not ready (captureFrame returns null) → no submission, no toast',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);

    expect(tags.submissions, isEmpty);
    expect(find.textContaining('No match'), findsNothing);
    expect(find.textContaining('Hit'), findsNothing);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets('calls endRound when the timer expires and routes to results',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(
      ctx.lobbyId,
      DateTime.now().subtract(const Duration(seconds: 120)),
    );
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RoundResultsScreen), findsOneWidget);
    addTearDown(ctx.repo.dispose);
  });

  testWidgets('shows unavailable when watchLobby errors', (tester) async {
    final repo = _ErroringRepo();
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: 'lobby-x',
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Round unavailable'), findsOneWidget);
    expect(repo.endRoundCalls, isEmpty);
  });

  testWidgets('shows unavailable when the lobby disappears mid-round',
      (tester) async {
    final repo = _DeletingRepo();
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: 'lobby-x',
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Round unavailable'), findsOneWidget);
    expect(repo.endRoundCalls, isEmpty);
  });

  testWidgets("doesn't end the round when startedAt hasn't propagated",
      (tester) async {
    final repo = _ActiveButNoStartedAtRepo();
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: 'lobby-x',
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(repo.endRoundCalls, isEmpty);
  });

  testWidgets(
      'cooldown gates a second shot for 5s after a server verdict',
      (tester) async {
    final ctx = await _activeLobby();
    var now = DateTime(2026, 1, 1, 12);
    ctx.repo.debugForceStartedAt(ctx.lobbyId, now);
    final tags = InMemoryTagRepository.fromQueue(const [
      TagSubmission(
        result: TagResult.noMatch,
        retainPhoto: false,
        tagId: '__placeholder__',
      ),
      TagSubmission(
        result: TagResult.noMatch,
        retainPhoto: false,
        tagId: '__placeholder__',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
          clock: () => now,
        ),
      ),
    );
    await _settleShortOf1s(tester);

    // First tap fires.
    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);
    expect(tags.submissions, hasLength(1));

    // 2s later — still inside the 5s cooldown window. Tap is a no-op.
    now = now.add(const Duration(seconds: 2));
    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);
    expect(tags.submissions, hasLength(1));

    // 6s past the first fire — cooldown drained. Pump enough fake time
    // for the 1Hz round ticker to drive the setState that re-evaluates
    // _onCooldown, then tap again.
    now = now.add(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);
    expect(tags.submissions, hasLength(2));

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'no-face short-circuit does NOT engage the shutter cooldown',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue(const [
      TagSubmission(
        result: TagResult.hit,
        retainPhoto: false,
        tagId: '__placeholder__',
        victimLivesRemaining: 2,
        eliminated: false,
      ),
    ]);

    // First call to embed throws no-face; subsequent calls succeed —
    // simulates the user re-aiming after a "no face detected" toast.
    final embedder = _NoFaceFirstEmbedder(const FakeFaceEmbedder());
    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: embedder,
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    // First tap → no face detected, no submission, no cooldown.
    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);
    expect(tags.submissions, isEmpty);
    expect(find.textContaining('No face detected'), findsOneWidget);

    // Immediate second tap — should fire because cooldown wasn't engaged.
    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);
    expect(tags.submissions, hasLength(1));
    expect(find.textContaining('Hit'), findsOneWidget);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'cooldown verdict does not surface a redundant toast',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue(const [
      TagSubmission(
        result: TagResult.cooldown,
        retainPhoto: false,
        tagId: '__placeholder__',
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: _fakeCameraReturning(_fakeJpegBytes),
        ),
      ),
    );
    await _settleShortOf1s(tester);

    await tester.tap(find.byKey(RoundScreen.shutterKey));
    await _settleShortOf1s(tester);

    expect(tags.submissions, hasLength(1));
    // The ring is the visual cue — toast suppressed (GAMEPLAY.md §107).
    expect(find.textContaining('Slow down'), findsNothing);
    expect(find.textContaining('cooldown'), findsNothing);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets(
      'timer color ramps white → amber → red as remaining time drops',
      (tester) async {
    Future<Color?> colorAtRemaining({
      required int durationSeconds,
      required int remainingSeconds,
    }) async {
      final ctx = await _activeLobby(durationSeconds: durationSeconds);
      final start = DateTime(2026, 1, 1, 12);
      ctx.repo.debugForceStartedAt(ctx.lobbyId, start);
      final now = start.add(
        Duration(seconds: durationSeconds - remainingSeconds),
      );
      addTearDown(ctx.repo.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RoundScreen(
            repo: ctx.repo,
            tags: InMemoryTagRepository.fromQueue(const <TagSubmission>[]),
            embedder: const FakeFaceEmbedder(),
            activeLobbies: InMemoryActiveLobbyStore(),
            lobbyId: ctx.lobbyId,
            currentUid: 'host-1',
            cameraFactory: _fakeCameraReturning(null),
            clock: () => now,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      final text = tester.widget<Text>(
        find.byKey(const ValueKey('round-countdown-text')),
      );
      // Pull the screen down so the next iteration's pumpWidget mounts a
      // fresh RoundScreen; otherwise we'd be re-pumping the same one and
      // the timer pulse animation could prevent the test from settling.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 1));
      return text.style?.color;
    }

    // Above 60s → white.
    expect(
      await colorAtRemaining(durationSeconds: 200, remainingSeconds: 120),
      Colors.white,
    );
    // 10s ≤ remaining < 60s → amber.
    expect(
      await colorAtRemaining(durationSeconds: 60, remainingSeconds: 30),
      Colors.amberAccent,
    );
    // < 10s → red.
    expect(
      await colorAtRemaining(durationSeconds: 60, remainingSeconds: 5),
      Colors.redAccent,
    );
  });

  testWidgets('disposes the camera when the screen is unmounted',
      (tester) async {
    final ctx = await _activeLobby();
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
    final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
    final camera = FakeRoundCamera(framePayload: _fakeJpegBytes);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          tags: tags,
          embedder: const FakeFaceEmbedder(),
          activeLobbies: InMemoryActiveLobbyStore(),
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          cameraFactory: () => camera,
        ),
      ),
    );
    await _settleShortOf1s(tester);
    expect(camera.initializeCalls, 1);

    // Replace the route with a blank screen — RoundScreen leaves the
    // tree, dispose() should run.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await _settleShortOf1s(tester);

    expect(camera.disposeCalls, greaterThanOrEqualTo(1));

    addTearDown(ctx.repo.dispose);
  });
}

class _ErroringRepo implements LobbyRepository {
  final List<String> endRoundCalls = [];
  @override
  Future<CreatedLobby> createLobby() async => throw UnimplementedError();
  @override
  Future<String> joinLobby(String code) async => throw UnimplementedError();
  @override
  Future<void> startRound(String id, LobbyRules r) async =>
      throw UnimplementedError();
  @override
  Future<void> endRound(String id) async => endRoundCalls.add(id);
  @override
  Stream<Lobby?> watchLobby(String lobbyId) =>
      Stream<Lobby?>.error(StateError('boom'));
  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) => const Stream.empty();
}

class _DeletingRepo implements LobbyRepository {
  final List<String> endRoundCalls = [];
  @override
  Future<CreatedLobby> createLobby() async => throw UnimplementedError();
  @override
  Future<String> joinLobby(String code) async => throw UnimplementedError();
  @override
  Future<void> startRound(String id, LobbyRules r) async =>
      throw UnimplementedError();
  @override
  Future<void> endRound(String id) async => endRoundCalls.add(id);
  @override
  Stream<Lobby?> watchLobby(String lobbyId) =>
      Stream<Lobby?>.value(null);
  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) => const Stream.empty();
}

/// Wraps a [FaceEmbedder] and throws [NoFaceDetectedException] on the
/// first [embed] call only — every subsequent call delegates straight
/// through. Lets a test exercise the "no face → tap again" flow without
/// having to mount and re-mount different embedder instances.
class _NoFaceFirstEmbedder implements FaceEmbedder {
  final FaceEmbedder _delegate;
  int _calls = 0;
  _NoFaceFirstEmbedder(this._delegate);

  @override
  String get modelVersion => _delegate.modelVersion;

  @override
  int get embeddingDim => _delegate.embeddingDim;

  @override
  Future<Float32List> embed(Uint8List imageBytes) async {
    _calls++;
    if (_calls == 1) throw const NoFaceDetectedException();
    return _delegate.embed(imageBytes);
  }

  @override
  Future<void> close() => _delegate.close();
}

class _ActiveButNoStartedAtRepo implements LobbyRepository {
  final List<String> endRoundCalls = [];
  @override
  Future<CreatedLobby> createLobby() async => throw UnimplementedError();
  @override
  Future<String> joinLobby(String code) async => throw UnimplementedError();
  @override
  Future<void> startRound(String id, LobbyRules r) async =>
      throw UnimplementedError();
  @override
  Future<void> endRound(String id) async => endRoundCalls.add(id);
  @override
  Stream<Lobby?> watchLobby(String lobbyId) => Stream<Lobby?>.value(
        Lobby(
          lobbyId: lobbyId,
          code: 'ABC123',
          hostUid: 'host-1',
          status: LobbyStatus.active,
          rules: LobbyRules.defaults,
          createdAt: DateTime.now(),
          // startedAt deliberately null — server transaction in flight.
        ),
      );
  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) => const Stream.empty();
}

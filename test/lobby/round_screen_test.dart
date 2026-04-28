import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/camera/round_camera.dart';
import 'package:snapshot/camera/testing/fake_round_camera.dart';
import 'package:snapshot/face/face_embedder.dart';
import 'package:snapshot/face/face_tracker.dart';
import 'package:snapshot/face/no_face_detected_exception.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/face/testing/fake_face_tracker.dart';
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

/// Factory that hands the screen a fresh [FakeFaceTracker]. The tests
/// that don't care about the reticle just want isolation from the
/// real ML Kit-backed tracker; tests that *do* want to drive the
/// reticle capture the instance via [_capturingTrackerFactory].
FaceTracker Function(RoundCamera) _fakeTrackerFactory() =>
    (_) => FakeFaceTracker();

/// Same as [_fakeTrackerFactory] but writes the tracker to [holder]
/// so tests can drive emissions through it.
FaceTracker Function(RoundCamera) _capturingTrackerFactory(
  List<FakeFaceTracker> holder,
) {
  return (_) {
    final tracker = FakeFaceTracker();
    holder.add(tracker);
    return tracker;
  };
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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
            faceTrackerFactory: _fakeTrackerFactory(),
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
          faceTrackerFactory: _fakeTrackerFactory(),
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

  group('face reticle', () {
    testWidgets('hides when no face is tracked', (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
      final captured = <FakeFaceTracker>[];

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
            faceTrackerFactory: _capturingTrackerFactory(captured),
          ),
        ),
      );
      await _settleShortOf1s(tester);
      // Tracker is wired up and started by the time the camera resolves.
      expect(captured, hasLength(1));
      expect(captured.single.startCalls, 1);

      // No emissions yet → no reticle in the tree.
      expect(find.byKey(const ValueKey('round-face-reticle')), findsNothing);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('renders a white reticle while a face is tracked',
        (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
      final captured = <FakeFaceTracker>[];

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
            faceTrackerFactory: _capturingTrackerFactory(captured),
          ),
        ),
      );
      await _settleShortOf1s(tester);

      captured.single.emit(const TrackedFace(
        normalizedBounds: Rect.fromLTRB(0.4, 0.35, 0.6, 0.55),
        aimLocked: false,
      ));
      await _settleShortOf1s(tester);

      final reticle = find.byKey(const ValueKey('round-face-reticle'));
      expect(reticle, findsOneWidget);
      final container = tester.widget<AnimatedContainer>(reticle);
      final decoration = container.decoration as BoxDecoration?;
      expect(decoration?.border?.top.color, Colors.white);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('flips the reticle to green when aim-locked', (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
      final captured = <FakeFaceTracker>[];

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
            faceTrackerFactory: _capturingTrackerFactory(captured),
          ),
        ),
      );
      await _settleShortOf1s(tester);

      captured.single.emit(const TrackedFace(
        normalizedBounds: Rect.fromLTRB(0.42, 0.4, 0.58, 0.6),
        aimLocked: true,
      ));
      await _settleShortOf1s(tester);

      final container = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('round-face-reticle')),
      );
      final decoration = container.decoration as BoxDecoration?;
      expect(decoration?.border?.top.color, Colors.greenAccent);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('clears the reticle when the tracker emits null',
        (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
      final captured = <FakeFaceTracker>[];

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
            faceTrackerFactory: _capturingTrackerFactory(captured),
          ),
        ),
      );
      await _settleShortOf1s(tester);

      captured.single.emit(const TrackedFace(
        normalizedBounds: Rect.fromLTRB(0.4, 0.35, 0.6, 0.55),
        aimLocked: false,
      ));
      await _settleShortOf1s(tester);
      expect(find.byKey(const ValueKey('round-face-reticle')), findsOneWidget);

      captured.single.emitNone();
      await _settleShortOf1s(tester);
      expect(find.byKey(const ValueKey('round-face-reticle')), findsNothing);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('stops + disposes the tracker when the screen unmounts',
        (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      final tags = InMemoryTagRepository.fromQueue(const <TagSubmission>[]);
      final captured = <FakeFaceTracker>[];

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
            faceTrackerFactory: _capturingTrackerFactory(captured),
          ),
        ),
      );
      await _settleShortOf1s(tester);
      expect(captured.single.disposeCalls, 0);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settleShortOf1s(tester);

      expect(captured.single.disposeCalls, greaterThanOrEqualTo(1));

      addTearDown(ctx.repo.dispose);
    });
  });

  group('"you got hit" feedback', () {
    testWidgets(
        'no flash on initial mount even when player joins mid-hit',
        (tester) async {
      // Initial subscription replays the player's CURRENT lives.
      // Auto-rejoin after a relaunch lands here with a possibly
      // already-reduced lives count — we should NOT flash on that.
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      // Pre-stage a hit so the very first players emission arrives
      // with lives=2, not 3. Without the "first emission seeds the
      // baseline" guard the screen would immediately flash on mount.
      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1');

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
            faceTrackerFactory: _fakeTrackerFactory(),
          ),
        ),
      );
      await _settleShortOf1s(tester);

      expect(find.byKey(const ValueKey('round-hit-flash')), findsNothing);
      expect(find.byKey(const ValueKey('round-pulsing-heart')), findsNothing);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('lives drop → flash + pulsing heart appear', (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());

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
            faceTrackerFactory: _fakeTrackerFactory(),
          ),
        ),
      );
      await _settleShortOf1s(tester);
      // Baseline: 3 lives, no flash, no pulse.
      expect(find.byIcon(Icons.favorite), findsNWidgets(3));
      expect(find.byKey(const ValueKey('round-hit-flash')), findsNothing);
      expect(find.byKey(const ValueKey('round-pulsing-heart')), findsNothing);

      // Server-side: a hit lands. Lives drop from 3 → 2.
      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1');
      // Two pumps without advancing time so the players-stream microtask
      // fires AND the resulting setState rebuild lands AND the
      // animation controllers tick at least one frame past their
      // initial value=0 paint.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byKey(const ValueKey('round-hit-flash')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('round-pulsing-heart')),
        findsOneWidget,
      );
      // Lives row is now 2 filled + 1 outline; the lost heart's slot
      // shows the static outline behind the pulsing ghost.
      expect(find.byIcon(Icons.favorite), findsNWidgets(3));
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);

      // Animation completes — overlay clears.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('round-hit-flash')), findsNothing);
      expect(find.byKey(const ValueKey('round-pulsing-heart')), findsNothing);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('elimination (lives 1 → 0) still triggers flash',
        (tester) async {
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());
      // Pre-bring host down to 1 life so the next hit eliminates them.
      // Initial subscription seeds the baseline at 1, so no flash yet.
      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1', livesLost: 2);

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
            faceTrackerFactory: _fakeTrackerFactory(),
          ),
        ),
      );
      await _settleShortOf1s(tester);
      expect(find.byKey(const ValueKey('round-hit-flash')), findsNothing);

      // Knock-out hit. Status flips to eliminated and lives → 0.
      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byKey(const ValueKey('round-hit-flash')), findsOneWidget);
      // OUT badge appears once status is eliminated.
      expect(find.text('OUT'), findsOneWidget);

      addTearDown(ctx.repo.dispose);
    });

    testWidgets('repeat hit during animation re-arms the flash',
        (tester) async {
      // Server immunity makes back-to-back hits rare in practice, but
      // the animation re-key should cope with it: a fresh hit-event
      // with a later timestamp should restart the flash from full
      // intensity rather than letting the in-flight one drift.
      final ctx = await _activeLobby();
      ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime.now());

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
            faceTrackerFactory: _fakeTrackerFactory(),
          ),
        ),
      );
      await _settleShortOf1s(tester);

      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const ValueKey('round-hit-flash')), findsOneWidget);

      // Mid-flash, another hit lands.
      await tester.pump(const Duration(milliseconds: 100));
      ctx.repo.debugApplyHit(ctx.lobbyId, 'host-1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // Flash is still on screen — re-armed against the fresh event.
      expect(find.byKey(const ValueKey('round-hit-flash')), findsOneWidget);

      addTearDown(ctx.repo.dispose);
    });
  });

  group('coverFitRect', () {
    test('matching aspect ratio → identity scaling', () {
      final r = coverFitRect(
        normalizedBounds: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
        previewAspectRatio: 9 / 16,
        screenSize: const Size(450, 800),
      )!;
      // Preview AR 9/16 == screen AR 450/800 → no crop, no scale.
      expect(r.left, closeTo(0.4 * 450, 1e-9));
      expect(r.top, closeTo(0.4 * 800, 1e-9));
      expect(r.width, closeTo(0.2 * 450, 1e-9));
      expect(r.height, closeTo(0.2 * 800, 1e-9));
    });

    test('preview wider than screen → fit height, crop sides', () {
      // Preview AR 16/9, screen 9/16 (very tall) — preview gets blown
      // up to fill height (800), width overflows past the screen and
      // is cropped equally on each side. A face centered horizontally
      // in preview space stays centered horizontally on screen.
      final r = coverFitRect(
        normalizedBounds: const Rect.fromLTRB(0.45, 0.45, 0.55, 0.55),
        previewAspectRatio: 16 / 9,
        screenSize: const Size(450, 800),
      )!;
      expect(r.center.dx, closeTo(450 / 2, 1e-6));
      expect(r.center.dy, closeTo(800 / 2, 1e-6));
      // height = 0.1 * renderedH = 0.1 * 800 = 80
      expect(r.height, closeTo(80, 1e-6));
      // width = 0.1 * renderedW where renderedW = 800 * 16/9 ≈ 1422
      expect(r.width, closeTo(0.1 * 800 * 16 / 9, 1e-6));
    });

    test('preview taller than screen → fit width, crop top+bottom', () {
      final r = coverFitRect(
        normalizedBounds: const Rect.fromLTRB(0.45, 0.45, 0.55, 0.55),
        previewAspectRatio: 9 / 16,
        screenSize: const Size(800, 450),
      )!;
      // Centered face stays centered.
      expect(r.center.dx, closeTo(800 / 2, 1e-6));
      expect(r.center.dy, closeTo(450 / 2, 1e-6));
      // width = 0.1 * renderedW = 0.1 * 800 = 80
      expect(r.width, closeTo(80, 1e-6));
      // height = 0.1 * renderedH where renderedH = 800 / (9/16)
      expect(r.height, closeTo(0.1 * 800 / (9 / 16), 1e-6));
    });

    test('zero-area placement → null', () {
      final r = coverFitRect(
        normalizedBounds: const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5),
        previewAspectRatio: 9 / 16,
        screenSize: const Size(450, 800),
      );
      expect(r, isNull);
    });

    test('clamps when the box overhangs the visible region', () {
      // Off-center face that reaches past the right edge — should
      // still fit horizontally, with its right edge clamped to the
      // screen width.
      final r = coverFitRect(
        normalizedBounds: const Rect.fromLTRB(0.9, 0.4, 1.2, 0.6),
        previewAspectRatio: 9 / 16,
        screenSize: const Size(450, 800),
      )!;
      expect(r.right, closeTo(450, 1e-6));
    });
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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/lobby/round_results_screen.dart';
import 'package:snapshot/lobby/round_screen.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

Future<({InMemoryLobbyRepository repo, String lobbyId})> _activeLobby() async {
  final repo = InMemoryLobbyRepository(currentUid: 'host-1')
    ..registerProfile('host-1', displayName: 'Alice')
    ..registerProfile('joiner-1', displayName: 'Bob');
  final created = await repo.createLobby();
  repo.currentUid = 'joiner-1';
  await repo.joinLobby(created.code);
  repo.currentUid = 'host-1';
  await repo.startRound(
    created.lobbyId,
    const LobbyRules(
      startingLives: 3,
      durationSeconds: 60,
      immunitySeconds: 10,
    ),
  );
  return (repo: repo, lobbyId: created.lobbyId);
}

void main() {
  testWidgets('renders countdown and alive count', (tester) async {
    final ctx = await _activeLobby();
    // Pin the clock so the displayed countdown is deterministic.
    ctx.repo.debugForceStartedAt(ctx.lobbyId, DateTime(2026, 1, 1, 12));
    final now = DateTime(2026, 1, 1, 12, 0, 30);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
          clock: () => now,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // 60s round, 30s elapsed → 30s remaining.
    expect(find.text('00:30'), findsOneWidget);
    expect(find.text('2 of 2 still alive'), findsOneWidget);

    addTearDown(ctx.repo.dispose);
  });

  testWidgets('calls endRound when the timer expires and routes to results',
      (tester) async {
    final ctx = await _activeLobby();
    // Backdate startedAt so the round is already past expiry from the
    // moment we pump (round is 60s, elapsed = 120s).
    ctx.repo.debugForceStartedAt(
      ctx.lobbyId,
      DateTime.now().subtract(const Duration(seconds: 120)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoundScreen(
          repo: ctx.repo,
          lobbyId: ctx.lobbyId,
          currentUid: 'host-1',
        ),
      ),
    );
    // First frame fires _maybeEnd via the StreamBuilder rebuild — let it
    // settle, the repo flips to ended, and the post-frame routes us.
    await tester.pumpAndSettle();

    expect(find.byType(RoundResultsScreen), findsOneWidget);
    addTearDown(ctx.repo.dispose);
  });
}

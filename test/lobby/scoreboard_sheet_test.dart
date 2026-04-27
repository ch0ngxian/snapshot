import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/lobby/scoreboard_sheet.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

void main() {
  testWidgets('lists every player with lives and "(you)" for the caller',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);
    repo.currentUid = 'host-1';
    await repo.startRound(created.lobbyId, LobbyRules.defaults);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreboardSheet(
          repo: repo,
          lobbyId: created.lobbyId,
          currentUid: 'host-1',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('(you)'), findsOneWidget);
    // 3 starting lives appears twice (Alice + Bob) — match findsNWidgets(2).
    expect(find.text('3'), findsNWidgets(2));
    expect(find.text('Scoreboard'), findsOneWidget);

    addTearDown(repo.dispose);
  });

  testWidgets('renders gracefully when no players have loaded yet',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScoreboardSheet(
          repo: repo,
          lobbyId: 'nonexistent',
          currentUid: 'host-1',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No players in this round.'), findsOneWidget);
    addTearDown(repo.dispose);
  });
}

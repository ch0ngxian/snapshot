import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/lobby/round_results_screen.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

void main() {
  testWidgets('shows every player with their lives left', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);

    await tester.pumpWidget(
      MaterialApp(
        home: RoundResultsScreen(repo: repo, lobbyId: created.lobbyId),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    // Default rules → 3 lives.
    expect(find.text('3 lives left'), findsNWidgets(2));

    addTearDown(repo.dispose);
  });

  testWidgets('back-to-home button pops to the root route', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RoundResultsScreen(
                    repo: repo,
                    lobbyId: created.lobbyId,
                  ),
                )),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(find.text('Round over'), findsOneWidget);

    await tester.tap(find.text('Back to home'));
    await tester.pumpAndSettle();
    expect(find.text('Round over'), findsNothing);
    expect(find.text('home'), findsOneWidget);

    addTearDown(repo.dispose);
  });
}

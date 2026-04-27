import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:snapshot/lobby/round_screen.dart';
import 'package:snapshot/lobby/rules_editor.dart';
import 'package:snapshot/lobby/waiting_room_screen.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

Future<void> _pumpScreen(
  WidgetTester tester, {
  required InMemoryLobbyRepository repo,
  required String lobbyId,
  required String currentUid,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: WaitingRoomScreen(
      repo: repo,
      lobbyId: lobbyId,
      currentUid: currentUid,
    ),
  ));
  // Let stream subscriptions emit their initial values.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('host view shows QR + code + player list + rules editor',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice');
    final created = await repo.createLobby();

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'host-1',
    );

    expect(find.text(created.code), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byType(RulesEditor), findsOneWidget);
    expect(find.text('Need 2 players to start'), findsOneWidget);

    addTearDown(repo.dispose);
  });

  testWidgets('joiner view has no QR, no rules editor, no Start button',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'joiner-1',
    );

    expect(find.text(created.code), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(RulesEditor), findsNothing);
    expect(find.textContaining('Start'), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    addTearDown(repo.dispose);
  });

  testWidgets('player list updates live when someone joins', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'host-1',
    );

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);

    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    addTearDown(repo.dispose);
  });

  testWidgets('Start round is disabled with only 1 player', (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice');
    final created = await repo.createLobby();

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'host-1',
    );

    // The host body is taller than the 800×600 test viewport (QR + rules
    // editor + button), so the SingleChildScrollView keeps the button
    // off-screen until we scroll. The widget is still in the tree —
    // ensureVisible just brings it into the hit-test region.
    await tester.ensureVisible(find.text('Need 2 players to start'));
    await tester.pumpAndSettle();

    // FilledButton.icon returns a private subclass, so byType(FilledButton)
    // misses it — find by the label text and walk up to the button.
    final btn = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Need 2 players to start'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(btn.onPressed, isNull);

    addTearDown(repo.dispose);
  });

  testWidgets(
      'host taps Start with 2 players → calls startRound, routes to RoundScreen',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);
    repo.currentUid = 'host-1';

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'host-1',
    );

    await tester.ensureVisible(find.text('Start round'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start round'));
    await tester.pumpAndSettle();

    expect(find.byType(RoundScreen), findsOneWidget);
    expect(find.byType(WaitingRoomScreen), findsNothing);

    addTearDown(repo.dispose);
  });

  testWidgets('joiner auto-routes to RoundScreen when host starts',
      (tester) async {
    final repo = InMemoryLobbyRepository(currentUid: 'host-1')
      ..registerProfile('host-1', displayName: 'Alice')
      ..registerProfile('joiner-1', displayName: 'Bob');
    final created = await repo.createLobby();
    repo.currentUid = 'joiner-1';
    await repo.joinLobby(created.code);

    await _pumpScreen(
      tester,
      repo: repo,
      lobbyId: created.lobbyId,
      currentUid: 'joiner-1',
    );
    expect(find.byType(WaitingRoomScreen), findsOneWidget);

    repo.currentUid = 'host-1';
    await repo.startRound(created.lobbyId, LobbyRules.defaults);
    await tester.pumpAndSettle();

    expect(find.byType(RoundScreen), findsOneWidget);

    addTearDown(repo.dispose);
  });
}

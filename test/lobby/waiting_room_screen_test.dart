import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:snapshot/lobby/waiting_room_screen.dart';
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
  testWidgets('host view shows QR + code + player list', (tester) async {
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

    addTearDown(repo.dispose);
  });

  testWidgets('joiner view shows code + player list, no QR', (tester) async {
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
}

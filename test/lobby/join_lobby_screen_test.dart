import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/lobby/join_lobby_screen.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/models/lobby_player.dart';
import 'package:snapshot/services/lobby_repository.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

Future<void> _pump(
  WidgetTester tester, {
  required LobbyRepository repo,
  required ValueChanged<String> onJoined,
  Stream<String>? scanStreamOverride,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: JoinLobbyScreen(
      repo: repo,
      onJoined: onJoined,
      scanStreamOverride: scanStreamOverride,
    ),
  ));
}

void main() {
  group('JoinLobbyScreen — manual entry', () {
    testWidgets('joins on a valid 6-char code', (tester) async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice')
        ..registerProfile('joiner-1', displayName: 'Bob');
      final created = await repo.createLobby();
      repo.currentUid = 'joiner-1';

      String? joinedLobbyId;
      await _pump(
        tester,
        repo: repo,
        onJoined: (id) => joinedLobbyId = id,
      );

      await tester.enterText(find.byType(TextField), created.code);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(joinedLobbyId, created.lobbyId);
    });

    testWidgets('shows an error when the code is unknown', (tester) async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice');

      String? joinedLobbyId;
      await _pump(
        tester,
        repo: repo,
        onJoined: (id) => joinedLobbyId = id,
      );

      await tester.enterText(find.byType(TextField), 'ZZZZZZ');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(joinedLobbyId, isNull);
      expect(find.textContaining("couldn't find"), findsOneWidget);
    });

    testWidgets('rejects malformed input before calling the repo', (tester) async {
      final repo = _RecordingRepo();

      await _pump(
        tester,
        repo: repo,
        onJoined: (_) {},
      );

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Join'));
      await tester.pump();

      expect(find.textContaining('6 characters'), findsOneWidget);
      expect(repo.joinCalls, isEmpty);
    });
  });

  group('JoinLobbyScreen — QR scan', () {
    testWidgets('joins when the scanner emits a valid code', (tester) async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice')
        ..registerProfile('joiner-1', displayName: 'Bob');
      final created = await repo.createLobby();
      repo.currentUid = 'joiner-1';

      String? joinedLobbyId;
      final scanController = Stream<String>.fromIterable([created.code]);

      await _pump(
        tester,
        repo: repo,
        onJoined: (id) => joinedLobbyId = id,
        scanStreamOverride: scanController,
      );

      await tester.tap(find.text('Scan QR'));
      await tester.pumpAndSettle();

      expect(joinedLobbyId, created.lobbyId);
    });
  });
}

class _RecordingRepo implements LobbyRepository {
  final List<String> joinCalls = [];
  @override
  Future<CreatedLobby> createLobby() async => throw UnimplementedError();
  @override
  Future<String> joinLobby(String code) async {
    joinCalls.add(code);
    return 'lobby-recorded';
  }
  @override
  Stream<Lobby?> watchLobby(String lobbyId) => const Stream.empty();
  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) => const Stream.empty();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/models/lobby.dart';
import 'package:snapshot/models/lobby_player.dart';
import 'package:snapshot/services/lobby_repository.dart';
import 'package:snapshot/services/testing/in_memory_lobby_repository.dart';

void main() {
  group('InMemoryLobbyRepository', () {
    test('createLobby seeds host as the first player', () async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice');

      final created = await repo.createLobby();
      expect(created.code, matches(RegExp(r'^[A-Z0-9]{6}$')));

      final players = await repo.watchPlayers(created.lobbyId).first;
      expect(players, hasLength(1));
      expect(players.single.uid, 'host-1');
      expect(players.single.displayName, 'Alice');
      expect(players.single.status, LobbyPlayerStatus.alive);

      final lobby = await repo.watchLobby(created.lobbyId).first;
      expect(lobby, isNotNull);
      expect(lobby!.hostUid, 'host-1');
      expect(lobby.status, LobbyStatus.waiting);
    });

    test('joinLobby looks up by code and adds the caller', () async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice')
        ..registerProfile('joiner-1', displayName: 'Bob');
      final created = await repo.createLobby();

      repo.currentUid = 'joiner-1';
      final lobbyId = await repo.joinLobby(created.code);
      expect(lobbyId, created.lobbyId);

      final players = await repo.watchPlayers(created.lobbyId).first;
      expect(players.map((p) => p.uid), containsAll(['host-1', 'joiner-1']));
    });

    test('joinLobby normalizes case and throws on unknown codes', () async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice')
        ..registerProfile('joiner-1', displayName: 'Bob');
      final created = await repo.createLobby();

      repo.currentUid = 'joiner-1';
      final lobbyId = await repo.joinLobby(created.code.toLowerCase());
      expect(lobbyId, created.lobbyId);

      await expectLater(
        repo.joinLobby('ZZZZZZ'),
        throwsA(isA<LobbyNotFoundException>()),
      );
    });

    test('joinLobby is idempotent for an existing player', () async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice');
      final created = await repo.createLobby();

      // Host re-joining their own lobby is a no-op that returns the same id.
      final again = await repo.joinLobby(created.code);
      expect(again, created.lobbyId);
      final players = await repo.watchPlayers(created.lobbyId).first;
      expect(players, hasLength(1));
    });

    test('watchPlayers emits when a new player joins', () async {
      final repo = InMemoryLobbyRepository(currentUid: 'host-1')
        ..registerProfile('host-1', displayName: 'Alice')
        ..registerProfile('joiner-1', displayName: 'Bob');
      final created = await repo.createLobby();

      final stream = repo.watchPlayers(created.lobbyId);
      final emissions = <List<LobbyPlayer>>[];
      final sub = stream.listen(emissions.add);
      // Initial emission is synchronous-ish — pump once for the listener.
      await Future<void>.delayed(Duration.zero);

      repo.currentUid = 'joiner-1';
      await repo.joinLobby(created.code);
      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, greaterThanOrEqualTo(2));
      expect(emissions.last.map((p) => p.uid), containsAll(['host-1', 'joiner-1']));

      await sub.cancel();
    });
  });
}

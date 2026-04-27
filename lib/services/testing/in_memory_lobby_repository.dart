import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../models/lobby.dart';
import '../../models/lobby_player.dart';
import '../lobby_repository.dart';

/// Test-only in-memory [LobbyRepository]. Mirrors the server-side semantics
/// of `createLobby` / `joinLobby` (tech-plan §103, §125):
///   - 6-char base36 code
///   - waiting/active/ended status
///   - idempotent re-join
///   - 20-player cap
///
/// Survives within a single test only.
class InMemoryLobbyRepository implements LobbyRepository {
  static const int maxPlayers = 20;
  static const int _codeLength = 6;
  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// Effective uid for the next [createLobby] / [joinLobby] call. Tests can
  /// reassign this between calls to simulate different callers without
  /// rebuilding the repo.
  String currentUid;

  final Random _rng;
  int _nextLobbySeq = 0;
  final Map<String, _LobbyState> _lobbies = {};
  final Map<String, _Profile> _profiles = {};
  final Map<String, StreamController<Lobby?>> _lobbyControllers = {};
  final Map<String, StreamController<List<LobbyPlayer>>> _playersControllers = {};

  InMemoryLobbyRepository({required this.currentUid, Random? rng})
      : _rng = rng ?? Random();

  /// Pre-seed the in-memory user profile so [createLobby] / [joinLobby] can
  /// snapshot its display name + embedding (the prod repo reads these from
  /// `users/{uid}`).
  void registerProfile(
    String uid, {
    required String displayName,
    Float32List? embedding,
    String embeddingModelVersion = 'mobilefacenet-v1',
  }) {
    _profiles[uid] = _Profile(
      displayName: displayName,
      embedding: embedding ?? Float32List(128),
      embeddingModelVersion: embeddingModelVersion,
    );
  }

  @override
  Future<CreatedLobby> createLobby() async {
    final profile = _profiles[currentUid];
    if (profile == null) {
      throw StateError('no profile registered for $currentUid');
    }
    final lobbyId = 'lobby-${_nextLobbySeq++}';
    final code = _allocateCode();
    final lobby = Lobby(
      lobbyId: lobbyId,
      code: code,
      hostUid: currentUid,
      status: LobbyStatus.waiting,
      rules: LobbyRules.defaults,
      createdAt: DateTime.now(),
    );
    final hostPlayer = _playerFor(currentUid, profile);
    _lobbies[lobbyId] = _LobbyState(lobby: lobby, players: {currentUid: hostPlayer});
    _emitLobby(lobbyId);
    _emitPlayers(lobbyId);
    return CreatedLobby(lobbyId: lobbyId, code: code);
  }

  @override
  Future<String> joinLobby(String code) async {
    final normalized = code.trim().toUpperCase();
    final state = _lobbies.values.firstWhere(
      (s) => s.lobby.code == normalized && s.lobby.status == LobbyStatus.waiting,
      orElse: () => throw LobbyNotFoundException(normalized),
    );
    if (state.players.containsKey(currentUid)) {
      return state.lobby.lobbyId;
    }
    if (state.players.length >= maxPlayers) {
      throw LobbyFullException();
    }
    final profile = _profiles[currentUid];
    if (profile == null) {
      throw StateError('no profile registered for $currentUid');
    }
    state.players[currentUid] = _playerFor(currentUid, profile);
    _emitPlayers(state.lobby.lobbyId);
    return state.lobby.lobbyId;
  }

  @override
  Stream<Lobby?> watchLobby(String lobbyId) {
    final controller = _lobbyControllers.putIfAbsent(
      lobbyId,
      () => StreamController<Lobby?>.broadcast(),
    );
    // Surface the current state on subscription.
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add(_lobbies[lobbyId]?.lobby);
      }
    });
    return controller.stream;
  }

  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) {
    final controller = _playersControllers.putIfAbsent(
      lobbyId,
      () => StreamController<List<LobbyPlayer>>.broadcast(),
    );
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add(_playersOf(lobbyId));
      }
    });
    return controller.stream;
  }

  String _allocateCode() {
    while (true) {
      final candidate = String.fromCharCodes(
        List.generate(_codeLength, (_) => _alphabet.codeUnitAt(_rng.nextInt(_alphabet.length))),
      );
      final taken = _lobbies.values.any(
        (s) => s.lobby.code == candidate && s.lobby.status != LobbyStatus.ended,
      );
      if (!taken) return candidate;
    }
  }

  LobbyPlayer _playerFor(String uid, _Profile profile) => LobbyPlayer(
        uid: uid,
        displayName: profile.displayName,
        livesRemaining: LobbyRules.defaults.startingLives,
        status: LobbyPlayerStatus.alive,
        joinedAt: DateTime.now(),
        embeddingSnapshot: profile.embedding,
        embeddingModelVersion: profile.embeddingModelVersion,
      );

  List<LobbyPlayer> _playersOf(String lobbyId) {
    final state = _lobbies[lobbyId];
    if (state == null) return const [];
    final list = state.players.values.toList()
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return list;
  }

  void _emitLobby(String lobbyId) {
    final controller = _lobbyControllers[lobbyId];
    if (controller != null && !controller.isClosed) {
      controller.add(_lobbies[lobbyId]?.lobby);
    }
  }

  void _emitPlayers(String lobbyId) {
    final controller = _playersControllers[lobbyId];
    if (controller != null && !controller.isClosed) {
      controller.add(_playersOf(lobbyId));
    }
  }

  /// Closes any open streams. Safe to call from `tearDown`.
  Future<void> dispose() async {
    for (final c in _lobbyControllers.values) {
      await c.close();
    }
    for (final c in _playersControllers.values) {
      await c.close();
    }
    _lobbyControllers.clear();
    _playersControllers.clear();
  }
}

class _LobbyState {
  final Lobby lobby;
  final Map<String, LobbyPlayer> players;
  _LobbyState({required this.lobby, required this.players});
}

class _Profile {
  final String displayName;
  final Float32List embedding;
  final String embeddingModelVersion;
  _Profile({
    required this.displayName,
    required this.embedding,
    required this.embeddingModelVersion,
  });
}

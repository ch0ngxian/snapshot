import '../models/lobby.dart';
import '../models/lobby_player.dart';

/// Reads + writes lobby state. Writes are routed through Cloud Functions
/// (createLobby / joinLobby — tech-plan §103/§321) so the client never
/// writes lobby docs directly. Reads stream from Firestore.
abstract class LobbyRepository {
  /// Creates a fresh lobby for the current user. Returns the new lobbyId
  /// + 6-char join code. Caller must already have an onboarded profile.
  Future<CreatedLobby> createLobby();

  /// Joins the lobby identified by [code]. Returns the lobbyId on success.
  /// Idempotent — re-joining a lobby the caller is already in returns the
  /// same lobbyId without rewriting the player doc.
  Future<String> joinLobby(String code);

  /// Streams the lobby document. Emits `null` if the doc doesn't exist
  /// (e.g. the lobby was deleted between joining and subscribing).
  Stream<Lobby?> watchLobby(String lobbyId);

  /// Streams the players subcollection sorted by joinedAt ascending.
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId);
}

/// Result of [LobbyRepository.createLobby].
class CreatedLobby {
  final String lobbyId;
  final String code;
  const CreatedLobby({required this.lobbyId, required this.code});
}

/// Thrown when [LobbyRepository.joinLobby] is called with a code that
/// doesn't match a waiting lobby. UI should surface a "couldn't find
/// that lobby" message.
class LobbyNotFoundException implements Exception {
  final String code;
  LobbyNotFoundException(this.code);
  @override
  String toString() => 'LobbyNotFoundException(code=$code)';
}

/// Thrown when [LobbyRepository.joinLobby] hits the player cap (§125).
class LobbyFullException implements Exception {
  @override
  String toString() => 'LobbyFullException';
}

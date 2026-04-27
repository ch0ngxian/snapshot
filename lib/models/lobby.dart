/// Lobby state document at `lobbies/{lobbyId}`. Schema mirrors tech-plan §98.
///
/// `status` walks waiting → active (on `startRound`, Phase 1 follow-up) →
/// ended (timer expiry / 1 alive). The Phase 1 PR scoped to lobbies + join
/// only needs `waiting`; later transitions add `startedAt` / `endedAt`.
class Lobby {
  final String lobbyId;
  final String code;
  final String hostUid;
  final LobbyStatus status;
  final LobbyRules rules;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const Lobby({
    required this.lobbyId,
    required this.code,
    required this.hostUid,
    required this.status,
    required this.rules,
    required this.createdAt,
    this.startedAt,
    this.endedAt,
  });
}

enum LobbyStatus { waiting, active, ended }

LobbyStatus lobbyStatusFromString(String raw) {
  switch (raw) {
    case 'waiting':
      return LobbyStatus.waiting;
    case 'active':
      return LobbyStatus.active;
    case 'ended':
      return LobbyStatus.ended;
    default:
      throw ArgumentError('unknown lobby status: $raw');
  }
}

/// Default values match `createLobby` (tech-plan §322); host-configurable
/// rules UI lands in a follow-up PR but the wire format is fixed now.
class LobbyRules {
  final int startingLives;
  final int durationSeconds;
  final int immunitySeconds;

  const LobbyRules({
    required this.startingLives,
    required this.durationSeconds,
    required this.immunitySeconds,
  });

  static const LobbyRules defaults = LobbyRules(
    startingLives: 3,
    durationSeconds: 600,
    immunitySeconds: 10,
  );
}

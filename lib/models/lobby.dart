/// Lobby state document at `lobbies/{lobbyId}`. Schema mirrors tech-plan §98.
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
  try {
    return LobbyStatus.values.byName(raw);
  } on ArgumentError {
    throw ArgumentError('unknown lobby status: $raw');
  }
}

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

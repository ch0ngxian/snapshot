import 'dart:typed_data';

/// Per-player state at `lobbies/{lobbyId}/players/{uid}` (tech-plan §99).
/// `embeddingSnapshot` is denormalized from `users/{uid}` at join time so
/// `submitTag` can read all opponents in a single subcollection query (§111).
class LobbyPlayer {
  final String uid;
  final String displayName;
  final int livesRemaining;
  final LobbyPlayerStatus status;
  final DateTime joinedAt;
  final Float32List embeddingSnapshot;
  final String embeddingModelVersion;

  const LobbyPlayer({
    required this.uid,
    required this.displayName,
    required this.livesRemaining,
    required this.status,
    required this.joinedAt,
    required this.embeddingSnapshot,
    required this.embeddingModelVersion,
  });
}

enum LobbyPlayerStatus { alive, eliminated }

LobbyPlayerStatus lobbyPlayerStatusFromString(String raw) {
  try {
    return LobbyPlayerStatus.values.byName(raw);
  } on ArgumentError {
    throw ArgumentError('unknown player status: $raw');
  }
}

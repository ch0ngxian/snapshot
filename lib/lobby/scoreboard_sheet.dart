import 'package:flutter/material.dart';

import '../models/lobby_player.dart';
import '../services/lobby_repository.dart';

/// Live scoreboard surfaced as a swipe-up bottom sheet during a round
/// (tech-plan §80). Subscribes to `lobbies/{id}/players` and re-renders
/// on every change — lives change atomically per submitTag, so the
/// scoreboard reflects each successful hit immediately.
class ScoreboardSheet extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;

  const ScoreboardSheet({
    super.key,
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return StreamBuilder<List<LobbyPlayer>>(
          stream: repo.watchPlayers(lobbyId),
          builder: (context, snap) {
            final players = snap.data ?? const <LobbyPlayer>[];
            // Sort by alive-then-eliminated, then by livesRemaining desc.
            // Players with no lives drop to the bottom; ties hold their
            // join order via the secondary sort key (joinedAt asc).
            final ordered = [...players]..sort((a, b) {
                final aOut = a.status == LobbyPlayerStatus.eliminated;
                final bOut = b.status == LobbyPlayerStatus.eliminated;
                if (aOut != bOut) return aOut ? 1 : -1;
                final lives = b.livesRemaining.compareTo(a.livesRemaining);
                if (lives != 0) return lives;
                return a.joinedAt.compareTo(b.joinedAt);
              });
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Scoreboard',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (ordered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('No players in this round.')),
                  ),
                for (final p in ordered)
                  _ScoreRow(player: p, isMe: p.uid == currentUid),
              ],
            );
          },
        );
      },
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final LobbyPlayer player;
  final bool isMe;
  const _ScoreRow({required this.player, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final eliminated = player.status == LobbyPlayerStatus.eliminated;
    final theme = Theme.of(context);
    final color = eliminated ? theme.disabledColor : theme.colorScheme.onSurface;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: eliminated
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.primaryContainer,
        child: Icon(Icons.person, color: color),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              player.displayName,
              style: TextStyle(
                color: color,
                fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                decoration: eliminated ? TextDecoration.lineThrough : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 6),
            Text(
              '(you)',
              style: TextStyle(color: color, fontSize: 12),
            ),
          ],
        ],
      ),
      trailing: eliminated
          ? const _EliminatedBadge()
          : _LivesBadge(lives: player.livesRemaining),
    );
  }
}

class _LivesBadge extends StatelessWidget {
  final int lives;
  const _LivesBadge({required this.lives});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.favorite, size: 18, color: Colors.redAccent),
        const SizedBox(width: 4),
        Text(
          '$lives',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _EliminatedBadge extends StatelessWidget {
  const _EliminatedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'OUT',
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 1,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

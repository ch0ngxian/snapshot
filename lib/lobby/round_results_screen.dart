import 'package:flutter/material.dart';

import '../models/lobby_player.dart';
import '../services/lobby_repository.dart';

/// End-of-round standings. Phase 1 keeps this minimal — full results
/// (MVP, share button, etc.) are deferred to Phase 3 polish (§335).
class RoundResultsScreen extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;

  const RoundResultsScreen({
    super.key,
    required this.repo,
    required this.lobbyId,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Round over'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Standings',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: StreamBuilder<List<LobbyPlayer>>(
                stream: repo.watchPlayers(lobbyId),
                builder: (context, snap) {
                  final players = (snap.data ?? const <LobbyPlayer>[]).toList()
                    ..sort((a, b) =>
                        b.livesRemaining.compareTo(a.livesRemaining));
                  if (players.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView.separated(
                    itemCount: players.length,
                    separatorBuilder: (_, _) => const Divider(height: 0),
                    itemBuilder: (context, i) {
                      final p = players[i];
                      final eliminated =
                          p.status == LobbyPlayerStatus.eliminated;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              eliminated ? Colors.black26 : null,
                          child: Text('${i + 1}'),
                        ),
                        title: Text(p.displayName),
                        subtitle: Text(
                          eliminated
                              ? 'Eliminated'
                              : '${p.livesRemaining} ${p.livesRemaining == 1 ? "life" : "lives"} left',
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            FilledButton(
              onPressed: () {
                // Pop everything back to the post-onboarding home so a
                // second round starts fresh from LobbyEntryScreen.
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('Back to home'),
            ),
          ],
        ),
      ),
    );
  }
}

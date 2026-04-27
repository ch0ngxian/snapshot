import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/lobby_player.dart';
import '../services/lobby_repository.dart';

/// Pre-round waiting screen. The host sees the QR (so co-located players
/// can scan to join — tech-plan §163) plus the 6-char code as a fallback;
/// joiners see just the code and the live player list.
///
/// Subscribes to [LobbyRepository.watchPlayers] for the live roster. The
/// "Start round" button + rules editor are deferred to the next Phase 1 PR.
class WaitingRoomScreen extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String code;
  final bool isHost;

  /// Optional callback for the joiner's "Leave" button. Phase 1 follow-up
  /// wires real "leave lobby" semantics; for now the screen just surfaces
  /// the affordance via the appbar back button.
  const WaitingRoomScreen({
    super.key,
    required this.repo,
    required this.lobbyId,
    required this.code,
    required this.isHost,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isHost ? 'Your lobby' : 'Waiting for host'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isHost) ...[
              const Text(
                'Have your friends scan this QR to join.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  data: code,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Center(
              child: _CodePill(code: code),
            ),
            const SizedBox(height: 24),
            const Text(
              'Players',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<LobbyPlayer>>(
                stream: repo.watchPlayers(lobbyId),
                builder: (context, snap) {
                  final players = snap.data ?? const <LobbyPlayer>[];
                  if (players.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: players.length,
                    separatorBuilder: (_, _) => const Divider(height: 0),
                    itemBuilder: (context, i) {
                      final p = players[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(p.displayName),
                      );
                    },
                  );
                },
              ),
            ),
            if (isHost)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Start-round button lands in the next Phase 1 PR.',
                  style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CodePill extends StatelessWidget {
  final String code;
  const _CodePill({required this.code});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Copied $code')),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          code,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            letterSpacing: 4,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

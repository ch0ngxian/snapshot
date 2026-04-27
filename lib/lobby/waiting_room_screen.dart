import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/lobby.dart';
import '../models/lobby_player.dart';
import '../services/lobby_repository.dart';

/// Pre-round waiting screen. The host sees the QR (so co-located players
/// can scan to join — tech-plan §163) plus the 6-char code as a fallback;
/// joiners see just the code and the live player list.
class WaitingRoomScreen extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;

  const WaitingRoomScreen({
    super.key,
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Lobby?>(
      stream: repo.watchLobby(lobbyId),
      builder: (context, snap) {
        if (snap.hasError) {
          return _LobbyUnavailable(
            message: 'Unable to load this lobby right now.',
            error: snap.error,
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final lobby = snap.data;
        if (lobby == null) {
          return const _LobbyUnavailable(
            message: "This lobby no longer exists or couldn't be found.",
          );
        }
        final isHost = lobby.hostUid == currentUid;
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
                      data: lobby.code,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Center(child: _CodePill(code: lobby.code)),
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
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LobbyUnavailable extends StatelessWidget {
  final String message;
  final Object? error;
  const _LobbyUnavailable({required this.message, this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lobby unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
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

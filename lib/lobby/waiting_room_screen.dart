import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../camera/round_camera.dart';
import '../face/face_embedder.dart';
import '../models/lobby.dart';
import '../models/lobby_player.dart';
import '../services/active_lobby_store.dart';
import '../services/lobby_repository.dart';
import '../services/tag_repository.dart';
import 'round_screen.dart';
import 'rules_editor.dart';

/// Pre-round waiting screen. The host sees the QR (so co-located players
/// can scan to join — tech-plan §163) plus the 6-char code as a fallback,
/// the live player list, the rules editor, and the Start button. Joiners
/// see just the code and the player list. Both auto-route to
/// [RoundScreen] when the lobby flips to `active`.
class WaitingRoomScreen extends StatefulWidget {
  final LobbyRepository repo;
  final TagRepository tags;
  final FaceEmbedder embedder;
  final ActiveLobbyStore activeLobbies;
  final String lobbyId;
  final String currentUid;
  // Optional test seam — forwarded to [RoundScreen] when the lobby
  // flips to active. Production leaves it null so [RoundScreen] uses
  // its real-camera default.
  final RoundCamera Function()? cameraFactory;

  const WaitingRoomScreen({
    super.key,
    required this.repo,
    required this.tags,
    required this.embedder,
    required this.activeLobbies,
    required this.lobbyId,
    required this.currentUid,
    this.cameraFactory,
  });

  @override
  State<WaitingRoomScreen> createState() => _WaitingRoomScreenState();
}

class _WaitingRoomScreenState extends State<WaitingRoomScreen> {
  // Local copy of the host's chosen rules. Initialized from the lobby doc
  // on first emission, then owned client-side until Start fires it off via
  // `startRound`. Joiners never see the editor, so this stays at defaults
  // for their session.
  LobbyRules? _rules;
  bool _starting = false;
  bool _routedToRound = false;
  bool _clearedOnUnavailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Persist the active lobbyId so a kill-and-relaunch can drop the user
    // back into this screen. We deliberately don't clear on the route to
    // RoundScreen — RoundScreen re-saves on init, keeping the resume hint
    // live across the waiting → active transition.
    unawaited(widget.activeLobbies.save(widget.lobbyId));
  }

  Future<void> _start() async {
    final rules = _rules;
    if (rules == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await widget.repo.startRound(widget.lobbyId, rules);
      // Don't navigate from here — the lobby stream will emit status=active
      // and the post-frame route below will pick it up. Same path host and
      // joiners take, so the routing logic stays in one place.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = "Couldn't start the round: $e";
      });
    }
  }

  void _routeToRound() {
    if (_routedToRound || !mounted) return;
    _routedToRound = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RoundScreen(
          repo: widget.repo,
          tags: widget.tags,
          embedder: widget.embedder,
          activeLobbies: widget.activeLobbies,
          lobbyId: widget.lobbyId,
          currentUid: widget.currentUid,
          cameraFactory: widget.cameraFactory,
        ),
      ),
    );
  }

  void _clearStoredLobbyOnce() {
    if (_clearedOnUnavailable) return;
    _clearedOnUnavailable = true;
    unawaited(widget.activeLobbies.clear());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Lobby?>(
      stream: widget.repo.watchLobby(widget.lobbyId),
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
          // Lobby vanished — drop the resume hint so a relaunch doesn't
          // try to take the user back into a dead lobby.
          _clearStoredLobbyOnce();
          return const _LobbyUnavailable(
            message: "This lobby no longer exists or couldn't be found.",
          );
        }
        // Hydrate the local rules state once we have a lobby snapshot.
        _rules ??= lobby.rules;

        if (lobby.status == LobbyStatus.active) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _routeToRound());
        }

        final isHost = lobby.hostUid == widget.currentUid;
        return Scaffold(
          appBar: AppBar(
            title: Text(isHost ? 'Your lobby' : 'Waiting for host'),
          ),
          body: SingleChildScrollView(
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
                StreamBuilder<List<LobbyPlayer>>(
                  stream: widget.repo.watchPlayers(widget.lobbyId),
                  builder: (context, playersSnap) {
                    final players =
                        playersSnap.data ?? const <LobbyPlayer>[];
                    if (players.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    return Column(
                      children: [
                        for (var i = 0; i < players.length; i++) ...[
                          if (i > 0) const Divider(height: 0),
                          ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.person),
                            ),
                            title: Text(players[i].displayName),
                          ),
                        ],
                        if (isHost) ...[
                          const Divider(),
                          RulesEditor(
                            value: _rules!,
                            enabled: !_starting,
                            onChanged: (next) =>
                                setState(() => _rules = next),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: (_starting || players.length < 2)
                                ? null
                                : _start,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              _starting
                                  ? 'Starting…'
                                  : players.length < 2
                                      ? 'Need 2 players to start'
                                      : 'Start round',
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ],
                    );
                  },
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

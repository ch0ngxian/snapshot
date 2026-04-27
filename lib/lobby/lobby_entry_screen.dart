import 'package:flutter/material.dart';

import '../services/lobby_repository.dart';
import 'join_lobby_screen.dart';
import 'waiting_room_screen.dart';

/// Post-onboarding home. Two primary CTAs — Create or Join — both routing
/// into [WaitingRoomScreen] once the lobby is established.
class LobbyEntryScreen extends StatefulWidget {
  final LobbyRepository repo;
  final String displayName;

  /// Optional extra content rendered below the primary CTAs. The app's
  /// `_Home` slots the debug §314 verification panel here in debug builds;
  /// release builds pass `null`.
  final Widget? child;

  const LobbyEntryScreen({
    super.key,
    required this.repo,
    required this.displayName,
    this.child,
  });

  @override
  State<LobbyEntryScreen> createState() => _LobbyEntryScreenState();
}

class _LobbyEntryScreenState extends State<LobbyEntryScreen> {
  bool _creating = false;
  String? _error;

  Future<void> _createLobby() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final created = await widget.repo.createLobby();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WaitingRoomScreen(
          repo: widget.repo,
          lobbyId: created.lobbyId,
          code: created.code,
          isHost: true,
        ),
      ));
      if (!mounted) return;
      setState(() => _creating = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = "Couldn't create a lobby: $e";
      });
    }
  }

  Future<void> _join() async {
    final lobbyId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => JoinLobbyScreen(
          repo: widget.repo,
          onJoined: (id) => Navigator.of(context).pop(id),
        ),
      ),
    );
    if (lobbyId == null || !mounted) return;
    // We have to look up the lobby's code to display it in the joiner's
    // waiting room. The first emission from `watchLobby` carries it.
    final lobby = await widget.repo.watchLobby(lobbyId).firstWhere(
          (l) => l != null,
        );
    if (lobby == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WaitingRoomScreen(
        repo: widget.repo,
        lobbyId: lobby.lobbyId,
        code: lobby.code,
        isHost: false,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Hi, ${widget.displayName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _creating ? null : _createLobby,
              icon: const Icon(Icons.flag),
              label: Text(_creating ? 'Creating…' : 'Create lobby'),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _creating ? null : _join,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Join a lobby'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (widget.child != null) widget.child!,
          ],
        ),
      ),
    );
  }
}

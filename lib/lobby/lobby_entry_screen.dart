import 'package:flutter/material.dart';

import '../services/lobby_repository.dart';
import 'join_lobby_screen.dart';
import 'waiting_room_screen.dart';

/// Post-onboarding home. Two primary CTAs — Create or Join — both routing
/// into [WaitingRoomScreen] once the lobby is established.
class LobbyEntryScreen extends StatefulWidget {
  final LobbyRepository repo;
  final String currentUid;
  final String displayName;

  /// Optional extra content rendered below the primary CTAs (the §314
  /// verification panel in debug builds).
  final Widget? child;

  const LobbyEntryScreen({
    super.key,
    required this.repo,
    required this.currentUid,
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
          currentUid: widget.currentUid,
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
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WaitingRoomScreen(
        repo: widget.repo,
        lobbyId: lobbyId,
        currentUid: widget.currentUid,
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

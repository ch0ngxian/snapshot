import 'package:flutter/material.dart';

import '../camera/round_camera.dart';
import '../face/face_embedder.dart';
import '../face/face_tracker.dart';
import '../services/active_lobby_store.dart';
import '../services/lobby_repository.dart';
import '../services/tag_repository.dart';
import 'join_lobby_screen.dart';
import 'waiting_room_screen.dart';

/// Post-onboarding home. Two primary CTAs — Create or Join — both routing
/// into [WaitingRoomScreen] once the lobby is established.
class LobbyEntryScreen extends StatefulWidget {
  final LobbyRepository repo;
  final TagRepository tags;
  final FaceEmbedder embedder;
  final ActiveLobbyStore activeLobbies;
  final String currentUid;
  final String displayName;

  /// Optional extra content rendered below the primary CTAs (the §314
  /// verification panel in debug builds).
  final Widget? child;

  /// Optional test seam — passed straight through to [WaitingRoomScreen]
  /// (and by extension to [RoundScreen]) so widget tests can inject a
  /// fake camera.
  final RoundCamera Function()? cameraFactory;
  /// Same idea for the live face tracker.
  final FaceTracker Function(RoundCamera)? faceTrackerFactory;

  const LobbyEntryScreen({
    super.key,
    required this.repo,
    required this.tags,
    required this.embedder,
    required this.activeLobbies,
    required this.currentUid,
    required this.displayName,
    this.child,
    this.cameraFactory,
    this.faceTrackerFactory,
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
          tags: widget.tags,
          embedder: widget.embedder,
          activeLobbies: widget.activeLobbies,
          lobbyId: created.lobbyId,
          currentUid: widget.currentUid,
          cameraFactory: widget.cameraFactory,
          faceTrackerFactory: widget.faceTrackerFactory,
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
        tags: widget.tags,
        embedder: widget.embedder,
        activeLobbies: widget.activeLobbies,
        lobbyId: lobbyId,
        currentUid: widget.currentUid,
        cameraFactory: widget.cameraFactory,
        faceTrackerFactory: widget.faceTrackerFactory,
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

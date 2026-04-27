import 'dart:async';

import 'package:flutter/material.dart';

import '../models/lobby.dart';
import '../models/lobby_player.dart';
import '../services/lobby_repository.dart';
import 'round_results_screen.dart';

/// Phase 1 in-round placeholder. Subscribes to the lobby doc to (a) drive
/// the countdown off `startedAt + durationSeconds` and (b) auto-route to
/// [RoundResultsScreen] when status flips to `ended`. The actual camera +
/// shutter UI is tech-plan §326 — Phase 2.
class RoundScreen extends StatefulWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;

  /// Injectable clock for tests. Production uses [DateTime.now].
  final DateTime Function() clock;

  const RoundScreen({
    super.key,
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  @override
  State<RoundScreen> createState() => _RoundScreenState();
}

class _RoundScreenState extends State<RoundScreen> {
  Timer? _ticker;
  Lobby? _lobby;
  bool _endRequested = false;
  bool _resultsRouted = false;

  @override
  void initState() {
    super.initState();
    // 1Hz tick is enough — display granularity is mm:ss and the
    // expiry-detect path is idempotent server-side anyway.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
    final lobby = _lobby;
    if (lobby != null) _maybeEnd(lobby);
  }

  Duration _remaining(Lobby lobby) {
    final startedAt = lobby.startedAt;
    if (startedAt == null) return Duration.zero;
    final endsAt = startedAt.add(Duration(seconds: lobby.rules.durationSeconds));
    final delta = endsAt.difference(widget.clock());
    return delta.isNegative ? Duration.zero : delta;
  }

  Future<void> _maybeEnd(Lobby lobby) async {
    if (_endRequested) return;
    if (lobby.status != LobbyStatus.active) return;
    if (_remaining(lobby) > Duration.zero) return;
    _endRequested = true;
    try {
      await widget.repo.endRound(widget.lobbyId);
    } catch (_) {
      // Idempotent on the server. If it failed, the next tick will retry
      // when whichever client wins the race flips status to ended (or, in
      // a true outage, when status drops back to active and the timer is
      // already past expiry).
      _endRequested = false;
    }
  }

  void _routeToResults() {
    if (_resultsRouted || !mounted) return;
    _resultsRouted = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RoundResultsScreen(
          repo: widget.repo,
          lobbyId: widget.lobbyId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Lobby?>(
      stream: widget.repo.watchLobby(widget.lobbyId),
      builder: (context, lobbySnap) {
        final lobby = lobbySnap.data;
        if (lobby != null) {
          _lobby = lobby;
          if (lobby.status == LobbyStatus.ended) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _routeToResults());
          } else {
            // Drive expiry detection off lobby updates too (not just the
            // 1Hz ticker) so a state change like the host bumping duration
            // — Phase 2+ if it's ever added — re-evaluates immediately.
            _maybeEnd(lobby);
          }
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Round in progress'),
            automaticallyImplyLeading: false,
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Countdown(remaining: lobby == null ? null : _remaining(lobby)),
                const SizedBox(height: 24),
                _AliveCount(repo: widget.repo, lobbyId: widget.lobbyId),
                const Spacer(),
                const _CameraPlaceholder(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Countdown extends StatelessWidget {
  final Duration? remaining;
  const _Countdown({required this.remaining});

  @override
  Widget build(BuildContext context) {
    final r = remaining ?? Duration.zero;
    final mm = r.inMinutes.toString().padLeft(2, '0');
    final ss = (r.inSeconds % 60).toString().padLeft(2, '0');
    return Center(
      child: Text(
        '$mm:$ss',
        style: const TextStyle(
          fontSize: 64,
          fontWeight: FontWeight.bold,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _AliveCount extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;
  const _AliveCount({required this.repo, required this.lobbyId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LobbyPlayer>>(
      stream: repo.watchPlayers(lobbyId),
      builder: (context, snap) {
        final players = snap.data ?? const <LobbyPlayer>[];
        final alive = players
            .where((p) => p.status == LobbyPlayerStatus.alive)
            .length;
        return Center(
          child: Text(
            '$alive of ${players.length} still alive',
            style: const TextStyle(fontSize: 16),
          ),
        );
      },
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder();

  @override
  Widget build(BuildContext context) {
    // The shutter / capture UI lands in Phase 2 (§326). For Phase 1 the
    // round screen exists so we can validate the timer + end-of-round
    // transition independently — keeping these phases separate so the
    // tag mechanic doesn't slip into the "lobby lifecycle" PR.
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.photo_camera_outlined, size: 40),
          SizedBox(height: 12),
          Text(
            'Camera shutter coming in Phase 2.',
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 4),
          Text(
            'For now the round just runs out the clock.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

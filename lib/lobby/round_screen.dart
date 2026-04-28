import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../face/face_embedder.dart';
import '../face/no_face_detected_exception.dart';
import '../models/lobby.dart';
import '../models/lobby_player.dart';
import '../services/active_lobby_store.dart';
import '../services/lobby_repository.dart';
import '../services/tag_id.dart';
import '../services/tag_repository.dart';
import 'round_results_screen.dart';
import 'scoreboard_sheet.dart';

/// In-round screen — primary surface during an active lobby. Renders the
/// timer, lives, alive count, a shutter button (tech-plan §72-§78), and
/// surfaces tag verdicts as toasts. Subscribes to the lobby doc to (a)
/// drive the countdown off `startedAt + durationSeconds` and (b) auto-
/// route to [RoundResultsScreen] when status flips to `ended`.
class RoundScreen extends StatefulWidget {
  final LobbyRepository repo;
  final TagRepository tags;
  final FaceEmbedder embedder;
  final ActiveLobbyStore activeLobbies;
  final String lobbyId;
  final String currentUid;

  /// Injectable shutter so widget tests can stub the camera path without
  /// a real platform channel + file system. Returns the captured JPEG
  /// bytes, or `null` if the user backed out of the camera. Production
  /// uses [ImagePicker.pickImage] and `File.readAsBytes`.
  final Future<Uint8List?> Function() pickPhoto;

  /// Injectable clock for tests. Production uses [DateTime.now].
  final DateTime Function() clock;

  // Cannot be `const` — the defaulting for `pickPhoto`/`clock` runs at
  // construction time, which is non-const.
  // ignore: prefer_const_constructors_in_immutables
  RoundScreen({
    super.key,
    required this.repo,
    required this.tags,
    required this.embedder,
    required this.activeLobbies,
    required this.lobbyId,
    required this.currentUid,
    Future<Uint8List?> Function()? pickPhoto,
    DateTime Function()? clock,
  })  : pickPhoto = pickPhoto ?? _defaultPickPhoto,
        clock = clock ?? DateTime.now;

  static Future<Uint8List?> _defaultPickPhoto() async {
    // image_picker over a custom in-app camera preview is a deliberate v1
    // trade-off: ~500ms hand-off latency for system camera, vs the much
    // larger surface of CameraController + lifecycle management. Re-visit
    // for v2 polish (an embedded viewfinder is what the plan describes).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (picked == null) return null;
    return File(picked.path).readAsBytes();
  }

  @override
  State<RoundScreen> createState() => _RoundScreenState();
}

class _RoundScreenState extends State<RoundScreen> {
  Timer? _ticker;
  Lobby? _lobby;
  bool _endRequested = false;
  bool _resultsRouted = false;
  bool _shooting = false;
  _Toast? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    // 1Hz tick is enough — display granularity is mm:ss and the
    // expiry-detect path is idempotent server-side anyway.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // Re-save defensively. WaitingRoomScreen already wrote this on the
    // create/join path, but auto-rejoin lands here directly when the
    // saved lobby is already `active`, so refresh the hint either way.
    unawaited(widget.activeLobbies.save(widget.lobbyId));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
    final lobby = _lobby;
    if (lobby != null) _maybeEnd(lobby);
  }

  Duration? _remaining(Lobby lobby) {
    final startedAt = lobby.startedAt;
    if (startedAt == null) return null;
    final endsAt = startedAt.add(Duration(seconds: lobby.rules.durationSeconds));
    final delta = endsAt.difference(widget.clock());
    return delta.isNegative ? Duration.zero : delta;
  }

  Future<void> _maybeEnd(Lobby lobby) async {
    if (_endRequested) return;
    if (lobby.status != LobbyStatus.active) return;
    final remaining = _remaining(lobby);
    // Don't try to end if `startedAt` hasn't propagated yet — the round
    // hasn't actually begun from the server's POV, so calling endRound
    // would just trip the active→ended precondition check.
    if (remaining == null) return;
    if (remaining > Duration.zero) return;
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
    // Round is over — drop the resume hint so a relaunch lands on the
    // home screen, not back on a finished round.
    unawaited(widget.activeLobbies.clear());
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RoundResultsScreen(
          repo: widget.repo,
          lobbyId: widget.lobbyId,
        ),
      ),
    );
  }

  Future<void> _onShutter() async {
    if (_shooting) return;
    if (_lobby?.status != LobbyStatus.active) return;
    setState(() {
      _shooting = true;
      _toast = null;
    });
    try {
      // The picker returns null when the user backs out of the camera
      // sheet without taking a photo — silent no-op, no toast.
      final bytes = await widget.pickPhoto();
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _shooting = false);
        return;
      }

      Float32List? embedding;
      try {
        embedding = await widget.embedder.embed(bytes);
      } on NoFaceDetectedException {
        // Per §313: the client short-circuits to "no match" without
        // calling submitTag — saves a Function invocation and the user
        // gets faster feedback than a server round-trip.
        _showToast(_Toast.localNoMatch());
        if (!mounted) return;
        setState(() => _shooting = false);
        return;
      }

      final tagId = generateTagId();
      final submission = await widget.tags.submitTag(
        lobbyId: widget.lobbyId,
        tagId: tagId,
        embedding: embedding,
        modelVersion: widget.embedder.modelVersion,
      );

      _showToast(_Toast.fromSubmission(
        submission,
        targetName: _displayNameOf(submission),
      ));

      if (submission.retainPhoto) {
        // Fire-and-forget per §122 — verdict toast is the user-facing
        // ack; the photo upload runs in the background. Errors are
        // logged but don't surface to the player.
        unawaited(
          widget.tags
              .uploadTagPhoto(
                lobbyId: widget.lobbyId,
                tagId: submission.tagId,
                jpegBytes: bytes,
              )
              .catchError((Object e, StackTrace _) {
            debugPrint('uploadTagPhoto failed (best-effort): $e');
          }),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      _showToast(_Toast.error(_friendlyFnError(e)));
    } catch (e) {
      _showToast(_Toast.error("Couldn't process that shot."));
      debugPrint('RoundScreen shutter failure: $e');
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  String? _displayNameOf(TagSubmission s) {
    // tagId on a hit verdict is enough to look up the victim, but the
    // server doesn't echo back the victim uid by name and watchPlayers is
    // the source of truth. We don't have the victim uid in the verdict
    // (deliberately, to keep the response small), so the toast falls back
    // to a generic "you hit someone" — the scoreboard reflects the lives
    // change immediately. Improving this is a polish-PR item.
    return null;
  }

  void _showToast(_Toast toast) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toast = toast);
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  String _friendlyFnError(FirebaseFunctionsException e) {
    // submitTag's documented errors. Anything else is a bug or a network
    // outage — same generic message.
    switch (e.code) {
      case 'failed-precondition':
        if (e.message?.contains('eliminated') ?? false) {
          return "You're already eliminated.";
        }
        if (e.message?.contains('lobby status') ?? false) {
          return 'Round is no longer active.';
        }
        return e.message ?? 'Could not submit tag.';
      case 'permission-denied':
        return "You're not in this lobby.";
      case 'unauthenticated':
        return 'Sign in expired — restart the app.';
      default:
        return 'Network hiccup. Try again.';
    }
  }

  void _openScoreboard() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ScoreboardSheet(
        repo: widget.repo,
        lobbyId: widget.lobbyId,
        currentUid: widget.currentUid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Lobby?>(
      stream: widget.repo.watchLobby(widget.lobbyId),
      builder: (context, lobbySnap) {
        if (lobbySnap.hasError) {
          // The stream blew up — stop the ticker so we don't keep firing
          // _maybeEnd against a stale _lobby and looping endRound calls.
          _ticker?.cancel();
          return _RoundUnavailable(
            message: 'Lost connection to the round.',
            error: lobbySnap.error,
          );
        }
        if (lobbySnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final lobby = lobbySnap.data;
        if (lobby == null) {
          // Lobby doc was deleted out from under us. Same protection as
          // the error branch — drop the ticker and surface a terminal UI.
          _ticker?.cancel();
          _lobby = null;
          // No lobby to resume into — clear the hint so a relaunch goes
          // home instead of looping back to this dead round.
          unawaited(widget.activeLobbies.clear());
          return const _RoundUnavailable(
            message: 'This round is no longer available.',
          );
        }
        _lobby = lobby;
        if (lobby.status == LobbyStatus.ended) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _routeToResults());
        } else {
          // Drive expiry detection off lobby updates too (not just the
          // 1Hz ticker) so a state change like the host bumping duration
          // — Phase 2+ if it's ever added — re-evaluates immediately.
          _maybeEnd(lobby);
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Round in progress'),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                tooltip: 'Open scoreboard',
                onPressed: _openScoreboard,
                icon: const Icon(Icons.leaderboard_outlined),
              ),
            ],
          ),
          body: GestureDetector(
            // Approximation of the §80 "swipe-up sheet" — drag up anywhere
            // on the round surface opens the live scoreboard.
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -250) _openScoreboard();
            },
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Countdown(remaining: _remaining(lobby)),
                  const SizedBox(height: 16),
                  _TopBar(
                    repo: widget.repo,
                    lobbyId: widget.lobbyId,
                    currentUid: widget.currentUid,
                  ),
                  const Spacer(),
                  if (_toast != null) _ToastBanner(toast: _toast!),
                  const SizedBox(height: 12),
                  _ShutterButton(
                    busy: _shooting,
                    onPressed: _shooting ? null : _onShutter,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _openScoreboard,
                    icon: const Icon(Icons.keyboard_arrow_up),
                    label: const Text('Scoreboard'),
                  ),
                ],
              ),
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

class _TopBar extends StatelessWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;
  const _TopBar({
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LobbyPlayer>>(
      stream: repo.watchPlayers(lobbyId),
      builder: (context, snap) {
        final players = snap.data ?? const <LobbyPlayer>[];
        final me = players.firstWhere(
          (p) => p.uid == currentUid,
          orElse: () => _missingPlayer,
        );
        final aliveOpponents = players
            .where((p) => p.uid != currentUid && p.status == LobbyPlayerStatus.alive)
            .length;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Stat(
              icon: Icons.favorite,
              label: 'Lives',
              value: me.livesRemaining.toString(),
              eliminated: me.status == LobbyPlayerStatus.eliminated,
            ),
            _Stat(
              icon: Icons.person_outline,
              label: 'Opponents',
              value: aliveOpponents.toString(),
            ),
          ],
        );
      },
    );
  }

  static final _missingPlayer = LobbyPlayer(
    uid: '__missing__',
    displayName: '',
    livesRemaining: 0,
    status: LobbyPlayerStatus.alive,
    joinedAt: DateTime.fromMillisecondsSinceEpoch(0),
    embeddingSnapshot: Float32List(0),
    embeddingModelVersion: '',
  );
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool eliminated;
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.eliminated = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          color: eliminated ? Theme.of(context).disabledColor : null,
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            Text(
              eliminated ? 'OUT' : value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  const _ShutterButton({required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 96,
        height: 96,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: busy
              ? const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : const Icon(Icons.camera_alt, size: 36),
        ),
      ),
    );
  }
}

class _Toast {
  final String message;
  final _ToastKind kind;
  const _Toast._(this.message, this.kind);

  factory _Toast.fromSubmission(TagSubmission s, {String? targetName}) {
    switch (s.result) {
      case TagResult.hit:
        final lives = s.victimLivesRemaining;
        final eliminated = s.eliminated ?? false;
        if (eliminated) {
          return _Toast._('You eliminated your target!', _ToastKind.success);
        }
        if (lives != null) {
          return _Toast._(
            targetName == null
                ? 'Hit! Target has $lives ${lives == 1 ? "life" : "lives"} left.'
                : 'You hit $targetName. ${lives == 1 ? "1 life" : "$lives lives"} left.',
            _ToastKind.success,
          );
        }
        return _Toast._('Hit!', _ToastKind.success);
      case TagResult.noMatch:
        return const _Toast._('No match. (Cooldown 5s)', _ToastKind.warning);
      case TagResult.immune:
        return const _Toast._('Target is immune. Try again soon.', _ToastKind.warning);
      case TagResult.cooldown:
        return const _Toast._('Slow down — cooldown active.', _ToastKind.warning);
    }
  }

  factory _Toast.localNoMatch() =>
      const _Toast._('No face detected — try better lighting.', _ToastKind.warning);

  factory _Toast.error(String message) =>
      _Toast._(message, _ToastKind.error);
}

enum _ToastKind { success, warning, error }

class _ToastBanner extends StatelessWidget {
  final _Toast toast;
  const _ToastBanner({required this.toast});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color background;
    IconData icon;
    switch (toast.kind) {
      case _ToastKind.success:
        background = Colors.green.shade100;
        icon = Icons.check_circle_outline;
        break;
      case _ToastKind.warning:
        background = theme.colorScheme.surfaceContainerHighest;
        icon = Icons.info_outline;
        break;
      case _ToastKind.error:
        background = theme.colorScheme.errorContainer;
        icon = Icons.error_outline;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              toast.message,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundUnavailable extends StatelessWidget {
  final String message;
  final Object? error;
  const _RoundUnavailable({required this.message, this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Round unavailable'),
        automaticallyImplyLeading: false,
      ),
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
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

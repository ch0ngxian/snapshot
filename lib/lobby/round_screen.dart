import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../camera/round_camera.dart';
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

/// Per-shooter cooldown duration. Mirrors `COOLDOWN_MS` in
/// `functions/src/submitTag.ts`; the client-side ring is purely visual
/// (the server is the source of truth) but the local copy lets us
/// disable the shutter and animate the sweep without waiting on a
/// network round-trip.
const _kCooldownDuration = Duration(seconds: 5);

/// In-round screen — primary surface during an active lobby.
///
/// Built as the immersive viewfinder GAMEPLAY.md describes: the rear
/// camera fills the screen for the full duration of the round, and the
/// HUD (lives, timer, opponents-alive, shutter) floats on top in a
/// translucent overlay. There's no "open the camera" hand-off — the
/// camera *is* the game. Tapping the shutter (or anywhere in the bottom
/// half of the screen) captures a frame, runs it through the on-device
/// face embedder, and submits a tag.
class RoundScreen extends StatefulWidget {
  /// Stable key on the shutter button so widget tests can target it
  /// without depending on the private `_ShutterButton` type.
  static const Key shutterKey = ValueKey('round-shutter-button');

  /// Stable key on the invisible bottom-half tap-to-fire zone — same
  /// reason as [shutterKey], surfaced for tests.
  static const Key tapToFireKey = ValueKey('round-tap-to-fire-zone');

  final LobbyRepository repo;
  final TagRepository tags;
  final FaceEmbedder embedder;
  final ActiveLobbyStore activeLobbies;
  final String lobbyId;
  final String currentUid;

  /// Factory for the round's camera. Production hands back a
  /// [PackageCameraRoundCamera]; widget tests inject [FakeRoundCamera]
  /// so they don't need a live platform channel. Called once per
  /// [RoundScreen] mount; the screen owns the lifecycle.
  final RoundCamera Function() cameraFactory;

  /// Injectable clock for tests. Production uses [DateTime.now].
  final DateTime Function() clock;

  // Cannot be `const` — the defaulting for `cameraFactory`/`clock` runs
  // at construction time, which is non-const.
  // ignore: prefer_const_constructors_in_immutables
  RoundScreen({
    super.key,
    required this.repo,
    required this.tags,
    required this.embedder,
    required this.activeLobbies,
    required this.lobbyId,
    required this.currentUid,
    RoundCamera Function()? cameraFactory,
    DateTime Function()? clock,
  })  : cameraFactory = cameraFactory ?? PackageCameraRoundCamera.new,
        clock = clock ?? DateTime.now;

  @override
  State<RoundScreen> createState() => _RoundScreenState();
}

class _RoundScreenState extends State<RoundScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  Lobby? _lobby;
  bool _endRequested = false;
  bool _resultsRouted = false;
  bool _shooting = false;
  _Toast? _toast;
  Timer? _toastTimer;
  late final RoundCamera _camera;
  Object? _cameraInitError;
  bool _cameraReady = false;
  /// Anchor for the shutter cooldown ring. Set to the moment of the
  /// most recent server verdict that would have bumped the server-side
  /// `lastTagAttemptAt` (hit / no_match / immune). Null when no ring is
  /// in flight. The 1Hz ticker recomputes [_onCooldown] each second so
  /// the shutter re-enables itself once the window expires.
  DateTime? _cooldownStart;
  // Cached so the 1Hz setState rebuild doesn't hand StreamBuilder a new
  // Stream instance every tick — that triggers a resubscribe and a one-
  // frame ConnectionState.waiting, which renders as a full-screen flash.
  // The players stream is cached inside [_TopBar] for the same reason,
  // but on its own lifecycle so its subscription is in place before any
  // replay-on-subscribe behaviour fires.
  late final Stream<Lobby?> _lobbyStream;

  @override
  void initState() {
    super.initState();
    _lobbyStream = widget.repo.watchLobby(widget.lobbyId);
    _camera = widget.cameraFactory();
    WidgetsBinding.instance.addObserver(this);
    // Lock to portrait for the round — the HUD layout assumes a tall
    // viewfinder. Restored in dispose().
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    unawaited(_initCamera());
    // 1Hz tick is enough — display granularity is mm:ss and the
    // expiry-detect path is idempotent server-side anyway.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    // Re-save defensively. WaitingRoomScreen already wrote this on the
    // create/join path, but auto-rejoin lands here directly when the
    // saved lobby is already `active`, so refresh the hint either way.
    unawaited(widget.activeLobbies.save(widget.lobbyId));
  }

  Future<void> _initCamera() async {
    try {
      await _camera.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
    } catch (e, st) {
      debugPrint('RoundScreen camera init failed: $e\n$st');
      if (!mounted) return;
      setState(() => _cameraInitError = e);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _toastTimer?.cancel();
    unawaited(_camera.dispose());
    // Drop the round's portrait-only constraint. Flutter has no
    // getPreferredOrientations() to mirror, so we restore the framework
    // default — every orientation — and let the platform-level policy
    // (iOS UISupportedInterfaceOrientations + Android android:screenOrientation)
    // narrow it back from there.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause the camera when the app is backgrounded so we're not
    // burning the sensor while no one's looking, and resume on return.
    // The screen stays mounted (the lobby/round is still active) — only
    // the platform camera is parked.
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_camera.pause());
        break;
      case AppLifecycleState.resumed:
        unawaited(_camera.resume());
        break;
      case AppLifecycleState.detached:
        break;
    }
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

  /// True iff a per-shooter cooldown is in effect against [widget.clock].
  bool get _onCooldown {
    final start = _cooldownStart;
    if (start == null) return false;
    return widget.clock().difference(start) < _kCooldownDuration;
  }

  Future<void> _onShutter() async {
    if (_shooting) return;
    // Defense-in-depth — the shutter button + tap-to-fire zone are
    // already null-handled while on cooldown, but a fast double-tap can
    // race the rebuild that flips them. The server enforces the 5s
    // window too; this just keeps the UI honest.
    if (_onCooldown) return;
    if (_lobby?.status != LobbyStatus.active) return;
    // Light tick on press (GAMEPLAY.md "haptics on every verdict").
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _shooting = true;
      _toast = null;
    });
    try {
      // captureFrame returns null when the camera isn't ready — silent
      // no-op rather than a confusing toast (e.g. mid-init, mid-pause).
      final bytes = await _camera.captureFrame();
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
        // gets faster feedback than a server round-trip. No cooldown
        // either — explicit GAMEPLAY.md call-out: "no cooldown wasted".
        unawaited(HapticFeedback.lightImpact());
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

      _hapticForVerdict(submission);
      _engageCooldownFor(submission.result);

      // GAMEPLAY.md §107: on a `cooldown` verdict the ring already says
      // "you're shooting too fast" — suppressing the redundant toast.
      if (submission.result != TagResult.cooldown) {
        _showToast(_Toast.fromSubmission(
          submission,
          targetName: _displayNameOf(submission),
        ));
      }

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

  /// GAMEPLAY.md "haptics on every verdict":
  /// - **hit (non-elim)** → success bump.
  /// - **elimination** → double thud (a heavy impact, then a second one
  ///   ~90ms later — close enough that they read as a single "kill"
  ///   beat without merging into one buzz).
  /// - **miss / immune / cooldown** → soft buzz.
  void _hapticForVerdict(TagSubmission s) {
    switch (s.result) {
      case TagResult.hit:
        if (s.eliminated ?? false) {
          unawaited(HapticFeedback.heavyImpact());
          Future.delayed(const Duration(milliseconds: 90), () {
            unawaited(HapticFeedback.heavyImpact());
          });
        } else {
          unawaited(HapticFeedback.mediumImpact());
        }
        break;
      case TagResult.noMatch:
      case TagResult.immune:
      case TagResult.cooldown:
        unawaited(HapticFeedback.lightImpact());
        break;
    }
  }

  /// Anchors [_cooldownStart] off the verdict that just landed. Hit /
  /// no_match / immune all bump the server's `lastTagAttemptAt`, so
  /// they re-arm a fresh 5s window; a `cooldown` verdict means the
  /// server's anchor wasn't moved, so we leave a still-running local
  /// ring alone — only re-arming if the local one had already drained
  /// (clock skew or post-restart, where the server is still cooling
  /// from a pre-restart attempt we no longer remember).
  void _engageCooldownFor(TagResult result) {
    if (result == TagResult.cooldown) {
      if (_onCooldown) return;
      setState(() => _cooldownStart = widget.clock());
      return;
    }
    setState(() => _cooldownStart = widget.clock());
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
      stream: _lobbyStream,
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
            backgroundColor: Colors.black,
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
        final canFire = !_shooting && !_onCooldown;
        return _RoundShell(
          lobby: lobby,
          remaining: _remaining(lobby),
          camera: _camera,
          cameraReady: _cameraReady,
          cameraInitError: _cameraInitError,
          shooting: _shooting,
          toast: _toast,
          onShutter: canFire ? _onShutter : null,
          onOpenScoreboard: _openScoreboard,
          repo: widget.repo,
          lobbyId: widget.lobbyId,
          currentUid: widget.currentUid,
          cooldownStart: _cooldownStart,
          cooldownDuration: _kCooldownDuration,
          clock: widget.clock,
        );
      },
    );
  }
}

/// The immersive viewfinder shell — full-bleed camera preview with the
/// HUD stacked on top. Pulled out of the state class so the build path
/// is easier to follow at a glance.
class _RoundShell extends StatelessWidget {
  final Lobby lobby;
  final Duration? remaining;
  final RoundCamera camera;
  final bool cameraReady;
  final Object? cameraInitError;
  final bool shooting;
  final _Toast? toast;
  final VoidCallback? onShutter;
  final VoidCallback onOpenScoreboard;
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;
  final DateTime? cooldownStart;
  final Duration cooldownDuration;
  final DateTime Function() clock;

  const _RoundShell({
    required this.lobby,
    required this.remaining,
    required this.camera,
    required this.cameraReady,
    required this.cameraInitError,
    required this.shooting,
    required this.toast,
    required this.onShutter,
    required this.onOpenScoreboard,
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
    required this.cooldownStart,
    required this.cooldownDuration,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // Approximation of the GAMEPLAY.md "swipe-up scoreboard sheet" —
      // dragging up anywhere on the round surface opens the live
      // scoreboard. Wraps the entire body so it competes with the tap-
      // to-fire zone on velocity rather than position.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -250) onOpenScoreboard();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Layer 1 — live preview. SizedBox.expand + FittedBox makes
            // the preview cover the entire screen even when its native
            // aspect ratio doesn't match the device's; cropping the
            // sides is the right call for an immersive HUD.
            Positioned.fill(
              child: cameraInitError != null
                  ? const _CameraUnavailableBackdrop()
                  : _ViewfinderBackdrop(camera: camera, ready: cameraReady),
            ),

            // Layer 2 — invisible bottom-half tap-to-fire zone. Sits
            // *under* the HUD so the shutter button + scoreboard icon
            // win the hit-test when they overlap. Behaviour stays the
            // same as the shutter: gated on (not currently shooting).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              top: null,
              height: MediaQuery.of(context).size.height / 2,
              child: GestureDetector(
                key: RoundScreen.tapToFireKey,
                behavior: HitTestBehavior.translucent,
                onTap: onShutter,
                // No child — pure gesture catcher.
              ),
            ),

            // Layer 3 — HUD overlay. SafeArea so nothing collides with
            // the notch / status bar / home indicator.
            SafeArea(
              child: Stack(
                children: [
                  // Top-left — lives.
                  Positioned(
                    top: 16,
                    left: 16,
                    child: _LivesIndicator(
                      repo: repo,
                      lobbyId: lobbyId,
                      currentUid: currentUid,
                      startingLives: lobby.rules.startingLives,
                    ),
                  ),

                  // Top-center — timer.
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Center(child: _Countdown(remaining: remaining)),
                  ),

                  // Top-right — opponents alive + tap-to-open scoreboard.
                  Positioned(
                    top: 16,
                    right: 16,
                    child: _OpponentsBadge(
                      repo: repo,
                      lobbyId: lobbyId,
                      currentUid: currentUid,
                      onTap: onOpenScoreboard,
                    ),
                  ),

                  // Above the shutter — verdict toast.
                  if (toast != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 160,
                      child: _ToastBanner(toast: toast!),
                    ),

                  // Bottom-center — shutter.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 32,
                    child: Center(
                      child: _ShutterButton(
                        key: RoundScreen.shutterKey,
                        busy: shooting,
                        onPressed: onShutter,
                        cooldownStart: cooldownStart,
                        cooldownDuration: cooldownDuration,
                        clock: clock,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewfinderBackdrop extends StatelessWidget {
  final RoundCamera camera;
  final bool ready;
  const _ViewfinderBackdrop({required this.camera, required this.ready});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(color: Colors.white70),
        ),
      );
    }
    // FittedBox(BoxFit.cover) keeps the preview filling the screen even
    // when the camera's native aspect ratio is squarer/taller than the
    // device — overflow is hidden behind the HUD instead of letterboxed.
    // The SizedBox uses the camera's *real* aspect ratio (queried from
    // the controller via `previewAspectRatio`) as a `width / height`
    // pair so cover-scaling crops correctly instead of distorting
    // against an arbitrary box. The numeric extents are irrelevant —
    // FittedBox rescales — only their ratio matters. AspectRatio can't
    // be used directly here because FittedBox hands its child unbounded
    // constraints, which AspectRatio rejects.
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: camera.previewAspectRatio,
            height: 1.0,
            child: camera.previewWidget(context),
          ),
        ),
      ),
    );
  }
}

class _CameraUnavailableBackdrop extends StatelessWidget {
  const _CameraUnavailableBackdrop();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "Camera unavailable.\nGrant camera permission and re-open the round.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

/// Countdown pill with the GAMEPLAY.md "urgency ramp": white above 60s,
/// amber under 60s, red and pulsing under 10s. The pulse is a subtle
/// scale wobble — large enough to read as "hurry up" without obscuring
/// the digits.
class _Countdown extends StatefulWidget {
  final Duration? remaining;
  const _Countdown({required this.remaining});

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _syncPulse(widget.remaining);
  }

  @override
  void didUpdateWidget(covariant _Countdown old) {
    super.didUpdateWidget(old);
    _syncPulse(widget.remaining);
  }

  /// `repeat(reverse: true)` while in the red zone, idle otherwise. We
  /// don't run the controller continuously because `pumpAndSettle` in
  /// widget tests would loop forever on a non-terminating animation.
  void _syncPulse(Duration? remaining) {
    final shouldPulse = _isPulseBand(remaining);
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  static bool _isPulseBand(Duration? r) {
    if (r == null) return false;
    return r.inMilliseconds > 0 && r.inSeconds < 10;
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.remaining ?? Duration.zero;
    final mm = r.inMinutes.toString().padLeft(2, '0');
    final ss = (r.inSeconds % 60).toString().padLeft(2, '0');
    final color = _colorFor(r);
    final pulsing = _isPulseBand(widget.remaining);
    final text = Text(
      '$mm:$ss',
      key: const ValueKey('round-countdown-text'),
      style: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.bold,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: 0.5,
      ),
    );
    return _HudPill(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) {
          // 1.0 → 1.10 scale on the pulse band; identity scale otherwise.
          final scale = pulsing ? 1.0 + (_pulse.value * 0.10) : 1.0;
          return Transform.scale(scale: scale, child: child);
        },
        child: text,
      ),
    );
  }

  static Color _colorFor(Duration r) {
    final s = r.inSeconds;
    if (s < 10) return Colors.redAccent;
    if (s < 60) return Colors.amberAccent;
    return Colors.white;
  }
}

/// Hearts row driven by the player's live `livesRemaining`. Renders one
/// filled heart per remaining life and one outline per lost life, up to
/// the lobby's starting count. When the player is eliminated the row
/// goes grey.
class _LivesIndicator extends StatefulWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;
  final int startingLives;
  const _LivesIndicator({
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
    required this.startingLives,
  });

  @override
  State<_LivesIndicator> createState() => _LivesIndicatorState();
}

class _LivesIndicatorState extends State<_LivesIndicator> {
  // Cache the players stream so parent rebuilds (driven by the round's
  // 1Hz countdown ticker) don't hand StreamBuilder a new Stream every
  // tick and re-subscribe.
  late final Stream<List<LobbyPlayer>> _playersStream =
      widget.repo.watchPlayers(widget.lobbyId);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LobbyPlayer>>(
      stream: _playersStream,
      builder: (context, snap) {
        final players = snap.data ?? const <LobbyPlayer>[];
        final me = players.firstWhere(
          (p) => p.uid == widget.currentUid,
          orElse: () => _missingPlayer,
        );
        final eliminated = me.status == LobbyPlayerStatus.eliminated;
        final lives = me.livesRemaining.clamp(0, widget.startingLives);
        return _HudPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.startingLives; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Icon(
                  i < lives ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                  color: eliminated
                      ? Colors.white24
                      : (i < lives
                          ? Colors.redAccent.shade100
                          : Colors.white38),
                ),
              ],
              if (eliminated) ...[
                const SizedBox(width: 8),
                const Text(
                  'OUT',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ],
          ),
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

class _OpponentsBadge extends StatefulWidget {
  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;
  final VoidCallback onTap;
  const _OpponentsBadge({
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
    required this.onTap,
  });

  @override
  State<_OpponentsBadge> createState() => _OpponentsBadgeState();
}

class _OpponentsBadgeState extends State<_OpponentsBadge> {
  late final Stream<List<LobbyPlayer>> _playersStream =
      widget.repo.watchPlayers(widget.lobbyId);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LobbyPlayer>>(
      stream: _playersStream,
      builder: (context, snap) {
        final players = snap.data ?? const <LobbyPlayer>[];
        final aliveOpponents = players
            .where((p) =>
                p.uid != widget.currentUid &&
                p.status == LobbyPlayerStatus.alive)
            .length;
        return GestureDetector(
          onTap: widget.onTap,
          child: _HudPill(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  '$aliveOpponents',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.leaderboard_outlined,
                  size: 18,
                  color: Colors.white70,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Translucent rounded pill used by every HUD chip. Centralised so the
/// HUD stays visually coherent and any future tweaks (blur, tint) land
/// in one place.
class _HudPill extends StatelessWidget {
  final Widget child;
  const _HudPill({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: child,
    );
  }
}

class _ShutterButton extends StatefulWidget {
  final bool busy;
  final VoidCallback? onPressed;
  /// Wall-clock instant the most recent shot landed (any non-cooldown
  /// verdict). Null when no cooldown is in flight. The ring sweeps from
  /// this moment forward by [cooldownDuration] of real time, regardless
  /// of the parent's injected [clock] — the animation needs to tick
  /// against the real frame clock so it stays smooth across rebuilds.
  final DateTime? cooldownStart;
  final Duration cooldownDuration;
  /// Same clock the parent uses to decide whether the shutter is
  /// gated. We use it once on mount / didUpdateWidget to compute how
  /// much of the cooldown has already elapsed, so a rebuild that
  /// remounts mid-cooldown picks up the right starting fraction.
  final DateTime Function() clock;

  const _ShutterButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.cooldownStart,
    required this.cooldownDuration,
    required this.clock,
  });

  @override
  State<_ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<_ShutterButton>
    with SingleTickerProviderStateMixin {
  /// 0.0 = cooldown just started; 1.0 = cooldown complete (ring not
  /// drawn). Driven by [AnimationController.animateTo] so the sweep
  /// uses the real frame clock instead of timer setStates.
  late final AnimationController _ring;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(
      vsync: this,
      duration: widget.cooldownDuration,
      value: 1.0,
    );
    if (widget.cooldownStart != null) _animateRing(widget.cooldownStart!);
  }

  @override
  void didUpdateWidget(covariant _ShutterButton old) {
    super.didUpdateWidget(old);
    if (widget.cooldownStart != old.cooldownStart) {
      if (widget.cooldownStart == null) {
        _ring
          ..stop()
          ..value = 1.0;
      } else {
        _animateRing(widget.cooldownStart!);
      }
    }
  }

  void _animateRing(DateTime start) {
    final totalMs = widget.cooldownDuration.inMilliseconds;
    final elapsedMs = widget.clock().difference(start).inMilliseconds;
    if (elapsedMs >= totalMs) {
      _ring.value = 1.0;
      return;
    }
    final clamped = elapsedMs.clamp(0, totalMs);
    _ring.value = clamped / totalMs;
    _ring.animateTo(
      1.0,
      duration: Duration(milliseconds: totalMs - clamped),
      curve: Curves.linear,
    );
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    final busy = widget.busy;
    // Wrapped with Semantics(button: true) so screen readers announce
    // it as a button with the right enabled/disabled state, and with
    // Material+InkResponse so it gets standard ripple feedback on tap
    // — both are missing from a bare GestureDetector + Container.
    return Semantics(
      button: true,
      enabled: !disabled,
      label: 'Shutter',
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkResponse(
          onTap: widget.onPressed,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          radius: 44,
          child: SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Layer 1 — static outer border + sweep arc, painted
                // together so the cooldown ring overlays cleanly on the
                // muted base ring.
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _ring,
                    builder: (_, _) => CustomPaint(
                      painter: _ShutterRingPainter(
                        cooldownProgress: _ring.value,
                        disabled: disabled,
                      ),
                    ),
                  ),
                ),
                // Layer 2 — inner disc. Stays bright while the ring
                // sweeps so the button still reads as "alive"; disabled
                // (eliminated / round-over) goes greyed out.
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: disabled
                          ? Colors.white24
                          : (busy ? Colors.white70 : Colors.white),
                    ),
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor:
                                  AlwaysStoppedAnimation(Colors.black54),
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the shutter outer ring and (while in cooldown) the sweeping
/// arc that visualises the per-shooter cooldown.
class _ShutterRingPainter extends CustomPainter {
  /// 0.0 = ring just started sweeping; 1.0 = sweep complete.
  final double cooldownProgress;
  final bool disabled;
  const _ShutterRingPainter({
    required this.cooldownProgress,
    required this.disabled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final radius = (size.shortestSide - stroke) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final cooling = cooldownProgress < 1.0;
    // Static base ring. Muted while a sweep is in flight so the swept
    // (un-drawn) sector reads as "the part you've earned back" and the
    // un-swept arc reads as "still cooling".
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = disabled
          ? Colors.white24
          : (cooling ? Colors.white24 : Colors.white);
    canvas.drawCircle(center, radius, base);

    if (cooling) {
      // 12 o'clock start, clockwise sweep. The painted arc is the
      // *remaining* cooldown — it shrinks toward the 12 o'clock origin
      // as the cooldown elapses, so the ring "drains".
      final sweptAngle = cooldownProgress * 2 * pi;
      final remainingAngle = 2 * pi - sweptAngle;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = Colors.amberAccent;
      canvas.drawArc(rect, -pi / 2 + sweptAngle, remainingAngle, false, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _ShutterRingPainter old) =>
      old.cooldownProgress != cooldownProgress || old.disabled != disabled;
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
    Color background;
    IconData icon;
    Color iconColor;
    switch (toast.kind) {
      case _ToastKind.success:
        background = Colors.green.shade600.withValues(alpha: 0.85);
        icon = Icons.check_circle_outline;
        iconColor = Colors.white;
        break;
      case _ToastKind.warning:
        background = Colors.black.withValues(alpha: 0.7);
        icon = Icons.info_outline;
        iconColor = Colors.amberAccent;
        break;
      case _ToastKind.error:
        background = Colors.red.shade700.withValues(alpha: 0.9);
        icon = Icons.error_outline;
        iconColor = Colors.white;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              toast.message,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
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

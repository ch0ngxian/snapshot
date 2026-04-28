import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../camera/round_camera.dart';
import '../face/face_embedder.dart';
import '../face/face_tracker.dart';
import '../face/mlkit_face_tracker.dart';
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

/// How long the "you got hit" feedback (red flash + camera shake +
/// heart pulse) plays for. Short — long enough to register but short
/// enough to clear before the player can frame their next shot.
const _kHitFeedbackDuration = Duration(milliseconds: 450);

/// Stable signal raised by [_RoundScreenState] when its own lives drop.
/// Children (lives indicator, viewfinder shake wrapper, flash overlay)
/// react by playing a one-shot animation keyed off [at]; the rest of
/// the rebuild path is unchanged.
@immutable
class _HitEvent {
  /// Wall-clock instant the drop was detected (from the injected clock).
  /// Doubles as the animation key — distinct timestamps mean distinct
  /// hits, so a second hit while the first is still playing re-arms.
  final DateTime at;

  /// Lives count *before* the hit landed. The heart at index
  /// `livesBeforeHit - 1` is the one that just got knocked out, so the
  /// pulse-out animation runs on that specific heart.
  final int livesBeforeHit;

  const _HitEvent({required this.at, required this.livesBeforeHit});
}

/// Plays a one-shot animation each time the host widget's `eventAt`
/// returns a fresh, non-null timestamp. Used by the three "you got
/// hit" feedback channels (red flash, viewfinder shake, heart pulse-
/// out) — they all share the same "play once per [_HitEvent.at]"
/// trigger semantics, and centralising the controller + dedupe guard
/// means the three keep their playback timing in lock-step.
mixin _PlayOnEventTimestamp<T extends StatefulWidget> on State<T>
    implements TickerProvider {
  AnimationController? _eventController;
  DateTime? _lastEventAt;

  AnimationController get eventController => _eventController!;

  void initEventController(Duration duration) {
    _eventController = AnimationController(vsync: this, duration: duration);
  }

  /// Subclasses return the current event timestamp (or null). Called
  /// from `initState` and `didUpdateWidget` — a fresh timestamp
  /// restarts the animation from zero; a repeated timestamp is a
  /// no-op so a parent rebuild during playback doesn't reset the run.
  DateTime? eventTimestamp();

  void maybePlayOnEvent() {
    final at = eventTimestamp();
    if (at == null) return;
    if (_lastEventAt == at) return;
    _lastEventAt = at;
    eventController
      ..stop()
      ..value = 0
      ..forward();
  }

  @override
  void dispose() {
    _eventController?.dispose();
    super.dispose();
  }
}

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

  /// Factory for the live face-detection tracker. Production hands
  /// back an [MlKitFaceTracker] bound to the round's camera; widget
  /// tests inject [FakeFaceTracker] so they don't need ML Kit. Called
  /// once per mount, after the camera is initialized.
  final FaceTracker Function(RoundCamera) faceTrackerFactory;

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
    FaceTracker Function(RoundCamera)? faceTrackerFactory,
    DateTime Function()? clock,
  })  : cameraFactory = cameraFactory ?? PackageCameraRoundCamera.new,
        faceTrackerFactory = faceTrackerFactory ??
            ((camera) => MlKitFaceTracker(camera: camera)),
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
  FaceTracker? _faceTracker;
  TrackedFace? _trackedFace;
  StreamSubscription<TrackedFace?>? _faceSub;
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

  // "You got hit" detection. The state class subscribes to the same
  // players stream the HUD chips do (Firestore deduplicates listeners
  // on identical queries) and watches the local player's lives counter
  // for drops. When a drop is observed, we raise [_hitEvent] which
  // children watch for the one-shot flash / shake / heart-pulse
  // animations. The first emission only seeds [_lastObservedLives] —
  // we never flash on the initial subscription or on auto-rejoin
  // (where the player might be mounting back in with already-reduced
  // lives from a hit they took before relaunching).
  StreamSubscription<List<LobbyPlayer>>? _playersSub;
  int? _lastObservedLives;
  _HitEvent? _hitEvent;
  Timer? _hitClearTimer;

  @override
  void initState() {
    super.initState();
    _lobbyStream = widget.repo.watchLobby(widget.lobbyId);
    _playersSub = widget.repo
        .watchPlayers(widget.lobbyId)
        .listen(_onPlayersUpdate);
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
      // Spin the live face tracker up only after the camera is good
      // to go — the production tracker subscribes to the camera's
      // image stream, which doesn't exist until [initialize] resolves.
      // Failures here are non-fatal: the round still plays without a
      // reticle, just without the aim-assist visual.
      try {
        final tracker = widget.faceTrackerFactory(_camera);
        _faceTracker = tracker;
        _faceSub = tracker.faces.listen((face) {
          if (!mounted) return;
          setState(() => _trackedFace = face);
        });
        await tracker.start();
      } catch (e, st) {
        debugPrint('RoundScreen face tracker start failed: $e\n$st');
      }
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
    _hitClearTimer?.cancel();
    unawaited(_playersSub?.cancel());
    unawaited(_faceSub?.cancel());
    final tracker = _faceTracker;
    if (tracker != null) unawaited(tracker.dispose());
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
    // the platform camera is parked. The face tracker pauses with it
    // (its image-stream subscription would otherwise be left hanging
    // off a paused camera) and is restarted on resume.
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        final tracker = _faceTracker;
        if (tracker != null) unawaited(tracker.stop());
        unawaited(_camera.pause());
        break;
      case AppLifecycleState.resumed:
        unawaited(_resumeAfterBackground());
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _resumeAfterBackground() async {
    await _camera.resume();
    final tracker = _faceTracker;
    if (tracker == null || !mounted) return;
    try {
      await tracker.start();
    } catch (e, st) {
      debugPrint('RoundScreen face tracker resume failed: $e\n$st');
    }
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
    final lobby = _lobby;
    if (lobby != null) _maybeEnd(lobby);
  }

  /// Watches the local player's lives counter for drops. The first
  /// emission seeds [_lastObservedLives] without firing feedback —
  /// otherwise an auto-rejoin into a round where you've already been
  /// hit would replay the flash on cold launch. Subsequent strict
  /// decreases raise a [_HitEvent] that the flash overlay, viewfinder
  /// shake wrapper, and lives indicator key off of.
  void _onPlayersUpdate(List<LobbyPlayer> players) {
    if (!mounted) return;
    final me = players
        .where((p) => p.uid == widget.currentUid)
        .firstOrNull;
    if (me == null) return;
    final previous = _lastObservedLives;
    _lastObservedLives = me.livesRemaining;
    if (previous == null) return;
    if (me.livesRemaining < previous) {
      _triggerHitFeedback(livesBeforeHit: previous);
    }
  }

  void _triggerHitFeedback({required int livesBeforeHit}) {
    final at = widget.clock();
    // Heavy buzz on the victim side — distinct from the per-verdict
    // shooter haptics that fire from `_hapticForVerdict`.
    unawaited(HapticFeedback.heavyImpact());
    setState(() {
      _hitEvent = _HitEvent(at: at, livesBeforeHit: livesBeforeHit);
    });
    _hitClearTimer?.cancel();
    // Auto-clear so the overlay stack returns to a "no hit in flight"
    // baseline; without this a stale event would stick around forever
    // and rebuild against the same hit-key on every parent rebuild.
    _hitClearTimer = Timer(_kHitFeedbackDuration, () {
      if (!mounted) return;
      setState(() => _hitEvent = null);
    });
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
          trackedFace: _trackedFace,
          hitEvent: _hitEvent,
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
  final TrackedFace? trackedFace;
  final _HitEvent? hitEvent;

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
    required this.trackedFace,
    required this.hitEvent,
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
            // Layers 1 + 1.5 — live preview + reticle, wrapped in the
            // viewfinder shake so a "you got hit" event jolts the
            // world but leaves the HUD steady. Shaking the HUD too
            // reads as "the screen is broken"; jolting just the
            // viewfinder reads as "the world rocked" (GAMEPLAY.md
            // §117).
            Positioned.fill(
              child: _ViewfinderShake(
                hitEvent: hitEvent,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Layer 1 — live preview. SizedBox.expand +
                    // FittedBox makes the preview cover the entire
                    // screen even when its native aspect ratio doesn't
                    // match the device's; cropping the sides is the
                    // right call for an immersive HUD.
                    Positioned.fill(
                      child: cameraInitError != null
                          ? const _CameraUnavailableBackdrop()
                          : _ViewfinderBackdrop(
                              camera: camera, ready: cameraReady),
                    ),

                    // Layer 1.5 — live face-detection reticle.
                    // Visible only when the tracker is currently
                    // locked onto a face; otherwise it renders
                    // nothing. Wrapped in IgnorePointer so it never
                    // wins the hit-test against the tap-to-fire zone
                    // or the shutter (GAMEPLAY.md §78). The reticle
                    // applies the same `BoxFit.cover` transform the
                    // preview uses, so its position lines up with the
                    // cropped / scaled preview pixels rather than
                    // drifting on devices whose screen aspect ratio
                    // differs from the camera's.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _FaceReticle(
                          face: trackedFace,
                          previewAspectRatio: camera.previewAspectRatio,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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

            // Layer 2.5 — "you got hit" red flash. Sits above the
            // viewfinder + tap-to-fire zone but is `IgnorePointer`'d
            // so it never blocks input. Painted full-bleed (outside
            // the SafeArea) so the flash bleeds into the notch /
            // status bar — the moment is supposed to be jarring.
            Positioned.fill(
              child: IgnorePointer(
                child: _HitFlashOverlay(hitEvent: hitEvent),
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
                      hitEvent: hitEvent,
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
///
/// On a hit, the just-lost heart (the one whose index matches
/// `hitEvent.livesBeforeHit - 1`) plays a one-shot pulse-out — scale
/// up, fade out — before settling into its outline state.
class _LivesIndicator extends StatefulWidget {
  /// Stable key on the heart that's actively pulsing out. Surfaced so
  /// widget tests can verify the right heart is being animated without
  /// reaching into private types.
  static const Key kPulsingHeartKey = ValueKey('round-pulsing-heart');

  final LobbyRepository repo;
  final String lobbyId;
  final String currentUid;
  final int startingLives;
  final _HitEvent? hitEvent;

  const _LivesIndicator({
    required this.repo,
    required this.lobbyId,
    required this.currentUid,
    required this.startingLives,
    required this.hitEvent,
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
        // Index of the heart that's currently pulsing out, if any.
        // The player can be re-hit while still within the prior hit's
        // animation window (since immunity is shorter on the server
        // for low values), so we re-key on `hitEvent.at`.
        final hit = widget.hitEvent;
        final pulsingIndex = (hit != null && !eliminated)
            ? (hit.livesBeforeHit - 1).clamp(0, widget.startingLives - 1)
            : null;
        return _HudPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.startingLives; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _HeartIcon(
                  filled: i < lives,
                  eliminated: eliminated,
                  pulse: i == pulsingIndex ? hit : null,
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

/// Individual heart slot in the lives row. Renders a static
/// filled/outline icon by default; when [pulse] is non-null AND
/// matches a "fresh" event, runs a one-shot scale-up + fade-out so the
/// heart visibly *leaves* the row instead of just blinking to outline.
class _HeartIcon extends StatefulWidget {
  final bool filled;
  final bool eliminated;
  /// The hit event currently animating this heart. `null` for hearts
  /// that aren't the just-lost slot. The widget keys its animation off
  /// `pulse.at`, so a new event with a later timestamp restarts the
  /// pulse from zero (lets a victim re-hit during their own pulse
  /// re-trigger the animation, even though server immunity makes that
  /// rare).
  final _HitEvent? pulse;

  const _HeartIcon({
    required this.filled,
    required this.eliminated,
    required this.pulse,
  });

  @override
  State<_HeartIcon> createState() => _HeartIconState();
}

class _HeartIconState extends State<_HeartIcon>
    with SingleTickerProviderStateMixin, _PlayOnEventTimestamp<_HeartIcon> {
  @override
  DateTime? eventTimestamp() => widget.pulse?.at;

  @override
  void initState() {
    super.initState();
    initEventController(_kHitFeedbackDuration);
    maybePlayOnEvent();
  }

  @override
  void didUpdateWidget(covariant _HeartIcon old) {
    super.didUpdateWidget(old);
    maybePlayOnEvent();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.eliminated
        ? Colors.white24
        : (widget.filled ? Colors.redAccent.shade100 : Colors.white38);
    // Key attaches whenever the parent has flagged this slot as the
    // newly-lost heart, regardless of whether the controller is
    // mid-frame — the pulse window is always exactly the same as the
    // parent's `_hitEvent` window, and gating on `isAnimating` would
    // make the key flicker as the controller starts/completes within
    // that window.
    final iconKey =
        widget.pulse != null ? _LivesIndicator.kPulsingHeartKey : null;
    final iconData =
        widget.filled ? Icons.favorite : Icons.favorite_border;
    final base = Icon(iconData, size: 22, color: color, key: iconKey);
    if (widget.pulse == null) {
      return SizedBox(width: 22, height: 22, child: base);
    }
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: eventController,
        builder: (_, _) {
          final t = eventController.value;
          // Two layers: the static base heart in its post-hit state,
          // and a "ghost" of the pre-hit filled heart scaling up and
          // fading out on top — reads as the life *leaving*.
          final scale = 1.0 + 0.8 * t;
          final opacity = (1.0 - t).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.center,
            children: [
              base,
              Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: opacity,
                  child: Icon(
                    Icons.favorite,
                    size: 22,
                    color: Colors.redAccent.shade100,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Full-bleed red flash that fades in fast and out slow on a hit
/// event. IgnorePointer is applied at the call site so it never
/// blocks the tap-to-fire zone; this widget is purely visual.
class _HitFlashOverlay extends StatefulWidget {
  static const Key kFlashKey = ValueKey('round-hit-flash');

  final _HitEvent? hitEvent;
  const _HitFlashOverlay({required this.hitEvent});

  @override
  State<_HitFlashOverlay> createState() => _HitFlashOverlayState();
}

class _HitFlashOverlayState extends State<_HitFlashOverlay>
    with
        SingleTickerProviderStateMixin,
        _PlayOnEventTimestamp<_HitFlashOverlay> {
  @override
  DateTime? eventTimestamp() => widget.hitEvent?.at;

  @override
  void initState() {
    super.initState();
    initEventController(_kHitFeedbackDuration);
    maybePlayOnEvent();
  }

  @override
  void didUpdateWidget(covariant _HitFlashOverlay old) {
    super.didUpdateWidget(old);
    maybePlayOnEvent();
  }

  @override
  Widget build(BuildContext context) {
    // When there's no hit in flight, drop the overlay entirely — keeps
    // the build cheap on the 99% of frames that aren't recovering
    // from a hit. The parent clears `hitEvent` after
    // `_kHitFeedbackDuration`, so this only renders during that
    // window.
    if (widget.hitEvent == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: eventController,
      builder: (_, _) {
        final t = eventController.value;
        // Curve: snap to peak alpha quickly, then fade. 0.0 → 0.55 by
        // t=0.15, decaying linearly to 0 at t=1.
        final alpha = t < 0.15
            ? (t / 0.15) * 0.55
            : (1.0 - (t - 0.15) / 0.85) * 0.55;
        return ColoredBox(
          key: _HitFlashOverlay.kFlashKey,
          color: Colors.redAccent.withValues(alpha: alpha.clamp(0.0, 1.0)),
        );
      },
    );
  }
}

/// Wraps the viewfinder layer (preview + reticle) in a brief horizontal
/// shake when a hit lands. Driven by the same hit-event the flash and
/// heart-pulse react to so the three feedback channels stay in lock-
/// step. Keyed off `hitEvent.at` — a fresh timestamp restarts the
/// shake from zero.
class _ViewfinderShake extends StatefulWidget {
  final _HitEvent? hitEvent;
  final Widget child;
  const _ViewfinderShake({required this.hitEvent, required this.child});

  @override
  State<_ViewfinderShake> createState() => _ViewfinderShakeState();
}

class _ViewfinderShakeState extends State<_ViewfinderShake>
    with
        SingleTickerProviderStateMixin,
        _PlayOnEventTimestamp<_ViewfinderShake> {
  @override
  DateTime? eventTimestamp() => widget.hitEvent?.at;

  @override
  void initState() {
    super.initState();
    initEventController(_kHitFeedbackDuration);
    maybePlayOnEvent();
  }

  @override
  void didUpdateWidget(covariant _ViewfinderShake old) {
    super.didUpdateWidget(old);
    maybePlayOnEvent();
  }

  @override
  Widget build(BuildContext context) {
    // Skip the AnimatedBuilder wrapper entirely when the controller's
    // settled — every parent rebuild (the 1Hz round ticker, lives /
    // toast updates, etc.) lands here, and an idle AnimatedBuilder
    // node would just be a wasted layer.
    if (!eventController.isAnimating) return widget.child;
    return AnimatedBuilder(
      animation: eventController,
      builder: (_, child) {
        final t = eventController.value;
        // Decaying sine — three full oscillations over the window,
        // amplitude tapered by `(1 - t)` so the shake settles back to
        // rest naturally instead of cutting off mid-swing.
        const peakDx = 12.0;
        final dx = sin(t * pi * 6) * peakDx * (1.0 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
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

/// GAMEPLAY.md §78 — live face-detection reticle. White by default,
/// green when the tracker reports an aim-lock (face roughly centered
/// AND large enough that a tag is likely to match).
///
/// The tracker emits bounds normalized to preview space `[0, 1]^2`.
/// The preview itself is rendered through `FittedBox(BoxFit.cover)`,
/// so when the screen and preview aspect ratios differ the preview
/// is scaled past the screen on the longer axis and cropped — the
/// reticle has to apply the *same* transform or it drifts off the
/// face on those devices. [coverFitRect] does the math; this widget
/// just feeds the LayoutBuilder constraints in.
class _FaceReticle extends StatelessWidget {
  static const Key kReticleKey = ValueKey('round-face-reticle');

  final TrackedFace? face;
  /// Aspect ratio of the camera preview (`width / height`) — matches
  /// what `_ViewfinderBackdrop` hands to its `FittedBox`.
  final double previewAspectRatio;

  const _FaceReticle({required this.face, required this.previewAspectRatio});

  @override
  Widget build(BuildContext context) {
    final tracked = face;
    if (tracked == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final placement = coverFitRect(
          normalizedBounds: tracked.normalizedBounds,
          previewAspectRatio: previewAspectRatio,
          screenSize: constraints.biggest,
        );
        if (placement == null) return const SizedBox.shrink();
        final color =
            tracked.aimLocked ? Colors.greenAccent : Colors.white;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: placement.left,
              top: placement.top,
              width: placement.width,
              height: placement.height,
              child: AnimatedContainer(
                key: kReticleKey,
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.35),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Maps a normalized preview-space rect through the same
/// `BoxFit.cover` transform the camera preview is rendered with, so
/// overlay widgets (the face reticle today; future detection chrome
/// later) line up with the cropped/scaled preview pixels.
///
/// Returns `null` if the rect would render with zero area after
/// clamping to the visible region — saves the caller a follow-up
/// shrink-check.
///
/// Visible at top level for testing; the math is fiddly enough to
/// want assertions independent of widget mounting.
@visibleForTesting
Rect? coverFitRect({
  required Rect normalizedBounds,
  required double previewAspectRatio,
  required Size screenSize,
}) {
  final screenW = screenSize.width;
  final screenH = screenSize.height;
  if (screenW <= 0 || screenH <= 0) return null;
  if (previewAspectRatio <= 0) return null;
  final screenAr = screenW / screenH;
  // Cover scaling: fit the *shorter* normalized axis to the screen
  // and let the longer axis overflow + crop.
  final double renderedW;
  final double renderedH;
  final double offsetX;
  final double offsetY;
  if (previewAspectRatio > screenAr) {
    // Preview is wider than screen → fit height, crop sides.
    renderedH = screenH;
    renderedW = screenH * previewAspectRatio;
    offsetX = (screenW - renderedW) / 2;
    offsetY = 0;
  } else {
    // Preview is taller than screen → fit width, crop top/bottom.
    renderedW = screenW;
    renderedH = screenW / previewAspectRatio;
    offsetX = 0;
    offsetY = (screenH - renderedH) / 2;
  }
  final left = (offsetX + normalizedBounds.left * renderedW).clamp(0.0, screenW);
  final top = (offsetY + normalizedBounds.top * renderedH).clamp(0.0, screenH);
  final right = (offsetX + normalizedBounds.right * renderedW).clamp(0.0, screenW);
  final bottom = (offsetY + normalizedBounds.bottom * renderedH).clamp(0.0, screenH);
  final width = right - left;
  final height = bottom - top;
  if (width <= 0 || height <= 0) return null;
  return Rect.fromLTWH(left, top, width, height);
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

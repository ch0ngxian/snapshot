import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'camera/round_camera.dart';
import 'face/cosine_similarity.dart';
import 'face/face_embedder.dart';
import 'face/mobilefacenet_embedder.dart';
import 'face/no_face_detected_exception.dart';
import 'firebase_options.dart';
import 'lobby/lobby_entry_screen.dart';
import 'lobby/round_screen.dart';
import 'lobby/waiting_room_screen.dart';
import 'models/lobby.dart';
import 'models/user_profile.dart';
import 'onboarding/onboarding_flow.dart';
import 'services/active_lobby_store.dart';
import 'services/auth_bootstrap.dart';
import 'services/fcm_registrar.dart';
import 'services/firebase_auth_bootstrap.dart';
import 'services/firestore_lobby_repository.dart';
import 'services/firestore_tag_repository.dart';
import 'services/firestore_user_repository.dart';
import 'services/lobby_repository.dart';
import 'services/tag_push_listener.dart';
import 'services/tag_repository.dart';
import 'services/user_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Production face embedder. Defaults to mobilefacenet-v1 (float32) per
    // tech-plan §314 — switch to mobilefacenet-v1-q (int8 dynamic-range)
    // only if the latency gate flags p95 > 300 ms on a low-end Android,
    // and bump the modelVersion stamp at the same time so the wire format
    // isn't a silent swap. The .tflite is gitignored; tools/fetch_model.sh
    // fetches it before `flutter run`.
    final FaceEmbedder embedder = await MobileFaceNetEmbedder.create();

    final users = FirestoreUserRepository();
    runApp(SnapshotApp(
      auth: FirebaseAuthBootstrap(),
      users: users,
      lobbies: FirestoreLobbyRepository(),
      tags: FirestoreTagRepository(),
      fcm: FcmRegistrar(users: users),
      embedder: embedder,
      activeLobbies: SharedPreferencesActiveLobbyStore(),
      buildTagPushListener: (key) => TagPushListener(messengerKey: key),
    ));
  } catch (err, stack) {
    // Anything before runApp throws into a no-UI void — wrap it so the
    // user sees the same _BootError surface the in-app FutureBuilder uses
    // for auth/profile-fetch failures, instead of a blank screen.
    debugPrint('Snapshot boot failed before first frame: $err\n$stack');
    runApp(MaterialApp(
      title: 'Snapshot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: _BootError(error: err),
    ));
  }
}

class SnapshotApp extends StatefulWidget {
  final AuthBootstrap auth;
  final UserRepository users;
  final LobbyRepository lobbies;
  final TagRepository tags;
  final FcmRegistrar fcm;
  final FaceEmbedder embedder;
  final ActiveLobbyStore activeLobbies;
  // Factory rather than a finished instance — the listener needs the
  // ScaffoldMessenger key, which is owned by `_SnapshotAppState`.
  final TagPushListener Function(GlobalKey<ScaffoldMessengerState>)
      buildTagPushListener;
  // Optional override for the in-round camera. Defaults to the real
  // package:camera-backed implementation; widget tests inject a fake
  // so they don't need a live platform channel.
  final RoundCamera Function()? cameraFactory;

  const SnapshotApp({
    super.key,
    required this.auth,
    required this.users,
    required this.lobbies,
    required this.tags,
    required this.fcm,
    required this.embedder,
    required this.activeLobbies,
    required this.buildTagPushListener,
    this.cameraFactory,
  });

  @override
  State<SnapshotApp> createState() => _SnapshotAppState();
}

/// Result of [_SnapshotAppState._boot]. Carries the user's profile (or null
/// for a new user who needs onboarding) plus an optional resume target for
/// auto-rejoining a lobby/round the user was last in.
class _BootResult {
  final UserProfile? profile;
  final _ResumeTarget? resume;
  const _BootResult({this.profile, this.resume});
}

class _ResumeTarget {
  final String lobbyId;
  final LobbyStatus status;
  const _ResumeTarget({required this.lobbyId, required this.status});
}

class _SnapshotAppState extends State<SnapshotApp> {
  late Future<_BootResult> _bootFuture;
  // Hoisted so the FCM listener can surface in-app banners (tech-plan §78)
  // without needing a BuildContext from inside the messaging callback.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  // Owns the Navigator the resume push targets — needed because the push
  // is scheduled from outside any widget that has a Navigator-aware context.
  final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();
  late final TagPushListener _tagPushes;
  bool _resumePushed = false;

  @override
  void initState() {
    super.initState();
    _bootFuture = _boot();
    _tagPushes = widget.buildTagPushListener(_messengerKey);
    // Attach early — the listener swallows messages whose type != 'tag',
    // so it's safe to leave on for the whole app lifecycle even if the
    // user is still on the onboarding screen when a stray message lands.
    unawaited(_tagPushes.attach());
  }

  @override
  void dispose() {
    // Best-effort release of native resources (TFLite interpreter + ML Kit
    // face detector). Mostly relevant for dev hot-restart, where the
    // process keeps running and a fresh embedder is created on each
    // restart — without this, each restart leaks one set of natives.
    // Production teardown (process exit) reclaims either way.
    unawaited(widget.embedder.close());
    unawaited(widget.fcm.dispose());
    unawaited(_tagPushes.dispose());
    super.dispose();
  }

  Future<_BootResult> _boot() async {
    final uid = await widget.auth.signInAnonymously();
    final profile = await widget.users.get(uid);
    if (profile == null) {
      // New user heading into onboarding — no resume to consider yet.
      return const _BootResult();
    }
    // Returning user — register for FCM in the background. Pre-onboarded
    // users have no users/{uid} doc, so we skip until onboarding writes
    // it; the post-onboarding callback below picks them up.
    unawaited(widget.fcm.register(uid));
    final resume = await _resolveResume();
    return _BootResult(profile: profile, resume: resume);
  }

  /// Reads the persisted active lobbyId (if any) and resolves it to a
  /// resume target. A target is only returned when the lobby still exists
  /// and is in `waiting` or `active`. Terminal states (the doc is gone or
  /// already `ended`) clear the persisted id so we don't loop on a dead
  /// lobby. Transient errors (timeout, network hiccup) skip resume for
  /// this boot but deliberately leave the stored id in place so the next
  /// launch can try again — assuming the user really is mid-game.
  Future<_ResumeTarget?> _resolveResume() async {
    final stored = await widget.activeLobbies.read();
    if (stored == null) return null;
    try {
      final lobby = await widget.lobbies
          .watchLobby(stored)
          .first
          .timeout(const Duration(seconds: 5));
      if (lobby == null || lobby.status == LobbyStatus.ended) {
        await widget.activeLobbies.clear();
        return null;
      }
      return _ResumeTarget(lobbyId: lobby.lobbyId, status: lobby.status);
    } catch (_) {
      // Transient — don't block boot, don't clear the hint. Next launch
      // will retry the lookup. (Terminal cases are handled above.)
      return null;
    }
  }

  void _onOnboardingComplete(UserProfile profile) {
    // Block body, not arrow — `setState` rejects callbacks that return a
    // value, and `_bootFuture = ...` evaluates to the assigned Future.
    setState(() {
      _bootFuture = Future.value(_BootResult(profile: profile));
    });
    // First-time users — onboarding just wrote users/{uid}, so the FCM
    // token write has a doc to update against. Fire and forget.
    unawaited(widget.fcm.register(profile.uid));
  }

  void _maybePushResume(UserProfile profile, _ResumeTarget? resume) {
    if (resume == null || _resumePushed) return;
    _resumePushed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = _navigatorKey.currentState;
      if (navigator == null) return;
      switch (resume.status) {
        case LobbyStatus.waiting:
          navigator.push(MaterialPageRoute(
            builder: (_) => WaitingRoomScreen(
              repo: widget.lobbies,
              tags: widget.tags,
              embedder: widget.embedder,
              activeLobbies: widget.activeLobbies,
              lobbyId: resume.lobbyId,
              currentUid: profile.uid,
              cameraFactory: widget.cameraFactory,
            ),
          ));
          break;
        case LobbyStatus.active:
          navigator.push(MaterialPageRoute(
            builder: (_) => RoundScreen(
              repo: widget.lobbies,
              tags: widget.tags,
              embedder: widget.embedder,
              activeLobbies: widget.activeLobbies,
              lobbyId: resume.lobbyId,
              currentUid: profile.uid,
              cameraFactory: widget.cameraFactory,
            ),
          ));
          break;
        case LobbyStatus.ended:
          // Filtered out in _resolveResume — unreachable.
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapshot',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: FutureBuilder<_BootResult>(
        future: _bootFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _BootSplash();
          }
          if (snapshot.hasError) {
            return _BootError(error: snapshot.error!);
          }
          final result = snapshot.data!;
          final profile = result.profile;
          if (profile == null) {
            return OnboardingFlow(
              auth: widget.auth,
              users: widget.users,
              embedder: widget.embedder,
              onComplete: _onOnboardingComplete,
            );
          }
          // Resume into the saved lobby/round, if any. The push is
          // scheduled post-frame so _Home is the underlying route — that
          // way "Back to home" from the round results screen lands on
          // LobbyEntryScreen as it always has.
          _maybePushResume(profile, result.resume);
          return _Home(
            profile: profile,
            embedder: widget.embedder,
            lobbies: widget.lobbies,
            tags: widget.tags,
            activeLobbies: widget.activeLobbies,
            cameraFactory: widget.cameraFactory,
          );
        },
      ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _BootError extends StatelessWidget {
  final Object error;
  const _BootError({required this.error});

  @override
  Widget build(BuildContext context) {
    debugPrint('Snapshot boot failed: $error');
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Couldn't start Snapshot.",
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 8),
              const Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 16),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Post-onboarding home. Primary CTAs are Create / Join (lobby flow,
/// tech-plan §318). The §314 "Re-scan & compare" sanity panel sits below
/// in debug builds — it's still useful for eyeballing pipeline latency
/// and discrimination, but it's no longer the only thing on the screen.
class _Home extends StatefulWidget {
  final UserProfile profile;
  final FaceEmbedder embedder;
  final LobbyRepository lobbies;
  final TagRepository tags;
  final ActiveLobbyStore activeLobbies;
  final RoundCamera Function()? cameraFactory;
  const _Home({
    required this.profile,
    required this.embedder,
    required this.lobbies,
    required this.tags,
    required this.activeLobbies,
    this.cameraFactory,
  });

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _verifying = false;
  double? _cosine;
  int? _elapsedMs;
  String? _error;

  Future<void> _rescan() async {
    setState(() {
      _verifying = true;
      _cosine = null;
      _elapsedMs = null;
      _error = null;
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1280,
        maxHeight: 1280,
      );
      if (!mounted) return;
      if (picked == null) {
        setState(() => _verifying = false);
        return;
      }
      final bytes = await File(picked.path).readAsBytes();
      final stopwatch = Stopwatch()..start();
      final newEmbedding = await widget.embedder.embed(bytes);
      stopwatch.stop();
      final cosine = cosineSimilarity(
        widget.profile.faceEmbedding,
        newEmbedding,
      );
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _cosine = cosine;
        _elapsedMs = stopwatch.elapsedMilliseconds;
      });
    } on NoFaceDetectedException {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = "No face detected — try better lighting.";
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = 'Failed: $err';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LobbyEntryScreen(
      repo: widget.lobbies,
      tags: widget.tags,
      embedder: widget.embedder,
      activeLobbies: widget.activeLobbies,
      currentUid: widget.profile.uid,
      displayName: widget.profile.displayName,
      cameraFactory: widget.cameraFactory,
      child: kDebugMode ? _verifyPanel() : null,
    );
  }

  Widget _verifyPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Verify face recognition (§314 sanity)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Same face → cosine ≳ 0.7. Different face → cosine ≲ 0.4. '
            'Production threshold is 0.65.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _verifying ? null : _rescan,
            icon: const Icon(Icons.refresh),
            label: Text(_verifying ? 'Scanning…' : 'Re-scan & compare'),
          ),
          if (_cosine != null) ...[
            const SizedBox(height: 8),
            Text(
              'cosine: ${_cosine!.toStringAsFixed(3)}    '
              'embed pipeline: ${_elapsedMs}ms',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

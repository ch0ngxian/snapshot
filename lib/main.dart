import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'face/cosine_similarity.dart';
import 'face/face_embedder.dart';
import 'face/mobilefacenet_embedder.dart';
import 'face/no_face_detected_exception.dart';
import 'firebase_options.dart';
import 'lobby/lobby_entry_screen.dart';
import 'models/user_profile.dart';
import 'onboarding/onboarding_flow.dart';
import 'services/auth_bootstrap.dart';
import 'services/firebase_auth_bootstrap.dart';
import 'services/firestore_lobby_repository.dart';
import 'services/firestore_user_repository.dart';
import 'services/lobby_repository.dart';
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

    runApp(SnapshotApp(
      auth: FirebaseAuthBootstrap(),
      users: FirestoreUserRepository(),
      lobbies: FirestoreLobbyRepository(),
      embedder: embedder,
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
  final FaceEmbedder embedder;

  const SnapshotApp({
    super.key,
    required this.auth,
    required this.users,
    required this.lobbies,
    required this.embedder,
  });

  @override
  State<SnapshotApp> createState() => _SnapshotAppState();
}

class _SnapshotAppState extends State<SnapshotApp> {
  late Future<UserProfile?> _bootFuture;

  @override
  void initState() {
    super.initState();
    _bootFuture = _boot();
  }

  @override
  void dispose() {
    // Best-effort release of native resources (TFLite interpreter + ML Kit
    // face detector). Mostly relevant for dev hot-restart, where the
    // process keeps running and a fresh embedder is created on each
    // restart — without this, each restart leaks one set of natives.
    // Production teardown (process exit) reclaims either way.
    unawaited(widget.embedder.close());
    super.dispose();
  }

  Future<UserProfile?> _boot() async {
    final uid = await widget.auth.signInAnonymously();
    return widget.users.get(uid);
  }

  void _onOnboardingComplete(UserProfile profile) {
    // Block body, not arrow — `setState` rejects callbacks that return a
    // value, and `_bootFuture = ...` evaluates to the assigned Future.
    setState(() {
      _bootFuture = Future.value(profile);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapshot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: FutureBuilder<UserProfile?>(
        future: _bootFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _BootSplash();
          }
          if (snapshot.hasError) {
            return _BootError(error: snapshot.error!);
          }
          final profile = snapshot.data;
          if (profile == null) {
            return OnboardingFlow(
              auth: widget.auth,
              users: widget.users,
              embedder: widget.embedder,
              onComplete: _onOnboardingComplete,
            );
          }
          return _Home(
            profile: profile,
            embedder: widget.embedder,
            lobbies: widget.lobbies,
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
  const _Home({
    required this.profile,
    required this.embedder,
    required this.lobbies,
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
      displayName: widget.profile.displayName,
      // Verification panel is still embedded as a debug affordance — see
      // _verifyPanel below. Using a wrapper keeps LobbyEntryScreen widget-
      // testable in isolation.
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

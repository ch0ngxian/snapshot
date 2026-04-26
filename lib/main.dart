import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'face/face_embedder.dart';
import 'face/testing/fake_face_embedder.dart';
import 'firebase_options.dart';
import 'models/user_profile.dart';
import 'onboarding/onboarding_flow.dart';
import 'services/auth_bootstrap.dart';
import 'services/firebase_auth_bootstrap.dart';
import 'services/firestore_user_repository.dart';
import 'services/user_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // TODO(phase-0-followup): swap to MobileFaceNetEmbedder.create() once the
  // .tflite asset is sourced (see tools/fetch_model.sh + assets/models/NOTICE.md).
  // FakeFaceEmbedder produces deterministic 192-dim vectors so onboarding
  // wiring and Firestore writes can be exercised end-to-end in the meantime.
  const FaceEmbedder embedder = FakeFaceEmbedder();

  runApp(SnapshotApp(
    auth: FirebaseAuthBootstrap(),
    users: FirestoreUserRepository(),
    embedder: embedder,
  ));
}

class SnapshotApp extends StatefulWidget {
  final AuthBootstrap auth;
  final UserRepository users;
  final FaceEmbedder embedder;

  const SnapshotApp({
    super.key,
    required this.auth,
    required this.users,
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

  Future<UserProfile?> _boot() async {
    final uid = await widget.auth.signInAnonymously();
    return widget.users.get(uid);
  }

  void _onOnboardingComplete(UserProfile profile) {
    setState(() => _bootFuture = Future.value(profile));
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
          return _Home(profile: profile);
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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not start Snapshot: $error'),
        ),
      ),
    );
  }
}

/// Phase 0 placeholder home. Lobby UI lands in Phase 1.
class _Home extends StatelessWidget {
  final UserProfile profile;
  const _Home({required this.profile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Hi, ${profile.displayName}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You are onboarded.',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text('uid: ${profile.uid}'),
            Text('embedding model: ${profile.embeddingModelVersion}'),
            Text('embedding dim: ${profile.faceEmbedding.length}'),
            const SizedBox(height: 24),
            const Text(
              'Lobby UI lands in Phase 1.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}

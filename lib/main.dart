import 'package:flutter/material.dart';

import 'face/testing/fake_face_embedder.dart';
import 'models/user_profile.dart';
import 'onboarding/onboarding_flow.dart';
import 'services/testing/fake_auth_bootstrap.dart';
import 'services/testing/in_memory_user_repository.dart';

void main() {
  runApp(const SnapshotApp());
}

class SnapshotApp extends StatelessWidget {
  const SnapshotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapshot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _PlaceholderHome(),
    );
  }
}

/// Phase 0 placeholder. Production wiring (Firebase + MobileFaceNetEmbedder)
/// lands in a follow-up PR after `flutterfire configure` is run and the model
/// asset is sourced. For now, tapping the demo button runs the onboarding
/// flow with in-memory fakes so the screens can be hand-tested on a device.
class _PlaceholderHome extends StatefulWidget {
  const _PlaceholderHome();

  @override
  State<_PlaceholderHome> createState() => _PlaceholderHomeState();
}

class _PlaceholderHomeState extends State<_PlaceholderHome> {
  UserProfile? _completed;

  void _runDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OnboardingFlow(
          auth: FakeAuthBootstrap(),
          users: InMemoryUserRepository(),
          embedder: const FakeFaceEmbedder(),
          onComplete: (profile) {
            setState(() => _completed = profile);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Snapshot — Phase 0')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Phase 0 scaffold. Production wiring needs:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text("• `flutterfire configure` to generate firebase_options.dart"),
            const Text('• `tools/fetch_model.sh` (or manual drop) for the MobileFaceNet TFLite asset'),
            const Text('• `firebase deploy` for rules + functions + Remote Config'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _runDemo,
              child: const Text('Try onboarding (demo mode)'),
            ),
            if (_completed != null) ...[
              const SizedBox(height: 24),
              const Text(
                'Last demo run:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('uid: ${_completed!.uid}'),
              Text('name: ${_completed!.displayName}'),
              Text('embedding dim: ${_completed!.faceEmbedding.length}'),
              Text('model: ${_completed!.embeddingModelVersion}'),
              Text('createdAt: ${_completed!.createdAt.toIso8601String()}'),
            ],
          ],
        ),
      ),
    );
  }
}

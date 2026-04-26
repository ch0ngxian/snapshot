import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../face/face_embedder.dart';
import '../models/user_profile.dart';
import '../services/auth_bootstrap.dart';
import '../services/user_repository.dart';
import 'consent_screen.dart';
import 'display_name_screen.dart';
import 'selfie_capture_screen.dart';

/// Orchestrates the three-step onboarding flow:
///   1. Display name
///   2. Selfie capture (runs through [FaceEmbedder])
///   3. Consent
/// Then writes the [UserProfile] via [UserRepository] and calls [onComplete].
///
/// Stateless from the outside — it owns its own internal step state.
class OnboardingFlow extends StatefulWidget {
  final AuthBootstrap auth;
  final UserRepository users;
  final FaceEmbedder embedder;
  final ValueChanged<UserProfile> onComplete;

  /// Clock injection for tests; defaults to [DateTime.now].
  final DateTime Function()? now;

  /// Test-only override for the system camera picker. Forwarded to
  /// [SelfieCaptureScreen] so end-to-end tests don't need a platform channel.
  /// Returns image bytes or `null` on cancel.
  @visibleForTesting
  final Future<Uint8List?> Function()? pickerOverride;

  const OnboardingFlow({
    super.key,
    required this.auth,
    required this.users,
    required this.embedder,
    required this.onComplete,
    this.now,
    this.pickerOverride,
  });

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _Step { name, selfie, consent }

class _OnboardingFlowState extends State<OnboardingFlow> {
  _Step _step = _Step.name;
  String? _name;
  SelfieResult? _selfie;

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.name:
        return DisplayNameScreen(
          onContinue: (name) {
            setState(() {
              _name = name;
              _step = _Step.selfie;
            });
          },
        );
      case _Step.selfie:
        return SelfieCaptureScreen(
          embedder: widget.embedder,
          pickerOverride: widget.pickerOverride,
          onCaptured: (result) {
            setState(() {
              _selfie = result;
              _step = _Step.consent;
            });
          },
        );
      case _Step.consent:
        return ConsentScreen(onAccepted: _finish);
    }
  }

  Future<void> _finish() async {
    final name = _name;
    final selfie = _selfie;
    if (name == null || selfie == null) {
      // Defensive — UI doesn't allow reaching consent without prior steps.
      return;
    }
    final uid = await widget.auth.signInAnonymously();
    final profile = UserProfile(
      uid: uid,
      displayName: name,
      faceEmbedding: selfie.embedding,
      embeddingModelVersion: selfie.modelVersion,
      createdAt: (widget.now ?? DateTime.now)(),
    );
    await widget.users.save(profile);
    widget.onComplete(profile);
  }
}

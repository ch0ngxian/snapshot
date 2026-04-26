import 'dart:typed_data';

/// User profile written to `users/{uid}` on Firestore at the end of onboarding.
/// Schema mirrors tech-plan.md §3 — keep in sync.
class UserProfile {
  final String uid;
  final String displayName;
  final Float32List faceEmbedding;
  final String embeddingModelVersion;
  final DateTime createdAt;

  const UserProfile({
    required this.uid,
    required this.displayName,
    required this.faceEmbedding,
    required this.embeddingModelVersion,
    required this.createdAt,
  });
}

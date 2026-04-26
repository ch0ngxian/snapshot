import '../models/user_profile.dart';

/// Reads and writes `users/{uid}` records. Concrete Firestore-backed
/// implementation lands in a follow-up PR after `flutterfire configure` is
/// run (Phase 0 manual followup).
abstract class UserRepository {
  /// Returns the profile for [uid], or `null` if the user hasn't completed
  /// onboarding yet.
  Future<UserProfile?> get(String uid);

  /// Persists [profile] to Firestore. Overwrites existing data — onboarding
  /// is the only write path in v1.
  Future<void> save(UserProfile profile);
}

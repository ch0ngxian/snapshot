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

  /// Updates `users/{uid}.fcmToken` after FCM registration succeeds.
  /// Required by `submitTag`'s best-effort push to the victim — see
  /// tech-plan §326. Token-only update; other onboarding fields are not
  /// touched (firestore.rules `isValidFcmTokenUpdate`).
  Future<void> setFcmToken(String uid, String token);
}

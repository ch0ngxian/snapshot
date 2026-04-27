import '../../models/user_profile.dart';
import '../user_repository.dart';

/// Test-only in-memory [UserRepository]. Survives within a single test, no
/// persistence beyond that.
class InMemoryUserRepository implements UserRepository {
  final Map<String, UserProfile> _store = {};
  final Map<String, String> _fcmTokens = {};

  @override
  Future<UserProfile?> get(String uid) async => _store[uid];

  @override
  Future<void> save(UserProfile profile) async {
    _store[profile.uid] = profile;
  }

  @override
  Future<void> setFcmToken(String uid, String token) async {
    _fcmTokens[uid] = token;
  }

  /// Test-only inspector — returns the token last set for [uid], or `null`
  /// if [setFcmToken] hasn't been called for this user.
  String? fcmTokenFor(String uid) => _fcmTokens[uid];
}

import '../../models/user_profile.dart';
import '../user_repository.dart';

/// Test-only in-memory [UserRepository]. Survives within a single test, no
/// persistence beyond that.
class InMemoryUserRepository implements UserRepository {
  final Map<String, UserProfile> _store = {};

  @override
  Future<UserProfile?> get(String uid) async => _store[uid];

  @override
  Future<void> save(UserProfile profile) async {
    _store[profile.uid] = profile;
  }
}

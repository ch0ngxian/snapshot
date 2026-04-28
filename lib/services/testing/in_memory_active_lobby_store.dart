import '../active_lobby_store.dart';

/// Test-only in-memory [ActiveLobbyStore]. Surfaces the saved lobbyId
/// synchronously via [current] so widget tests can assert that screens
/// save / clear it at the right moments without driving a real
/// SharedPreferences platform channel.
class InMemoryActiveLobbyStore implements ActiveLobbyStore {
  String? current;

  InMemoryActiveLobbyStore({this.current});

  @override
  Future<String?> read() async => current;

  @override
  Future<void> save(String lobbyId) async {
    current = lobbyId;
  }

  @override
  Future<void> clear() async {
    current = null;
  }
}

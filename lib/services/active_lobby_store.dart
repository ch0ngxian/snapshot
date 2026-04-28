import 'package:shared_preferences/shared_preferences.dart';

/// Persists the lobbyId of the lobby/round the user is currently inside,
/// so that closing and relaunching the app drops them back into the
/// in-progress game instead of the home screen.
abstract class ActiveLobbyStore {
  Future<void> save(String lobbyId);
  Future<String?> read();
  Future<void> clear();
}

class SharedPreferencesActiveLobbyStore implements ActiveLobbyStore {
  static const String _key = 'active_lobby_id';

  @override
  Future<void> save(String lobbyId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, lobbyId);
  }

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

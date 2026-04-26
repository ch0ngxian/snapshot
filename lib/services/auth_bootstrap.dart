/// Anonymous-auth bootstrap. The concrete implementation (lands in a
/// follow-up PR after `flutterfire configure`) signs the user in with
/// `FirebaseAuth.signInAnonymously()` and persists the session.
abstract class AuthBootstrap {
  /// The current user's uid, or `null` if not yet signed in.
  String? get currentUid;

  /// Signs in anonymously if not already signed in. Returns the uid.
  Future<String> signInAnonymously();
}

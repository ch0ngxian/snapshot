import 'package:firebase_auth/firebase_auth.dart';

import 'auth_bootstrap.dart';

/// Production [AuthBootstrap]: signs the user in anonymously via FirebaseAuth.
/// Anonymous sessions persist across app restarts on the same device, so the
/// uid is stable for as long as the app is installed.
class FirebaseAuthBootstrap implements AuthBootstrap {
  final FirebaseAuth _auth;

  FirebaseAuthBootstrap({FirebaseAuth? auth})
      : _auth = auth ?? FirebaseAuth.instance;

  @override
  String? get currentUid => _auth.currentUser?.uid;

  @override
  Future<String> signInAnonymously() async {
    final existing = _auth.currentUser;
    if (existing != null) return existing.uid;
    final credential = await _auth.signInAnonymously();
    return credential.user!.uid;
  }
}

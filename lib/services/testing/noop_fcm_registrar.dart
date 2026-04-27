import '../fcm_registrar.dart';

/// Test-only [FcmRegistrar] that records every register call. Use in
/// widget tests where the Firebase plugin isn't initialized — the
/// production [FcmRegistrar] would throw on `FirebaseMessaging.instance`
/// access in that environment.
class NoopFcmRegistrar implements FcmRegistrar {
  final List<String> registered = [];
  bool disposed = false;

  @override
  Future<void> register(String uid) async {
    registered.add(uid);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

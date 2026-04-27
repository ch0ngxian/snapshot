import '../tag_push_listener.dart';

/// Test-only no-op [TagPushListener]. Records attach/dispose so widget
/// tests can assert lifecycle wiring without touching the FCM stream
/// (which `FirebaseMessaging.instance` would throw on outside an
/// initialized Firebase environment).
class NoopTagPushListener implements TagPushListener {
  bool attached = false;
  bool disposed = false;

  @override
  Future<void> attach() async {
    attached = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

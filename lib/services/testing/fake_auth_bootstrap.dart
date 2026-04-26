import '../auth_bootstrap.dart';

/// Test-only [AuthBootstrap] that pretends to sign in anonymously and just
/// hands back a configurable uid.
class FakeAuthBootstrap implements AuthBootstrap {
  String? _uid;
  final String fixedUid;

  FakeAuthBootstrap({this.fixedUid = 'test-uid'});

  @override
  String? get currentUid => _uid;

  @override
  Future<String> signInAnonymously() async {
    _uid ??= fixedUid;
    return _uid!;
  }
}

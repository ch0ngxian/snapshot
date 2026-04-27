import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'user_repository.dart';

/// Registers the device with FCM and persists the resulting token to
/// `users/{uid}.fcmToken` so `submitTag` can push the victim a "you were
/// tagged!" notification (tech-plan §326). All errors here are best-effort
/// — a permission denial, an APNs misconfiguration, or a write failure
/// must not block the user from playing. Worst case the victim simply
/// doesn't get a push; the verdict toast on the tagger's side is the
/// authoritative game state.
abstract class FcmRegistrar {
  Future<void> register(String uid);
  Future<void> dispose();

  /// Production registrar wired to `FirebaseMessaging.instance` and the
  /// supplied [UserRepository]. Tests should use `NoopFcmRegistrar`
  /// instead — Firebase plugins aren't initialized in widget-test mode.
  factory FcmRegistrar({
    FirebaseMessaging? messaging,
    required UserRepository users,
  }) = _FirebaseFcmRegistrar;
}

class _FirebaseFcmRegistrar implements FcmRegistrar {
  final FirebaseMessaging _messaging;
  final UserRepository _users;
  StreamSubscription<String>? _refreshSub;

  _FirebaseFcmRegistrar({
    FirebaseMessaging? messaging,
    required UserRepository users,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _users = users;

  /// Idempotent — safe to call on every app launch. Requests notification
  /// permission, fetches the current token, persists it, and listens for
  /// token rotations. The first call after install will prompt the user;
  /// subsequent calls are silent.
  @override
  Future<void> register(String uid) async {
    // Cancel any prior subscription up front so every code path below —
    // including the permission-denied early return — leaves us with at
    // most one live onTokenRefresh listener. Otherwise a re-onboard or a
    // permission revocation between calls strands the previous listener,
    // which would keep writing tokens for a user who has just denied
    // them.
    await _refreshSub?.cancel();
    _refreshSub = null;

    try {
      // iOS prompts; Android 13+ also prompts via the permission delegate
      // baked into firebase_messaging. On older Androids this returns
      // `authorized` without showing UI — same code path either way.
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('FcmRegistrar: notification permission denied — skipping');
        return;
      }

      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _users.setFcmToken(uid, token);
      }

      // Tokens rotate (app restore, FCM-side housekeeping). Listen for the
      // refresh stream so we never serve a stale victim push from a stored
      // token that no longer points at this device.
      _refreshSub = _messaging.onTokenRefresh.listen(
        (newToken) async {
          if (newToken.isEmpty) return;
          try {
            await _users.setFcmToken(uid, newToken);
          } catch (e) {
            debugPrint('FcmRegistrar: token refresh write failed: $e');
          }
        },
        onError: (Object e) =>
            debugPrint('FcmRegistrar: onTokenRefresh stream error: $e'),
      );
    } catch (e, stack) {
      // Don't propagate — boot must continue even if FCM is misconfigured
      // (e.g. APNs entitlement missing in dev, simulator without push).
      debugPrint('FcmRegistrar: register failed: $e\n$stack');
    }
  }

  @override
  Future<void> dispose() async {
    await _refreshSub?.cancel();
    _refreshSub = null;
  }
}

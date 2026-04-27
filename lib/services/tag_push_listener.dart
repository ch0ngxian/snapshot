import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Surfaces incoming "you were tagged" FCM messages while the app is in
/// the foreground (tech-plan §78: push + in-app banner + haptic). System
/// notifications cover the background path; iOS auto-displays the
/// notification block, Android does the same once an `Importance` channel
/// is configured by the FCM SDK.
abstract class TagPushListener {
  Future<void> attach();
  Future<void> dispose();

  /// Production listener wired to `FirebaseMessaging.onMessage`.
  /// Tests should use `NoopTagPushListener` — `FirebaseMessaging.instance`
  /// throws when Firebase plugins aren't initialized.
  factory TagPushListener({
    required GlobalKey<ScaffoldMessengerState> messengerKey,
    FirebaseMessaging? messaging,
    Future<void> Function()? haptic,
  }) = _FirebaseTagPushListener;
}

class _FirebaseTagPushListener implements TagPushListener {
  final FirebaseMessaging _messaging;
  final GlobalKey<ScaffoldMessengerState> _messengerKey;

  /// Override the haptic call for tests. Production calls
  /// `HapticFeedback.heavyImpact`.
  final Future<void> Function() _haptic;

  StreamSubscription<RemoteMessage>? _foregroundSub;

  _FirebaseTagPushListener({
    required GlobalKey<ScaffoldMessengerState> messengerKey,
    FirebaseMessaging? messaging,
    Future<void> Function()? haptic,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _messengerKey = messengerKey,
        _haptic = haptic ?? HapticFeedback.heavyImpact;

  /// Idempotent — subsequent calls cancel the prior subscription before
  /// re-attaching, so hot-restart in dev doesn't pile up listeners.
  @override
  Future<void> attach() async {
    await _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen(
      _handleMessage,
      onError: (Object e) =>
          debugPrint('TagPushListener: onMessage stream error: $e'),
    );
    // Best-effort — calling getInitialMessage drains the launch-from-tap
    // payload so a tap on the lockscreen notification doesn't replay as
    // an in-app banner once the app boots. The actual deep-link handling
    // (e.g. routing to the round) is a polish-PR item.
    try {
      await _messaging.getInitialMessage();
    } catch (e) {
      debugPrint('TagPushListener: getInitialMessage failed: $e');
    }
  }

  void _handleMessage(RemoteMessage message) {
    final data = message.data;
    if (data['type'] != 'tag') return;

    final notification = message.notification;
    final title = notification?.title ?? 'You were tagged!';
    final body = notification?.body;

    final messenger = _messengerKey.currentState;
    if (messenger == null) {
      debugPrint('TagPushListener: messenger not mounted, dropping banner');
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(body == null ? title : '$title — $body'),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );

    unawaited(_haptic().catchError((Object e) {
      debugPrint('TagPushListener: haptic failed: $e');
    }));
  }

  @override
  Future<void> dispose() async {
    await _foregroundSub?.cancel();
    _foregroundSub = null;
  }
}

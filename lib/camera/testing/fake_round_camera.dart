import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../round_camera.dart';

/// In-memory [RoundCamera] for widget tests. Returns canned bytes from
/// [captureFrame] and a tappable placeholder for [previewWidget].
///
/// Tests can also throw on capture (to exercise the error path) or
/// return `null` (to mimic "camera not ready yet").
class FakeRoundCamera implements RoundCamera {
  /// Bytes returned by [captureFrame]. If `null`, [captureFrame] returns
  /// `null` (i.e. camera not ready / capture aborted).
  Uint8List? framePayload;

  /// If set, [captureFrame] throws this instead of returning bytes.
  Object? throwOnCapture;

  bool _initialized = false;
  bool _disposed = false;

  /// Counters useful for asserting against in tests.
  int initializeCalls = 0;
  int captureCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int disposeCalls = 0;

  FakeRoundCamera({this.framePayload, this.throwOnCapture});

  @override
  bool get isInitialized => _initialized && !_disposed;

  /// Tests can override this if they want to assert on layout against
  /// a different shape; defaults to a typical portrait phone preview.
  @override
  double previewAspectRatio = 9 / 16;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _initialized = true;
  }

  @override
  Future<Uint8List?> captureFrame() async {
    captureCalls++;
    if (throwOnCapture != null) throw throwOnCapture!;
    return framePayload;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _disposed = true;
    _initialized = false;
  }

  @override
  Widget previewWidget(BuildContext context) {
    // A sentinel surface tests can find by Key if they need to assert
    // the preview is mounted under the HUD.
    return const ColoredBox(
      key: Key('fake-round-camera-preview'),
      color: Color(0xFF101010),
    );
  }
}

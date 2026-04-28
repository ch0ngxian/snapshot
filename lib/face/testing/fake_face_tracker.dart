import 'dart:async';

import '../face_tracker.dart';

/// In-memory [FaceTracker] for widget tests. Tests push detections via
/// [emit] (or the convenience [emitNone]); the round screen treats the
/// fake exactly like the production tracker.
class FakeFaceTracker implements FaceTracker {
  final StreamController<TrackedFace?> _controller =
      StreamController<TrackedFace?>.broadcast();

  bool _started = false;
  bool _stopped = false;
  bool _disposed = false;

  /// Counters useful for asserting against in tests.
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  /// Convenience: push a detection through the stream so subscribers
  /// see `face` as the latest [TrackedFace].
  void emit(TrackedFace? face) {
    _controller.add(face);
  }

  /// Convenience for the "no face in frame" state.
  void emitNone() => emit(null);

  bool get isStarted => _started && !_stopped && !_disposed;

  @override
  Future<void> start() async {
    startCalls++;
    _started = true;
    _stopped = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _stopped = true;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _disposed = true;
    await _controller.close();
  }

  @override
  Stream<TrackedFace?> get faces => _controller.stream;
}

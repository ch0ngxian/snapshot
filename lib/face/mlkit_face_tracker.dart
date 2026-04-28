import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:camera/camera.dart' show CameraImage;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../camera/round_camera.dart';
import 'face_tracker.dart';

/// Production [FaceTracker] backed by ML Kit's on-device face detector.
/// Subscribes to [RoundCamera.startImageStream], runs detection on a
/// throttled subset of preview frames, and emits the largest detected
/// face — bounding box pre-rotated into preview-widget space —
/// alongside an aim-lock flag that flips on when the face is roughly
/// centered and large enough that a tag is likely to match.
///
/// Throttling rules (GAMEPLAY.md §164 — running ML Kit on every frame
/// melts low-end Android):
/// - At most one detection in flight at a time. Frames that arrive
///   while a detection is running are dropped.
/// - A minimum interval between successive detections, default 150ms
///   (~6 Hz). Plenty smooth for tracking a person's head; conservative
///   on battery.
class MlKitFaceTracker implements FaceTracker {
  /// Aim-lock thresholds, exposed so tests / future tuning can override
  /// them without forking the class.
  static const double _defaultMaxOffCenter = 0.18;
  static const double _defaultMinFaceHeight = 0.22;
  static const Duration _defaultMinInterval = Duration(milliseconds: 150);

  final RoundCamera _camera;
  final FaceDetector _detector;
  final Duration _minInterval;
  final double _maxOffCenter;
  final double _minFaceHeight;

  final StreamController<TrackedFace?> _controller =
      StreamController<TrackedFace?>.broadcast();

  bool _processing = false;
  DateTime _lastRunAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _started = false;
  bool _disposed = false;

  MlKitFaceTracker._({
    required RoundCamera camera,
    required FaceDetector detector,
    required Duration minInterval,
    required double maxOffCenter,
    required double minFaceHeight,
  })  : _camera = camera,
        _detector = detector,
        _minInterval = minInterval,
        _maxOffCenter = maxOffCenter,
        _minFaceHeight = minFaceHeight;

  /// Build a tracker bound to [camera]. The detector runs in `fast`
  /// mode (vs. the embedder's `accurate` mode) — we don't need
  /// landmarks or contours for the reticle, just a bounding box, and
  /// `fast` is the lighter of the two.
  factory MlKitFaceTracker({
    required RoundCamera camera,
    Duration minInterval = _defaultMinInterval,
    double maxOffCenter = _defaultMaxOffCenter,
    double minFaceHeight = _defaultMinFaceHeight,
  }) {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: false,
        enableLandmarks: false,
        enableClassification: false,
        enableTracking: false,
        minFaceSize: 0.15,
      ),
    );
    return MlKitFaceTracker._(
      camera: camera,
      detector: detector,
      minInterval: minInterval,
      maxOffCenter: maxOffCenter,
      minFaceHeight: minFaceHeight,
    );
  }

  @override
  Stream<TrackedFace?> get faces => _controller.stream;

  @override
  Future<void> start() async {
    if (_disposed) {
      throw StateError('MlKitFaceTracker used after dispose().');
    }
    if (_started) return;
    _started = true;
    await _camera.startImageStream(_handleFrame);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _camera.stopImageStream();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    // ML Kit's close() goes through a method channel — catch so a
    // teardown failure (e.g. the platform side already gone during a
    // hot-restart) doesn't escape as an uncaught error.
    try {
      await _detector.close();
    } catch (e, st) {
      debugPrint('MlKitFaceTracker detector close failed: $e\n$st');
    }
    await _controller.close();
  }

  void _handleFrame(CameraImage image) {
    if (_disposed || !_started) return;
    if (_processing) return;
    final now = DateTime.now();
    if (now.difference(_lastRunAt) < _minInterval) return;
    _processing = true;
    _lastRunAt = now;
    unawaited(_runDetection(image).whenComplete(() => _processing = false));
  }

  Future<void> _runDetection(CameraImage image) async {
    try {
      final input = _toInputImage(image);
      if (input == null) {
        if (!_controller.isClosed) _controller.add(null);
        return;
      }
      final detected = await _detector.processImage(input);
      if (_disposed || _controller.isClosed) return;
      if (detected.isEmpty) {
        _controller.add(null);
        return;
      }
      final largest = detected.reduce((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaA >= areaB ? a : b;
      });
      final tracked = _toTrackedFace(
        sensorBox: largest.boundingBox,
        sensorWidth: image.width.toDouble(),
        sensorHeight: image.height.toDouble(),
        sensorOrientation: _camera.sensorOrientation,
      );
      _controller.add(tracked);
    } catch (e, st) {
      // Failed frame is not the end of the world — log and keep
      // listening. The reticle just won't update from this frame.
      debugPrint('MlKitFaceTracker detection failed: $e\n$st');
    }
  }

  /// Constructs an [InputImage] from a raw camera frame. Format is
  /// platform-specific (NV21 on Android, BGRA on iOS) — both come
  /// through as a single contiguous buffer in [CameraImage.planes[0]].
  InputImage? _toInputImage(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final InputImageFormat? format = _formatFor(image);
    if (format == null) return null;
    // Pass rotation=0 — the post-detection bounding-box rotation in
    // [_toTrackedFace] is the source of truth for orientation. Letting
    // ML Kit rotate too would double-rotate.
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation0deg,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );
    return InputImage.fromBytes(
      bytes: Uint8List.fromList(plane.bytes),
      metadata: metadata,
    );
  }

  InputImageFormat? _formatFor(CameraImage image) {
    if (Platform.isAndroid) return InputImageFormat.nv21;
    if (Platform.isIOS) return InputImageFormat.bgra8888;
    return null;
  }

  TrackedFace _toTrackedFace({
    required Rect sensorBox,
    required double sensorWidth,
    required double sensorHeight,
    required int sensorOrientation,
  }) {
    final normalized = rotateAndNormalizeBox(
      sensorBox: sensorBox,
      sensorWidth: sensorWidth,
      sensorHeight: sensorHeight,
      sensorOrientation: sensorOrientation,
    );
    final aimLocked = isAimLocked(
      normalized,
      maxOffCenter: _maxOffCenter,
      minFaceHeight: _minFaceHeight,
    );
    return TrackedFace(normalizedBounds: normalized, aimLocked: aimLocked);
  }

  /// Rotates [sensorBox] by [sensorOrientation] degrees clockwise and
  /// normalizes against the *rotated* image dimensions, so the result
  /// is in preview-widget coordinate space — `(0, 0)` top-left,
  /// `(1, 1)` bottom-right.
  ///
  /// Visible for testing — the math is fiddly and we'd rather assert
  /// against it directly than try to mount a real ML Kit detector.
  static Rect rotateAndNormalizeBox({
    required Rect sensorBox,
    required double sensorWidth,
    required double sensorHeight,
    required int sensorOrientation,
  }) {
    switch (sensorOrientation % 360) {
      case 90:
        // 90° CW: (x, y) sensor → (sensorH - y, x) preview.
        // After rotation, preview width = sensorH, preview height = sensorW.
        return Rect.fromLTRB(
          (sensorHeight - sensorBox.bottom) / sensorHeight,
          sensorBox.left / sensorWidth,
          (sensorHeight - sensorBox.top) / sensorHeight,
          sensorBox.right / sensorWidth,
        );
      case 180:
        return Rect.fromLTRB(
          (sensorWidth - sensorBox.right) / sensorWidth,
          (sensorHeight - sensorBox.bottom) / sensorHeight,
          (sensorWidth - sensorBox.left) / sensorWidth,
          (sensorHeight - sensorBox.top) / sensorHeight,
        );
      case 270:
        // 270° CW = 90° CCW: (x, y) sensor → (y, sensorW - x) preview.
        return Rect.fromLTRB(
          sensorBox.top / sensorHeight,
          (sensorWidth - sensorBox.right) / sensorWidth,
          sensorBox.bottom / sensorHeight,
          (sensorWidth - sensorBox.left) / sensorWidth,
        );
      case 0:
      default:
        return Rect.fromLTRB(
          sensorBox.left / sensorWidth,
          sensorBox.top / sensorHeight,
          sensorBox.right / sensorWidth,
          sensorBox.bottom / sensorHeight,
        );
    }
  }

  /// `true` when [normalized] is roughly centered AND tall enough that
  /// a tag is likely to match. Visible for testing.
  static bool isAimLocked(
    Rect normalized, {
    required double maxOffCenter,
    required double minFaceHeight,
  }) {
    final cx = normalized.center.dx;
    final cy = normalized.center.dy;
    final offset = ((cx - 0.5).abs() + (cy - 0.5).abs());
    if (offset > maxOffCenter) return false;
    if (normalized.height < minFaceHeight) return false;
    return true;
  }
}

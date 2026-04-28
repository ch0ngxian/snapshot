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
      final rotation = inputRotationFor(_camera.sensorOrientation);
      final input = _toInputImage(image, rotation);
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
      // ML Kit applied the rotation we passed in metadata, so its
      // returned bounding box is already in upright (post-rotation)
      // coordinates. We just need the upright dimensions to normalize.
      final isQuarterTurn = rotation == InputImageRotation.rotation90deg ||
          rotation == InputImageRotation.rotation270deg;
      final orientedWidth =
          (isQuarterTurn ? image.height : image.width).toDouble();
      final orientedHeight =
          (isQuarterTurn ? image.width : image.height).toDouble();
      final normalized = normalizeBox(
        orientedBox: largest.boundingBox,
        orientedWidth: orientedWidth,
        orientedHeight: orientedHeight,
      );
      _controller.add(TrackedFace(
        normalizedBounds: normalized,
        aimLocked: isAimLocked(
          normalized,
          maxOffCenter: _maxOffCenter,
          minFaceHeight: _minFaceHeight,
        ),
      ));
    } catch (e, st) {
      // Failed frame is not the end of the world — log and keep
      // listening. The reticle just won't update from this frame.
      debugPrint('MlKitFaceTracker detection failed: $e\n$st');
    }
  }

  /// Constructs an [InputImage] from a raw camera frame. Format is
  /// platform-specific (NV21 on Android, BGRA on iOS) — both come
  /// through as a single contiguous buffer in [CameraImage.planes[0]].
  /// The [rotation] is the orientation ML Kit should apply *before*
  /// processing so the detector sees an upright face — without it the
  /// detector sees portrait phones sideways and detection accuracy
  /// craters.
  InputImage? _toInputImage(CameraImage image, InputImageRotation rotation) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final InputImageFormat? format = _formatFor(image);
    if (format == null) return null;
    // [size] and [bytesPerRow] describe the *raw* (pre-rotation)
    // buffer; ML Kit rotates internally according to [rotation].
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
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

  /// Maps a sensor orientation in degrees (`0`/`90`/`180`/`270`) to
  /// the [InputImageRotation] enum ML Kit expects. Visible for
  /// testing.
  static InputImageRotation inputRotationFor(int sensorOrientation) {
    switch (sensorOrientation % 360) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      case 0:
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  /// Normalizes ML Kit's upright bounding box against the upright
  /// (post-rotation) image dimensions. Result is in preview-widget
  /// coordinate space — `(0, 0)` top-left, `(1, 1)` bottom-right.
  /// Visible for testing.
  static Rect normalizeBox({
    required Rect orientedBox,
    required double orientedWidth,
    required double orientedHeight,
  }) {
    return Rect.fromLTRB(
      orientedBox.left / orientedWidth,
      orientedBox.top / orientedHeight,
      orientedBox.right / orientedWidth,
      orientedBox.bottom / orientedHeight,
    );
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

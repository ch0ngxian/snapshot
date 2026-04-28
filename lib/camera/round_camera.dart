import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Owns the camera lifecycle for a single round.
///
/// The round screen wants the rear camera live for the full round
/// (GAMEPLAY.md "the camera is the game") — so [RoundScreen] holds onto
/// one of these for its entire lifetime, calls [initialize] once, and
/// drives [pause]/[resume] from `AppLifecycleState`. The shutter path
/// calls [captureFrame] instead of opening the system camera sheet.
///
/// Split out as an abstraction so widget tests don't have to mount a
/// real camera plugin: tests inject [FakeRoundCamera].
abstract class RoundCamera {
  /// Spin up the platform camera. Safe to call once — calling again
  /// after a successful init is a no-op. Resolves when the preview is
  /// ready to render or rejects with [CameraException] / [StateError].
  Future<void> initialize();

  /// `true` once [initialize] has resolved successfully and the
  /// underlying controller is ready to render a preview / capture.
  bool get isInitialized;

  /// Aspect ratio (`width / height`) of the live preview, used by the
  /// screen to pick a correctly-shaped box for `FittedBox(BoxFit.cover)`
  /// so the preview crops cleanly instead of being scaled against an
  /// arbitrary ratio. Returns a sensible portrait default (e.g. `9/16`)
  /// when the camera isn't initialized yet.
  double get previewAspectRatio;

  /// Sensor orientation in degrees (`0`, `90`, `180`, `270`) — the
  /// rotation the platform applies to map raw sensor pixels onto the
  /// upright preview. Live face detection needs this to translate ML
  /// Kit's image-space bounding boxes into the preview's coordinate
  /// space. Returns `0` before [initialize] resolves.
  int get sensorOrientation;

  /// Capture the current frame and return JPEG bytes, or `null` if the
  /// camera isn't ready (e.g. paused, mid-init, disposed). Errors from
  /// the platform layer are rethrown — the caller decides whether to
  /// surface them as a verdict-shaped toast.
  Future<Uint8List?> captureFrame();

  /// Begin delivering preview frames to [onImage] for things like the
  /// live face-detection reticle (GAMEPLAY.md §78). Frames arrive at
  /// the platform's preview rate; consumers are expected to throttle
  /// internally — running ML Kit on every frame is too expensive on
  /// low-end Android (GAMEPLAY.md §164).
  ///
  /// Frames are in the format chosen at controller construction —
  /// `NV21` on Android, `BGRA8888` on iOS — both ML-Kit friendly.
  /// Calling twice without a [stopImageStream] in between is an error
  /// (the camera plugin only supports one consumer).
  Future<void> startImageStream(void Function(CameraImage image) onImage);

  /// Stop delivering preview frames. Idempotent — safe to call when
  /// no stream is active.
  Future<void> stopImageStream();

  /// Release the platform camera (used while the app is backgrounded).
  /// Idempotent — safe to call when already paused / not yet inited.
  Future<void> pause();

  /// Re-acquire the platform camera after a [pause]. Idempotent.
  Future<void> resume();

  /// Tear down everything. After this the instance must not be reused.
  Future<void> dispose();

  /// The widget that renders the live preview. Must return *something*
  /// even when the camera isn't ready yet — the round screen always
  /// stacks the HUD on top of this and a black box is fine as a stand-
  /// in until [initialize] resolves.
  Widget previewWidget(BuildContext context);
}

/// Production [RoundCamera] backed by `package:camera`. Picks the rear
/// camera and a medium preview resolution — high enough that the face
/// detector has something to work with, low enough that low-end Androids
/// don't melt over a 5-minute round (per GAMEPLAY.md "battery / thermal
/// cost").
class PackageCameraRoundCamera implements RoundCamera {
  /// Optional override for [availableCameras]. Real code uses the
  /// package's top-level function; tests of this class can stub it.
  final Future<List<CameraDescription>> Function() _availableCameras;

  /// Optional factory for [CameraController]. Same reasoning as above —
  /// lets tests of this class drive controller behaviour without a real
  /// platform channel.
  final CameraController Function(CameraDescription) _controllerFactory;

  CameraController? _controller;
  CameraDescription? _camera;
  bool _initialized = false;
  bool _disposed = false;
  bool _streaming = false;
  Future<void>? _initFuture;

  PackageCameraRoundCamera({
    Future<List<CameraDescription>> Function()? availableCamerasFn,
    CameraController Function(CameraDescription)? controllerFactory,
  })  : _availableCameras = availableCamerasFn ?? availableCameras,
        _controllerFactory = controllerFactory ?? _defaultController;

  static CameraController _defaultController(CameraDescription camera) {
    // ML-Kit-friendly stream formats: NV21 on Android, BGRA on iOS.
    // The plugin's JPEG group disables `startImageStream`, so we trade
    // the JPEG path for a raw format here — `takePicture()` still
    // returns JPEG regardless of the stream format choice. Other
    // platforms (desktop / web) take whatever the plugin defaults to.
    final ImageFormatGroup format = Platform.isAndroid
        ? ImageFormatGroup.nv21
        : Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.unknown;
    return CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: format,
    );
  }

  @override
  bool get isInitialized => _initialized && !_disposed;

  @override
  double get previewAspectRatio {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      // Portrait fallback while the controller is still spinning up —
      // matches the orientation lock and avoids a one-frame square box
      // that snaps to the real ratio mid-mount.
      return 9 / 16;
    }
    return controller.value.aspectRatio;
  }

  @override
  int get sensorOrientation => _camera?.sensorOrientation ?? 0;

  @override
  Future<void> initialize() {
    if (_disposed) {
      throw StateError('PackageCameraRoundCamera used after dispose().');
    }
    return _initFuture ??= _initOnce();
  }

  Future<void> _initOnce() async {
    final cameras = await _availableCameras();
    if (cameras.isEmpty) {
      throw CameraException(
        'no-camera',
        'No camera is available on this device.',
      );
    }
    final rear = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = _controllerFactory(rear);
    await controller.initialize();
    if (_disposed) {
      // Race: dispose() landed before initialize() resolved. Best-effort
      // tear down what we just built so we don't leak a live camera.
      unawaited(controller.dispose());
      return;
    }
    _controller = controller;
    _camera = rear;
    _initialized = true;
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final controller = _controller;
    if (controller == null || !_initialized || _disposed) return null;
    if (!controller.value.isInitialized) return null;
    if (controller.value.isTakingPicture) return null;
    final XFile shot = await controller.takePicture();
    // takePicture() drops a JPEG into the platform tmp/Documents dir.
    // Over a 5-min round at one shot/sec that's ~hundreds of files left
    // behind — storage bloat AND a privacy footnote since the photo
    // policy says only borderline tags are retained. Read the bytes
    // and delete the file best-effort. Non-fatal if delete fails.
    final file = File(shot.path);
    try {
      return await file.readAsBytes();
    } finally {
      try {
        await file.delete();
      } catch (e, st) {
        debugPrint('PackageCameraRoundCamera capture cleanup failed: $e\n$st');
      }
    }
  }

  @override
  Future<void> startImageStream(
    void Function(CameraImage image) onImage,
  ) async {
    final controller = _controller;
    if (controller == null || !_initialized || _disposed) return;
    if (_streaming) return;
    try {
      await controller.startImageStream(onImage);
      _streaming = true;
    } catch (e, st) {
      debugPrint('PackageCameraRoundCamera.startImageStream failed: $e\n$st');
    }
  }

  @override
  Future<void> stopImageStream() async {
    final controller = _controller;
    if (controller == null || _disposed || !_streaming) return;
    try {
      await controller.stopImageStream();
    } catch (e, st) {
      debugPrint('PackageCameraRoundCamera.stopImageStream failed: $e\n$st');
    } finally {
      _streaming = false;
    }
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    // Drop the image stream first — `pausePreview` doesn't tear it down
    // and on Android it's the stream that pins the camera awake.
    if (_streaming) await stopImageStream();
    try {
      await controller.pausePreview();
    } catch (e, st) {
      debugPrint('PackageCameraRoundCamera.pause failed: $e\n$st');
    }
  }

  @override
  Future<void> resume() async {
    final controller = _controller;
    if (controller == null || _disposed) return;
    try {
      await controller.resumePreview();
    } catch (e, st) {
      debugPrint('PackageCameraRoundCamera.resume failed: $e\n$st');
    }
    // Note: callers (RoundScreen) re-attach the image stream after
    // resume — the tracker re-subscribes through its own start() call.
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    _camera = null;
    _initialized = false;
    if (_streaming) {
      try {
        await controller?.stopImageStream();
      } catch (_) {/* best-effort during teardown */}
      _streaming = false;
    }
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (e, st) {
        debugPrint('PackageCameraRoundCamera.dispose failed: $e\n$st');
      }
    }
  }

  @override
  Widget previewWidget(BuildContext context) {
    final controller = _controller;
    if (controller == null || !_initialized || _disposed) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    if (!controller.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return CameraPreview(controller);
  }
}

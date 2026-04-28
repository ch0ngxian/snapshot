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

  /// Capture the current frame and return JPEG bytes, or `null` if the
  /// camera isn't ready (e.g. paused, mid-init, disposed). Errors from
  /// the platform layer are rethrown — the caller decides whether to
  /// surface them as a verdict-shaped toast.
  Future<Uint8List?> captureFrame();

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
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;

  PackageCameraRoundCamera({
    Future<List<CameraDescription>> Function()? availableCamerasFn,
    CameraController Function(CameraDescription)? controllerFactory,
  })  : _availableCameras = availableCamerasFn ?? availableCameras,
        _controllerFactory = controllerFactory ?? _defaultController;

  static CameraController _defaultController(CameraDescription camera) {
    return CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      // JPEG keeps the path-of-least-change: takePicture() already lands
      // on disk as a JPEG and the embedder pipeline ingests JPEG bytes.
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
  }

  @override
  bool get isInitialized => _initialized && !_disposed;

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
    _initialized = true;
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final controller = _controller;
    if (controller == null || !_initialized || _disposed) return null;
    if (!controller.value.isInitialized) return null;
    if (controller.value.isTakingPicture) return null;
    final XFile shot = await controller.takePicture();
    return File(shot.path).readAsBytes();
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller == null || _disposed) return;
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
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    _initialized = false;
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

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/mlkit_face_tracker.dart';

void main() {
  group('rotateAndNormalizeBox', () {
    // Treat the sensor frame as 1280x720 — typical landscape buffer
    // from a portrait-oriented rear camera on Android. The face sits
    // dead-center in sensor space (640, 360) ± 100x100.
    const double sensorW = 1280;
    const double sensorH = 720;
    const Rect centerBox = Rect.fromLTRB(540, 260, 740, 460);

    test('0° → identity normalization against sensor dimensions', () {
      final r = MlKitFaceTracker.rotateAndNormalizeBox(
        sensorBox: centerBox,
        sensorWidth: sensorW,
        sensorHeight: sensorH,
        sensorOrientation: 0,
      );
      expect(r.left, closeTo(540 / 1280, 1e-9));
      expect(r.right, closeTo(740 / 1280, 1e-9));
      expect(r.top, closeTo(260 / 720, 1e-9));
      expect(r.bottom, closeTo(460 / 720, 1e-9));
    });

    test('90° → preview width = sensorH, preview height = sensorW', () {
      // After a 90° CW rotation a 1280x720 sensor frame becomes a
      // 720x1280 portrait preview. A face centered in sensor space
      // stays centered in preview space — that's the easy invariant
      // to assert against.
      final r = MlKitFaceTracker.rotateAndNormalizeBox(
        sensorBox: centerBox,
        sensorWidth: sensorW,
        sensorHeight: sensorH,
        sensorOrientation: 90,
      );
      expect(r.center.dx, closeTo(0.5, 1e-9));
      expect(r.center.dy, closeTo(0.5, 1e-9));
      // 200px of sensor width becomes 200px of preview height (rotated
      // axis), normalized against sensorW=1280.
      expect(r.height, closeTo(200 / 1280, 1e-9));
      // 200px of sensor height becomes 200px of preview width,
      // normalized against sensorH=720.
      expect(r.width, closeTo(200 / 720, 1e-9));
    });

    test('270° → mirror of 90° (CCW vs CW)', () {
      final r = MlKitFaceTracker.rotateAndNormalizeBox(
        sensorBox: centerBox,
        sensorWidth: sensorW,
        sensorHeight: sensorH,
        sensorOrientation: 270,
      );
      expect(r.center.dx, closeTo(0.5, 1e-9));
      expect(r.center.dy, closeTo(0.5, 1e-9));
      expect(r.height, closeTo(200 / 1280, 1e-9));
      expect(r.width, closeTo(200 / 720, 1e-9));
    });

    test('180° → diagonally opposite point in normalized space', () {
      // Top-left corner of the sensor → bottom-right corner of preview.
      const tl = Rect.fromLTRB(0, 0, 100, 100);
      final r = MlKitFaceTracker.rotateAndNormalizeBox(
        sensorBox: tl,
        sensorWidth: sensorW,
        sensorHeight: sensorH,
        sensorOrientation: 180,
      );
      expect(r.right, closeTo(1.0, 1e-9));
      expect(r.bottom, closeTo(1.0, 1e-9));
      expect(r.left, closeTo(1.0 - 100 / 1280, 1e-9));
      expect(r.top, closeTo(1.0 - 100 / 720, 1e-9));
    });

    test('off-center sensor box rotates as expected at 90°', () {
      // Top-left of sensor (away from center) — under a 90° CW
      // rotation a corner near the top-left of sensor space ends up
      // near the top-right of preview space.
      const tl = Rect.fromLTRB(0, 0, 100, 100);
      final r = MlKitFaceTracker.rotateAndNormalizeBox(
        sensorBox: tl,
        sensorWidth: sensorW,
        sensorHeight: sensorH,
        sensorOrientation: 90,
      );
      // After 90° CW: sensor top-left → preview top-right.
      expect(r.right, closeTo(1.0, 1e-9));
      expect(r.top, closeTo(0.0, 1e-9));
    });
  });

  group('isAimLocked', () {
    const maxOff = 0.18;
    const minH = 0.22;

    test('centered + tall → locked', () {
      const box = Rect.fromLTRB(0.4, 0.35, 0.6, 0.65);
      expect(
        MlKitFaceTracker.isAimLocked(box,
            maxOffCenter: maxOff, minFaceHeight: minH),
        isTrue,
      );
    });

    test('off-center → not locked', () {
      const box = Rect.fromLTRB(0.05, 0.1, 0.25, 0.4);
      expect(
        MlKitFaceTracker.isAimLocked(box,
            maxOffCenter: maxOff, minFaceHeight: minH),
        isFalse,
      );
    });

    test('too small (far away) → not locked', () {
      const box = Rect.fromLTRB(0.45, 0.45, 0.55, 0.55);
      expect(
        MlKitFaceTracker.isAimLocked(box,
            maxOffCenter: maxOff, minFaceHeight: minH),
        isFalse,
      );
    });
  });
}

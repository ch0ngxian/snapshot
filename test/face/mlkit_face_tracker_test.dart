import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    show InputImageRotation;
import 'package:snapshot/face/mlkit_face_tracker.dart';

void main() {
  group('inputRotationFor', () {
    test('maps 0/90/180/270 to the matching ML Kit enum', () {
      expect(MlKitFaceTracker.inputRotationFor(0),
          InputImageRotation.rotation0deg);
      expect(MlKitFaceTracker.inputRotationFor(90),
          InputImageRotation.rotation90deg);
      expect(MlKitFaceTracker.inputRotationFor(180),
          InputImageRotation.rotation180deg);
      expect(MlKitFaceTracker.inputRotationFor(270),
          InputImageRotation.rotation270deg);
    });

    test('treats out-of-range values as their mod-360 equivalent', () {
      expect(MlKitFaceTracker.inputRotationFor(360),
          InputImageRotation.rotation0deg);
      expect(MlKitFaceTracker.inputRotationFor(450),
          InputImageRotation.rotation90deg);
    });
  });

  group('normalizeBox', () {
    test('normalizes ML Kit upright box against post-rotation dims', () {
      // 1280x720 sensor frame, sensor orientation 90° → ML Kit detects
      // on a 720x1280 upright frame and returns the box in that frame.
      final box = Rect.fromLTRB(310, 540, 410, 740);
      final r = MlKitFaceTracker.normalizeBox(
        orientedBox: box,
        orientedWidth: 720,
        orientedHeight: 1280,
      );
      expect(r.left, closeTo(310 / 720, 1e-9));
      expect(r.top, closeTo(540 / 1280, 1e-9));
      expect(r.right, closeTo(410 / 720, 1e-9));
      expect(r.bottom, closeTo(740 / 1280, 1e-9));
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

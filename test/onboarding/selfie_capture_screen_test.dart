import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/no_face_detected_exception.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';
import 'package:snapshot/onboarding/selfie_capture_screen.dart';

void main() {
  group('SelfieCaptureScreen', () {
    final fakeBytes = Uint8List.fromList(List.generate(64, (i) => i));

    testWidgets('runs the embedder on the captured photo and forwards the result',
        (tester) async {
      SelfieResult? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: SelfieCaptureScreen(
            embedder: const FakeFaceEmbedder(),
            onCaptured: (r) => captured = r,
            pickerOverride: () async => fakeBytes,
          ),
        ),
      );

      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.embedding.length, 128);
      expect(captured!.modelVersion, 'fake-v1');
      expect(captured!.jpegBytes, equals(fakeBytes));
    });

    testWidgets('surfaces a friendly error when no face is detected',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SelfieCaptureScreen(
            embedder: const FakeFaceEmbedder(
              throwOnEmbed: NoFaceDetectedException(),
            ),
            onCaptured: (_) {},
            pickerOverride: () async => fakeBytes,
          ),
        ),
      );

      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      expect(find.textContaining("couldn't see a face"), findsOneWidget);
    });

    testWidgets('cancelled picker leaves UI ready for another attempt',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SelfieCaptureScreen(
            embedder: const FakeFaceEmbedder(),
            onCaptured: (_) {},
            pickerOverride: () async => null,
          ),
        ),
      );

      await tester.tap(find.text('Open camera'));
      await tester.pumpAndSettle();

      expect(find.text('Open camera'), findsOneWidget);
    });
  });
}

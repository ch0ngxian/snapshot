import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../face/face_embedder.dart';
import '../face/no_face_detected_exception.dart';

/// Onboarding step 2: take a selfie via the system camera, then run it
/// through the on-device [FaceEmbedder] (per §5.7) to produce the embedding
/// stored on the user profile.
class SelfieCaptureScreen extends StatefulWidget {
  final FaceEmbedder embedder;
  final ValueChanged<SelfieResult> onCaptured;

  /// Override the picker for tests (returns image bytes or null on cancel).
  /// Production path goes through [ImagePicker] + `File.readAsBytes`.
  @visibleForTesting
  final Future<Uint8List?> Function()? pickerOverride;

  const SelfieCaptureScreen({
    super.key,
    required this.embedder,
    required this.onCaptured,
    this.pickerOverride,
  });

  @override
  State<SelfieCaptureScreen> createState() => _SelfieCaptureScreenState();
}

class SelfieResult {
  final Uint8List jpegBytes;
  final Float32List embedding;
  final String modelVersion;

  const SelfieResult({
    required this.jpegBytes,
    required this.embedding,
    required this.modelVersion,
  });
}

class _SelfieCaptureScreenState extends State<SelfieCaptureScreen> {
  bool _processing = false;
  String? _error;

  Future<void> _capture() async {
    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final bytes = await (widget.pickerOverride ?? _defaultPicker)();
      if (bytes == null) {
        setState(() => _processing = false);
        return;
      }
      final embedding = await widget.embedder.embed(bytes);
      if (!mounted) return;
      setState(() => _processing = false);
      widget.onCaptured(
        SelfieResult(
          jpegBytes: bytes,
          embedding: embedding,
          modelVersion: widget.embedder.modelVersion,
        ),
      );
    } on NoFaceDetectedException {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = "We couldn't see a face. Try again with good lighting.";
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Something went wrong: $err';
      });
    }
  }

  Future<Uint8List?> _defaultPicker() async {
    // Cap to 1280×1280 — face detection + a 112×112 MobileFaceNet crop
    // don't benefit from 18MP, and the Dart-side decode/bake/encode pass in
    // the embedder dominates pipeline latency on full-res inputs (§314).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (picked == null) return null;
    return File(picked.path).readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Selfie')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Take a clear photo of your face. We'll use a numeric "
              "summary of it so other players' photos can find you.",
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _processing ? null : _capture,
              icon: const Icon(Icons.camera_alt),
              label: Text(_processing ? 'Processing…' : 'Open camera'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

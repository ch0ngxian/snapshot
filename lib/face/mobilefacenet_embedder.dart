import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_embedder.dart';
import 'no_face_detected_exception.dart';

/// Production [FaceEmbedder]: ML Kit Face Detection picks the largest face,
/// crops it (with a small margin), resizes to 112×112, and feeds it through a
/// MobileFaceNet TFLite interpreter to produce a 128-dim L2-normalized
/// embedding.
///
/// Construct via [create] — the default constructor is private so callers
/// can't bypass the async initialization of the interpreter and detector.
class MobileFaceNetEmbedder implements FaceEmbedder {
  static const _modelAssetPath = 'assets/models/mobilefacenet.tflite';
  static const _inputSize = 112;
  static const _embeddingDim = 128;
  static const _cropMarginRatio = 0.10;

  final Interpreter _interpreter;
  final FaceDetector _detector;
  bool _closed = false;

  @override
  final String modelVersion;

  MobileFaceNetEmbedder._(this._interpreter, this._detector, this.modelVersion);

  /// Loads the model from assets and initializes ML Kit.
  ///
  /// [modelVersion] is the stamp recorded with every embedding. The default
  /// matches the v1 lock in tech-plan.md §5.7; pass `mobilefacenet-v1-q` if
  /// shipping the quantized variant after the latency gate.
  static Future<MobileFaceNetEmbedder> create({
    String modelVersion = 'mobilefacenet-v1',
  }) async {
    final interpreter = await Interpreter.fromAsset(_modelAssetPath);
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableContours: false,
        enableLandmarks: false,
        enableClassification: false,
        enableTracking: false,
      ),
    );
    return MobileFaceNetEmbedder._(interpreter, detector, modelVersion);
  }

  @override
  int get embeddingDim => _embeddingDim;

  @override
  Future<Float32List> embed(Uint8List imageBytes) async {
    // image_picker's camera path on iOS writes JPEGs with raw camera-orientation
    // pixels and an EXIF orientation tag. ML Kit doesn't always honor the tag,
    // and `img.decodeImage` never does — so detection silently fails on
    // portrait selfies, or succeeds with a bounding box that doesn't line up
    // with our crop. Bake orientation once up front and feed the same upright
    // pixels to both stages.
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError('could not decode image bytes');
    }
    final upright = img.bakeOrientation(decoded);
    final uprightJpeg = Uint8List.fromList(img.encodeJpg(upright));

    final face = await _detectLargestFace(uprightJpeg);

    final resized = _cropAndResize(upright, face.boundingBox);
    final input = _toNHWCFloat32(resized);

    final output = List.generate(
      1,
      (_) => List<double>.filled(_embeddingDim, 0.0),
    );
    _interpreter.run(
      input.reshape([1, _inputSize, _inputSize, 3]),
      output,
    );

    return _l2Normalize(Float32List.fromList(output[0]));
  }

  Future<Face> _detectLargestFace(Uint8List imageBytes) async {
    // ML Kit's InputImage requires a file path on most platforms.
    final tempFile = await File(
      '${Directory.systemTemp.path}/snapshot_embed_'
      '${DateTime.now().microsecondsSinceEpoch}.jpg',
    ).writeAsBytes(imageBytes, flush: true);
    try {
      final faces = await _detector.processImage(
        InputImage.fromFilePath(tempFile.path),
      );
      if (faces.isEmpty) {
        throw const NoFaceDetectedException();
      }
      return faces.reduce((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaA >= areaB ? a : b;
      });
    } finally {
      unawaited(tempFile.delete().catchError((_) => tempFile));
    }
  }

  img.Image _cropAndResize(img.Image source, Rect box) {
    final marginX = (box.width * _cropMarginRatio).toInt();
    final marginY = (box.height * _cropMarginRatio).toInt();
    final left = (box.left.toInt() - marginX).clamp(0, source.width - 1);
    final top = (box.top.toInt() - marginY).clamp(0, source.height - 1);
    final right = (box.right.toInt() + marginX).clamp(left + 1, source.width);
    final bottom = (box.bottom.toInt() + marginY).clamp(top + 1, source.height);
    final cropped = img.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    return img.copyResize(cropped, width: _inputSize, height: _inputSize);
  }

  Float32List _toNHWCFloat32(img.Image resized) {
    final out = Float32List(_inputSize * _inputSize * 3);
    var i = 0;
    for (var y = 0; y < _inputSize; y++) {
      for (var x = 0; x < _inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        out[i++] = (pixel.r - 127.5) / 127.5;
        out[i++] = (pixel.g - 127.5) / 127.5;
        out[i++] = (pixel.b - 127.5) / 127.5;
      }
    }
    return out;
  }

  static Float32List _l2Normalize(Float32List v) {
    double sumSq = 0;
    for (final x in v) {
      sumSq += x * x;
    }
    final norm = math.sqrt(sumSq);
    if (norm == 0) return v;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _interpreter.close();
    await _detector.close();
  }
}

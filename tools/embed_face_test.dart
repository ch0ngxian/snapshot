import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

const _inputSize = 112;
const _embeddingDim = 128;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('embed face tool', () async {
    final imagePath = _requireEnv('SNAPSHOT_EMBED_FACE_IMAGE');
    final outputPath = _requireEnv('SNAPSHOT_EMBED_FACE_OUT');
    final modelPath = Platform.environment['SNAPSHOT_EMBED_FACE_MODEL'] ??
        'assets/models/mobilefacenet.tflite';
    final modelVersion =
        Platform.environment['SNAPSHOT_EMBED_FACE_MODEL_VERSION'] ??
            'mobilefacenet-v1';
    final crop = Platform.environment['SNAPSHOT_EMBED_FACE_CROP'];

    final imageFile = File(imagePath);
    expect(await imageFile.exists(), isTrue,
        reason: 'image file does not exist: $imagePath');

    final modelFile = File(modelPath);
    expect(await modelFile.exists(), isTrue,
        reason: 'model file does not exist: $modelPath');

    final decoded = img.decodeImage(await imageFile.readAsBytes());
    expect(decoded, isNotNull, reason: 'could not decode image: $imagePath');

    final upright = img.bakeOrientation(decoded!);
    final rect = crop == null
        ? _centerSquareCrop(upright.width, upright.height)
        : CropRect.parse(crop);
    _validateCrop(rect, upright.width, upright.height);

    final cropped = img.copyCrop(
      upright,
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    );
    final resized = img.copyResize(
      cropped,
      width: _inputSize,
      height: _inputSize,
    );

    final interpreter = Interpreter.fromFile(modelFile);
    try {
      final input = _toNHWCFloat32(resized);
      final output = List.generate(
        1,
        (_) => List<double>.filled(_embeddingDim, 0.0),
      );
      interpreter.run(
        input.reshape([1, _inputSize, _inputSize, 3]),
        output,
      );

      final embedding = _l2Normalize(Float32List.fromList(output[0]));
      expect(embedding, hasLength(_embeddingDim));

      final result = <String, Object?>{
        'imagePath': imageFile.absolute.path,
        'crop': <String, int>{
          'left': rect.left,
          'top': rect.top,
          'width': rect.width,
          'height': rect.height,
        },
        'modelPath': modelFile.absolute.path,
        'modelVersion': modelVersion,
        'embedding': List<double>.generate(
          embedding.length,
          (i) => embedding[i].toDouble(),
        ),
      };
      await File(outputPath).writeAsString(jsonEncode(result));
    } finally {
      interpreter.close();
    }
  });
}

String _requireEnv(String key) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) {
    throw ArgumentError('missing required environment variable $key');
  }
  return value;
}

CropRect _centerSquareCrop(int width, int height) {
  final side = math.min(width, height);
  final left = ((width - side) / 2).floor();
  final top = ((height - side) / 2).floor();
  return CropRect(left: left, top: top, width: side, height: side);
}

void _validateCrop(CropRect crop, int imageWidth, int imageHeight) {
  if (crop.left < 0 || crop.top < 0 || crop.width <= 0 || crop.height <= 0) {
    throw ArgumentError('crop must have non-negative origin and positive size');
  }
  if (crop.left + crop.width > imageWidth ||
      crop.top + crop.height > imageHeight) {
    throw ArgumentError(
      'crop $crop is outside image bounds ${imageWidth}x$imageHeight',
    );
  }
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

Float32List _l2Normalize(Float32List vector) {
  double sumSq = 0;
  for (final value in vector) {
    sumSq += value * value;
  }
  final norm = math.sqrt(sumSq);
  if (norm == 0) return vector;

  final out = Float32List(vector.length);
  for (var i = 0; i < vector.length; i++) {
    out[i] = vector[i] / norm;
  }
  return out;
}

class CropRect {
  const CropRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory CropRect.parse(String raw) {
    final parts = raw.split(',');
    if (parts.length != 4) {
      throw ArgumentError('SNAPSHOT_EMBED_FACE_CROP must be left,top,width,height');
    }
    final values = parts.map(int.parse).toList(growable: false);
    return CropRect(
      left: values[0],
      top: values[1],
      width: values[2],
      height: values[3],
    );
  }

  final int left;
  final int top;
  final int width;
  final int height;

  @override
  String toString() => '$left,$top,$width,$height';
}

import 'dart:math' as math;
import 'dart:typed_data';

import '../face_embedder.dart';

/// Test-only fake [FaceEmbedder] that returns a deterministic L2-normalized
/// embedding derived from the input bytes. Same bytes in ⇒ same vector out;
/// different bytes ⇒ different vectors. Used by tests in this and downstream
/// PRs to stand in for [MobileFaceNetEmbedder] without needing platform
/// channels or the model file.
///
/// Not for production use.
class FakeFaceEmbedder implements FaceEmbedder {
  @override
  String get modelVersion => 'fake-v1';

  @override
  int get embeddingDim => 192;

  /// If non-null, [embed] throws this instead of returning a vector — handy
  /// for testing error paths (e.g. `NoFaceDetectedException`).
  final Object? throwOnEmbed;

  const FakeFaceEmbedder({this.throwOnEmbed});

  @override
  Future<Float32List> embed(Uint8List imageBytes) async {
    if (throwOnEmbed != null) {
      throw throwOnEmbed!;
    }
    if (imageBytes.isEmpty) {
      throw ArgumentError('empty image bytes');
    }

    var seed = 0;
    for (final b in imageBytes) {
      seed = (seed * 31 + b) & 0xFFFFFFFF;
    }
    if (seed == 0) seed = 1;

    final out = Float32List(embeddingDim);
    for (var i = 0; i < embeddingDim; i++) {
      out[i] = math.sin(seed * (i + 1) * 0.001);
    }

    double sumSq = 0;
    for (final x in out) {
      sumSq += x * x;
    }
    final norm = math.sqrt(sumSq);
    for (var i = 0; i < out.length; i++) {
      out[i] /= norm;
    }
    return out;
  }

  @override
  Future<void> close() async {}
}

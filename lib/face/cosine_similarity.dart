import 'dart:math' as math;
import 'dart:typed_data';

/// Cosine similarity between two equal-length embedding vectors.
///
/// Returned values lie in [-1, 1]. Embeddings produced by [FaceEmbedder]
/// implementations are L2-normalized, so for those inputs this reduces to a
/// dot product — but we don't assume normalization here.
///
/// Throws [ArgumentError] if lengths mismatch, either input is empty, or
/// either input has zero norm.
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length) {
    throw ArgumentError(
      'embedding lengths must match: ${a.length} vs ${b.length}',
    );
  }
  if (a.isEmpty) {
    throw ArgumentError('embeddings must not be empty');
  }
  double dot = 0;
  double sumSqA = 0;
  double sumSqB = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    sumSqA += a[i] * a[i];
    sumSqB += b[i] * b[i];
  }
  final denom = math.sqrt(sumSqA) * math.sqrt(sumSqB);
  if (denom == 0) {
    throw ArgumentError('zero-norm embedding');
  }
  return dot / denom;
}

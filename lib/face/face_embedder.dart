import 'dart:typed_data';

/// Interface for any model that turns an image of a face into a fixed-length
/// numeric embedding. Per tech-plan.md §5.2, the active implementation is
/// injected at app startup and stamped onto every stored embedding via
/// [modelVersion] so the server can refuse to compare across mismatched
/// versions.
abstract class FaceEmbedder {
  /// Identifier recorded with every embedding. Bumping the model means bumping
  /// this string; the server-side cosine comparison refuses to mix versions.
  String get modelVersion;

  /// Length of the output vector.
  int get embeddingDim;

  /// Extracts a face embedding from raw image bytes (JPEG/PNG).
  ///
  /// Per §5.7, the implementation runs ML Kit Face Detection first and
  /// short-circuits with [NoFaceDetectedException] when no face is found —
  /// the caller should treat this as a local "no match" without calling
  /// `submitTag`.
  ///
  /// Returns an L2-normalized [Float32List] of length [embeddingDim] suitable
  /// for cosine-similarity comparison.
  Future<Float32List> embed(Uint8List imageBytes);

  /// Releases native resources (TFLite interpreter, ML Kit detector).
  /// Safe to call multiple times.
  Future<void> close();
}

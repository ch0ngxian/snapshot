/// Thrown by [FaceEmbedder.embed] when ML Kit Face Detection finds no face in
/// the input image. Per tech-plan.md §5.7 the client treats this as a local
/// "no match" without calling the server's `submitTag` Function.
class NoFaceDetectedException implements Exception {
  final String message;
  const NoFaceDetectedException([this.message = 'No face detected in image']);

  @override
  String toString() => 'NoFaceDetectedException: $message';
}

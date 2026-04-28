import 'dart:ui' show Rect;

/// A face detected in the round's live preview, with its bounding box
/// pre-mapped into the *preview widget's* coordinate space — i.e. the
/// orientation rotation has already been applied, and the rect is
/// expressed as fractions of the preview area `[0, 1]^2`.
///
/// Mapping to widget pixels is then a single multiply by the rendered
/// preview size, which is what the reticle widget does. Doing the
/// rotation/normalization inside the tracker keeps the widget layer
/// dumb — it doesn't have to know whether the camera sensor is
/// landscape, what the device orientation is, or how `BoxFit.cover`
/// scales the underlying preview.
class TrackedFace {
  /// Bounding box of the (largest) detected face, normalized so that
  /// `(0, 0)` is the top-left of the preview and `(1, 1)` is the
  /// bottom-right. Values may sit just outside `[0, 1]` when the face
  /// straddles a preview edge — callers that care should clamp or
  /// clip.
  final Rect normalizedBounds;

  /// Aim-assist signal (GAMEPLAY.md §78): `true` when the face is
  /// roughly centered AND large enough that a tag is likely to match.
  /// The reticle goes green when this flips on. Deliberately *doesn't*
  /// reveal *who* the face is — only that some face is well-framed.
  final bool aimLocked;

  const TrackedFace({
    required this.normalizedBounds,
    required this.aimLocked,
  });
}

/// Streams [TrackedFace] events while a round is live. The round screen
/// listens to [faces] to drive the reticle overlay; emitting `null`
/// means "no face is currently tracked" so the reticle hides.
///
/// Implementations are expected to throttle internally — ML Kit on
/// every preview frame is too expensive on low-end Android, per
/// GAMEPLAY.md §164.
abstract class FaceTracker {
  /// Start consuming preview frames. Called once after the round
  /// camera is initialized; safe to call again after [stop].
  Future<void> start();

  /// Stop consuming preview frames. Idempotent.
  Future<void> stop();

  /// Tear down. After this the tracker must not be reused.
  Future<void> dispose();

  /// Latest detection state. Emits `null` to clear the reticle when no
  /// face is detected. The stream is broadcast so the widget can
  /// subscribe and resubscribe without losing earlier subscriptions.
  Stream<TrackedFace?> get faces;
}

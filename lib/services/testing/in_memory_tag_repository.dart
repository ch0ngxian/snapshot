import 'dart:typed_data';

import '../tag_repository.dart';

/// Test-only in-memory [TagRepository]. Records every submitTag and photo
/// upload so widget tests can assert call shape without touching Firebase.
class InMemoryTagRepository implements TagRepository {
  /// Pre-canned verdicts the next [submitTag] call(s) should return.
  /// Drained FIFO; if empty, [submitTag] throws so a missing stub is
  /// loud rather than silent.
  final List<TagSubmission> Function(SubmittedTagCall) _verdictFor;

  final List<SubmittedTagCall> submissions = [];
  final List<UploadedPhotoCall> uploads = [];

  /// If non-null, [submitTag] throws this and never records the call —
  /// useful for testing the network-error path.
  Object? throwOnSubmit;

  /// If non-null, [uploadTagPhoto] throws this — useful for testing the
  /// "fire-and-forget photo upload swallowed an error" path.
  Object? throwOnUpload;

  InMemoryTagRepository.fromQueue(List<TagSubmission> verdicts)
      : _verdictFor = _drainQueue(verdicts);

  InMemoryTagRepository.always(TagSubmission verdict)
      : _verdictFor = ((_) => [verdict]);

  static List<TagSubmission> Function(SubmittedTagCall) _drainQueue(
    List<TagSubmission> q,
  ) {
    final remaining = List<TagSubmission>.from(q);
    return (_) {
      if (remaining.isEmpty) {
        throw StateError(
          'InMemoryTagRepository: no more pre-canned verdicts to return',
        );
      }
      return [remaining.removeAt(0)];
    };
  }

  @override
  Future<TagSubmission> submitTag({
    required String lobbyId,
    required String tagId,
    required Float32List embedding,
    required String modelVersion,
  }) async {
    if (throwOnSubmit != null) throw throwOnSubmit!;
    final call = SubmittedTagCall(
      lobbyId: lobbyId,
      tagId: tagId,
      modelVersion: modelVersion,
      embeddingLength: embedding.length,
    );
    submissions.add(call);
    final verdicts = _verdictFor(call);
    final v = verdicts.first;
    // Replace tagId so the caller's id round-trips even when the test
    // pre-canned a verdict with a placeholder id.
    return TagSubmission(
      result: v.result,
      retainPhoto: v.retainPhoto,
      tagId: tagId,
      victimLivesRemaining: v.victimLivesRemaining,
      eliminated: v.eliminated,
    );
  }

  @override
  Future<void> uploadTagPhoto({
    required String lobbyId,
    required String tagId,
    required Uint8List jpegBytes,
  }) async {
    if (throwOnUpload != null) throw throwOnUpload!;
    uploads.add(
      UploadedPhotoCall(lobbyId: lobbyId, tagId: tagId, byteLength: jpegBytes.length),
    );
  }
}

class SubmittedTagCall {
  final String lobbyId;
  final String tagId;
  final String modelVersion;
  final int embeddingLength;
  SubmittedTagCall({
    required this.lobbyId,
    required this.tagId,
    required this.modelVersion,
    required this.embeddingLength,
  });
}

class UploadedPhotoCall {
  final String lobbyId;
  final String tagId;
  final int byteLength;
  UploadedPhotoCall({
    required this.lobbyId,
    required this.tagId,
    required this.byteLength,
  });
}

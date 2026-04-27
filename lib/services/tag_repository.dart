import 'dart:typed_data';

/// Reads + writes tag state. Like the lobby flow, all writes go through a
/// Cloud Function (`submitTag` — tech-plan §326) so the verdict stays
/// server-authoritative; the photo upload to Cloud Storage is conditional
/// on the server's verdict and gated by storage.rules.
abstract class TagRepository {
  /// Calls the `submitTag` callable. The caller generates [tagId]
  /// client-side (it doubles as the idempotency key — replays from a
  /// dropped network return the original verdict instead of re-running
  /// the comparison).
  Future<TagSubmission> submitTag({
    required String lobbyId,
    required String tagId,
    required Float32List embedding,
    required String modelVersion,
  });

  /// Uploads the captured image bytes to `tags/{lobbyId}/{tagId}.jpg`.
  /// Only call this when [TagSubmission.retainPhoto] was true on the
  /// matching submitTag — Storage rules reject the create otherwise.
  Future<void> uploadTagPhoto({
    required String lobbyId,
    required String tagId,
    required Uint8List jpegBytes,
  });
}

/// Server verdict from `submitTag`. Mirrors `SubmitTagResult` in
/// functions/src/submitTag.ts. Field order/naming kept aligned so a
/// schema drift surfaces as a parse failure in tests.
class TagSubmission {
  final TagResult result;

  /// True iff the top match's similarity sat in the borderline band
  /// `|topSim - threshold| < halfWidth` per §5.9. The client uploads the
  /// photo iff this is set.
  final bool retainPhoto;

  /// Echoed back so the client doesn't have to remember which tagId it
  /// sent — useful for the photo-upload step.
  final String tagId;

  /// Only populated on a `hit` verdict. Drives the toast copy.
  final int? victimLivesRemaining;

  /// Only populated on a `hit` verdict. Indicates the tagged player's
  /// lives just hit zero.
  final bool? eliminated;

  const TagSubmission({
    required this.result,
    required this.retainPhoto,
    required this.tagId,
    this.victimLivesRemaining,
    this.eliminated,
  });
}

enum TagResult {
  /// Cosine similarity ≥ threshold AND target wasn't immune AND tagger
  /// wasn't on cooldown — life was decremented.
  hit,

  /// No opponent cleared the threshold, OR no faces in the captured
  /// frame (client short-circuit before calling submitTag).
  noMatch,

  /// Top match was tagged within the past `rules.immunitySeconds`.
  immune,

  /// Tagger spammed the shutter — under the 5s cooldown.
  cooldown,
}

TagResult tagResultFromString(String raw) {
  switch (raw) {
    case 'hit':
      return TagResult.hit;
    case 'no_match':
      return TagResult.noMatch;
    case 'immune':
      return TagResult.immune;
    case 'cooldown':
      return TagResult.cooldown;
    default:
      throw ArgumentError('unknown submitTag result: $raw');
  }
}

import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'tag_repository.dart';

/// Production [TagRepository] backed by the `submitTag` Cloud Function
/// (region per tech-plan §5.4) and Firebase Storage for the conditional
/// photo upload (§5.9). The Function is the only path that writes tag
/// docs; the client is restricted to creating the photo blob — and even
/// that is gated by Storage rules to the borderline-band case.
class FirestoreTagRepository implements TagRepository {
  static const String _region = 'asia-southeast1';

  final FirebaseFunctions _functions;
  final FirebaseStorage _storage;

  FirestoreTagRepository({
    FirebaseFunctions? functions,
    FirebaseStorage? storage,
  })  : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: _region),
        _storage = storage ?? FirebaseStorage.instance;

  @override
  Future<TagSubmission> submitTag({
    required String lobbyId,
    required String tagId,
    required Float32List embedding,
    required String modelVersion,
  }) async {
    final result = await _functions.httpsCallable('submitTag').call(
      <String, dynamic>{
        'lobbyId': lobbyId,
        'tagId': tagId,
        // Wire format is List<double> — Float32List doesn't survive the
        // JSON encode that callable functions does for the request body.
        'embedding': List<double>.generate(
          embedding.length,
          (i) => embedding[i].toDouble(),
        ),
        'modelVersion': modelVersion,
      },
    );
    final data = Map<String, dynamic>.from(result.data as Map);
    return TagSubmission(
      result: tagResultFromString(data['result'] as String),
      retainPhoto: data['retainPhoto'] as bool? ?? false,
      tagId: data['tagId'] as String? ?? tagId,
      victimLivesRemaining: (data['victimLivesRemaining'] as num?)?.toInt(),
      eliminated: data['eliminated'] as bool?,
    );
  }

  @override
  Future<void> uploadTagPhoto({
    required String lobbyId,
    required String tagId,
    required Uint8List jpegBytes,
  }) async {
    // Storage rules enforce the prefix + filename charset; matches the
    // tagId charset we generate client-side.
    final ref = _storage.ref('tags/$lobbyId/$tagId.jpg');
    await ref.putData(
      jpegBytes,
      SettableMetadata(contentType: 'image/jpeg'),
    );
  }
}

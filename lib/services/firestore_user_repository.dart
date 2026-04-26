import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import 'user_repository.dart';

/// Production [UserRepository] backed by Firestore at `users/{uid}`. Schema
/// matches tech-plan.md §3 and the validation in `firestore.rules`
/// (`isValidUserProfile`):
///   displayName (string), faceEmbedding (Firestore array of doubles, length
///   192), embeddingModelVersion (string), createdAt (Timestamp).
class FirestoreUserRepository implements UserRepository {
  static const String _collection = 'users';

  final FirebaseFirestore _db;

  FirestoreUserRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection(_collection);

  @override
  Future<UserProfile?> get(String uid) async {
    final snap = await _users.doc(uid).get();
    if (!snap.exists) return null;
    final data = snap.data()!;
    try {
      return UserProfile(
        uid: uid,
        displayName: data['displayName'] as String,
        faceEmbedding: _decodeEmbedding(data['faceEmbedding'] as List<dynamic>),
        embeddingModelVersion: data['embeddingModelVersion'] as String,
        createdAt: (data['createdAt'] as Timestamp).toDate(),
      );
    } on TypeError catch (e) {
      // Reachable if firestore.rules drift, an Admin-SDK write bypassed the
      // schema check, or the doc was edited manually in the console.
      throw StateError('users/$uid has unexpected schema: $e');
    }
  }

  @override
  Future<void> save(UserProfile profile) async {
    await _users.doc(profile.uid).set({
      'displayName': profile.displayName,
      'faceEmbedding': profile.faceEmbedding.toList(),
      'embeddingModelVersion': profile.embeddingModelVersion,
      'createdAt': Timestamp.fromDate(profile.createdAt),
    });
  }

  static Float32List _decodeEmbedding(List<dynamic> raw) {
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = (raw[i] as num).toDouble();
    }
    return out;
  }
}

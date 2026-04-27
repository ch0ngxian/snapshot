import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/lobby.dart';
import '../models/lobby_player.dart';
import 'embedding_codec.dart';
import 'lobby_repository.dart';

/// Production [LobbyRepository] backed by Firestore + the `createLobby` /
/// `joinLobby` callable Cloud Functions (region per tech-plan §5.4).
///
/// All writes are routed through the callables so the schema (and the
/// 6-char-code namespace) stays server-authoritative; the client only
/// streams reads.
class FirestoreLobbyRepository implements LobbyRepository {
  static const String _collection = 'lobbies';
  static const String _region = 'asia-southeast1';

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  FirestoreLobbyRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: _region);

  CollectionReference<Map<String, dynamic>> get _lobbies =>
      _db.collection(_collection);

  @override
  Future<CreatedLobby> createLobby() async {
    final result = await _functions.httpsCallable('createLobby').call();
    final data = Map<String, dynamic>.from(result.data as Map);
    return CreatedLobby(
      lobbyId: data['lobbyId'] as String,
      code: data['code'] as String,
    );
  }

  @override
  Future<String> joinLobby(String code) async {
    try {
      final result = await _functions
          .httpsCallable('joinLobby')
          .call(<String, dynamic>{'code': code});
      final data = Map<String, dynamic>.from(result.data as Map);
      return data['lobbyId'] as String;
    } on FirebaseFunctionsException catch (e) {
      switch (e.code) {
        case 'not-found':
          throw LobbyNotFoundException(code);
        case 'resource-exhausted':
          throw LobbyFullException();
        default:
          rethrow;
      }
    }
  }

  @override
  Future<void> startRound(String lobbyId, LobbyRules rules) async {
    await _functions.httpsCallable('startRound').call(<String, dynamic>{
      'lobbyId': lobbyId,
      'rules': <String, dynamic>{
        'startingLives': rules.startingLives,
        'durationSeconds': rules.durationSeconds,
        'immunitySeconds': rules.immunitySeconds,
      },
    });
  }

  @override
  Future<void> endRound(String lobbyId) async {
    await _functions
        .httpsCallable('endRound')
        .call(<String, dynamic>{'lobbyId': lobbyId});
  }

  @override
  Stream<Lobby?> watchLobby(String lobbyId) {
    return _lobbies.doc(lobbyId).snapshots().map((snap) {
      if (!snap.exists) return null;
      return _parseLobby(snap.id, snap.data()!);
    });
  }

  @override
  Stream<List<LobbyPlayer>> watchPlayers(String lobbyId) {
    return _lobbies
        .doc(lobbyId)
        .collection('players')
        .orderBy('joinedAt')
        .snapshots()
        .map((snap) => snap.docs.map((d) => _parsePlayer(d.id, d.data())).toList());
  }

  static Lobby _parseLobby(String lobbyId, Map<String, dynamic> data) {
    final rules = Map<String, dynamic>.from(data['rules'] as Map? ?? const {});
    return Lobby(
      lobbyId: lobbyId,
      code: data['code'] as String,
      hostUid: data['hostUid'] as String,
      status: lobbyStatusFromString(data['status'] as String),
      rules: LobbyRules(
        startingLives:
            (rules['startingLives'] as num?)?.toInt() ?? LobbyRules.defaults.startingLives,
        durationSeconds:
            (rules['durationSeconds'] as num?)?.toInt() ?? LobbyRules.defaults.durationSeconds,
        immunitySeconds:
            (rules['immunitySeconds'] as num?)?.toInt() ?? LobbyRules.defaults.immunitySeconds,
      ),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      startedAt: (data['startedAt'] as Timestamp?)?.toDate(),
      endedAt: (data['endedAt'] as Timestamp?)?.toDate(),
    );
  }

  static LobbyPlayer _parsePlayer(String uid, Map<String, dynamic> data) {
    return LobbyPlayer(
      uid: uid,
      displayName: data['displayName'] as String,
      livesRemaining: (data['livesRemaining'] as num).toInt(),
      status: lobbyPlayerStatusFromString(data['status'] as String),
      joinedAt: (data['joinedAt'] as Timestamp).toDate(),
      embeddingSnapshot:
          decodeEmbedding((data['embeddingSnapshot'] as List<dynamic>?) ?? const []),
      embeddingModelVersion: data['embeddingModelVersion'] as String,
    );
  }
}

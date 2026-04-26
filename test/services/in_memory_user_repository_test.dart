import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/models/user_profile.dart';
import 'package:snapshot/services/testing/in_memory_user_repository.dart';

void main() {
  group('InMemoryUserRepository', () {
    test('returns null for an unknown uid', () async {
      final repo = InMemoryUserRepository();
      expect(await repo.get('does-not-exist'), isNull);
    });

    test('round-trips a saved profile', () async {
      final repo = InMemoryUserRepository();
      final profile = UserProfile(
        uid: 'user-1',
        displayName: 'Alex',
        faceEmbedding: Float32List.fromList([0.1, 0.2, 0.3]),
        embeddingModelVersion: 'mobilefacenet-v1',
        createdAt: DateTime.utc(2026, 4, 26),
      );

      await repo.save(profile);
      final fetched = await repo.get('user-1');

      expect(fetched, isNotNull);
      expect(fetched!.uid, 'user-1');
      expect(fetched.displayName, 'Alex');
      expect(fetched.embeddingModelVersion, 'mobilefacenet-v1');
      expect(fetched.faceEmbedding, equals(profile.faceEmbedding));
    });

    test('save overwrites existing profile', () async {
      final repo = InMemoryUserRepository();
      await repo.save(
        UserProfile(
          uid: 'user-1',
          displayName: 'Alex',
          faceEmbedding: Float32List.fromList([0.1]),
          embeddingModelVersion: 'mobilefacenet-v1',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await repo.save(
        UserProfile(
          uid: 'user-1',
          displayName: 'Alex Renamed',
          faceEmbedding: Float32List.fromList([0.9]),
          embeddingModelVersion: 'mobilefacenet-v1',
          createdAt: DateTime.utc(2026, 2, 1),
        ),
      );
      final fetched = await repo.get('user-1');
      expect(fetched!.displayName, 'Alex Renamed');
      expect(fetched.createdAt, DateTime.utc(2026, 2, 1));
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/cosine_similarity.dart';
import 'package:snapshot/face/no_face_detected_exception.dart';
import 'package:snapshot/face/testing/fake_face_embedder.dart';

void main() {
  group('FakeFaceEmbedder', () {
    test('exposes a stable modelVersion and embeddingDim', () {
      const embedder = FakeFaceEmbedder();
      expect(embedder.modelVersion, 'fake-v1');
      expect(embedder.embeddingDim, 192);
    });

    test('returns deterministic L2-normalized embeddings', () async {
      const embedder = FakeFaceEmbedder();
      final input = Uint8List.fromList(List.generate(64, (i) => i));

      final a = await embedder.embed(input);
      final b = await embedder.embed(input);

      expect(a.length, embedder.embeddingDim);
      expect(b, equals(a));

      final selfSim = cosineSimilarity(a, a);
      expect(selfSim, closeTo(1.0, 1e-5));
    });

    test('different inputs produce different embeddings', () async {
      const embedder = FakeFaceEmbedder();
      final a = await embedder.embed(Uint8List.fromList([1, 2, 3, 4]));
      final b = await embedder.embed(Uint8List.fromList([5, 6, 7, 8]));
      expect(a, isNot(equals(b)));
      // They shouldn't be perfectly aligned by chance.
      final sim = cosineSimilarity(a, b);
      expect(sim.abs(), lessThan(0.999));
    });

    test('all-zero bytes still produce a unit vector', () async {
      const embedder = FakeFaceEmbedder();
      final out = await embedder.embed(Uint8List.fromList([0, 0, 0, 0]));
      expect(out.length, embedder.embeddingDim);
      final selfSim = cosineSimilarity(out, out);
      expect(selfSim, closeTo(1.0, 1e-5));
    });

    test('rejects empty input', () async {
      const embedder = FakeFaceEmbedder();
      expect(
        () => embedder.embed(Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('throwOnEmbed surfaces the configured exception', () async {
      const embedder = FakeFaceEmbedder(
        throwOnEmbed: NoFaceDetectedException('test'),
      );
      expect(
        () => embedder.embed(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<NoFaceDetectedException>()),
      );
    });

    test('close() is safe to call', () async {
      const embedder = FakeFaceEmbedder();
      await embedder.close();
      await embedder.close(); // idempotent
    });
  });
}

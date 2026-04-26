import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/face/cosine_similarity.dart';

void main() {
  group('cosineSimilarity', () {
    test('identical vectors return 1.0', () {
      final v = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      expect(cosineSimilarity(v, v), closeTo(1.0, 1e-6));
    });

    test('opposite vectors return -1.0', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([-1.0, -2.0, -3.0]);
      expect(cosineSimilarity(a, b), closeTo(-1.0, 1e-6));
    });

    test('orthogonal vectors return 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(cosineSimilarity(a, b), closeTo(0.0, 1e-6));
    });

    test('result is invariant under positive scaling', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([2.0, 4.0, 6.0]);
      expect(cosineSimilarity(a, b), closeTo(1.0, 1e-6));
    });

    test('throws on length mismatch', () {
      final a = Float32List.fromList([1.0, 2.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(() => cosineSimilarity(a, b), throwsArgumentError);
    });

    test('throws on empty input', () {
      final empty = Float32List(0);
      expect(() => cosineSimilarity(empty, empty), throwsArgumentError);
    });

    test('throws on zero-norm input', () {
      final a = Float32List.fromList([0.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(() => cosineSimilarity(a, b), throwsArgumentError);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/services/tag_repository.dart';

void main() {
  group('tagResultFromString', () {
    test('parses every documented submitTag verdict', () {
      expect(tagResultFromString('hit'), TagResult.hit);
      expect(tagResultFromString('no_match'), TagResult.noMatch);
      expect(tagResultFromString('immune'), TagResult.immune);
      expect(tagResultFromString('cooldown'), TagResult.cooldown);
    });

    test('throws on an unknown verdict so a server schema drift is loud', () {
      expect(
        () => tagResultFromString('exploded'),
        throwsArgumentError,
      );
    });
  });
}

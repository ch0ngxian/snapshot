import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapshot/services/tag_id.dart';

void main() {
  test('produces a 32-char hex string', () {
    final id = generateTagId();
    expect(id, hasLength(32));
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(id), isTrue);
  });

  test('matches the storage.rules character class for tag filenames', () {
    // storage.rules: ^[A-Za-z0-9_-]+\.jpg$ — hex is a strict subset.
    final id = generateTagId();
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
  });

  test('two consecutive generates with default RNG produce different ids', () {
    final a = generateTagId();
    final b = generateTagId();
    expect(a, isNot(equals(b)));
  });

  test('seeded RNG produces deterministic ids', () {
    final a = generateTagId(Random(42));
    final b = generateTagId(Random(42));
    expect(a, equals(b));
  });
}

import 'dart:math';

/// Generates a tagId suitable for `tags/{tagId}` and the storage filename
/// `tags/{lobbyId}/{tagId}.jpg`. The character set matches the
/// `^[A-Za-z0-9_-]+\.jpg$` regex enforced in storage.rules — base16 (hex)
/// is a strict subset, so we never trip the rule by accident.
///
/// 128 bits of randomness. Collision probability inside a single round
/// (≤20 players, ≤a few hundred tags) is effectively zero.
String generateTagId([Random? rng]) {
  final r = rng ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

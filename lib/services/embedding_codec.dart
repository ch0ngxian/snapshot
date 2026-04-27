import 'dart:typed_data';

/// Decodes a Firestore array-of-numbers into the embedding format used by
/// the face pipeline (`Float32List`, length 128 in production). Tolerant
/// of either `int` or `double` element types — Firestore returns whatever
/// the writer used.
Float32List decodeEmbedding(List<dynamic> raw) {
  final out = Float32List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    out[i] = (raw[i] as num).toDouble();
  }
  return out;
}

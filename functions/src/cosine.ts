/**
 * Cosine similarity for face embeddings (tech-plan §5.8).
 *
 * Returns a similarity in [-1, 1] — `1` means identical direction, `0`
 * orthogonal, `-1` opposite. Scale-invariant: only the angle matters, not
 * the magnitude.
 *
 * Throws on:
 *   - mismatched lengths (programmer error — embeddings must share a model)
 *   - empty inputs (no defined cosine)
 *   - zero-magnitude inputs (cosine undefined; division by zero)
 *
 * Used by `submitTag` to score the caller's embedding against every alive
 * opponent's `embeddingSnapshot`. The schema in tech-plan §3 names the
 * winning score `topMatchDistance` — that's a misnomer carried through from
 * the plan; the value here is a similarity, with higher = closer match.
 */
export function cosineSimilarity(a: readonly number[], b: readonly number[]): number {
  if (a.length !== b.length) {
    throw new Error(
      `cosineSimilarity: length mismatch (${a.length} vs ${b.length})`,
    );
  }
  if (a.length === 0) {
    throw new Error("cosineSimilarity: empty vectors");
  }
  let dot = 0;
  let aMagSq = 0;
  let bMagSq = 0;
  for (let i = 0; i < a.length; i++) {
    const ai = a[i];
    const bi = b[i];
    dot += ai * bi;
    aMagSq += ai * ai;
    bMagSq += bi * bi;
  }
  if (aMagSq === 0 || bMagSq === 0) {
    throw new Error("cosineSimilarity: zero-magnitude vector");
  }
  return dot / Math.sqrt(aMagSq * bMagSq);
}

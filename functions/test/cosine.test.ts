/**
 * Unit test for the cosine-similarity helper used by submitTag (tech-plan §5.8).
 * The metric must be a stable [-1, 1] similarity (not a distance), since §5.8
 * defines acceptance as `cosine_similarity(...) >= threshold`.
 */

import { cosineSimilarity } from "../src/cosine";

describe("cosineSimilarity", () => {
  test("identical vectors → 1", () => {
    const v = [0.1, 0.2, 0.3, 0.4];
    expect(cosineSimilarity(v, v)).toBeCloseTo(1, 10);
  });

  test("opposite vectors → -1", () => {
    const a = [1, 2, 3];
    const b = [-1, -2, -3];
    expect(cosineSimilarity(a, b)).toBeCloseTo(-1, 10);
  });

  test("orthogonal vectors → 0", () => {
    expect(cosineSimilarity([1, 0], [0, 1])).toBeCloseTo(0, 10);
    expect(cosineSimilarity([1, 0, 0], [0, 1, 0])).toBeCloseTo(0, 10);
  });

  test("scale invariance (cosine ignores magnitude)", () => {
    const a = [1, 2, 3];
    const b = [10, 20, 30];
    expect(cosineSimilarity(a, b)).toBeCloseTo(1, 10);
  });

  test("rejects mismatched length", () => {
    expect(() => cosineSimilarity([1, 2], [1, 2, 3])).toThrow(/length/i);
  });

  test("rejects empty vectors", () => {
    expect(() => cosineSimilarity([], [])).toThrow(/empty/i);
  });

  test("rejects zero-magnitude vector (undefined cosine)", () => {
    expect(() => cosineSimilarity([0, 0, 0], [1, 2, 3])).toThrow(
      /zero|magnitude/i,
    );
    expect(() => cosineSimilarity([1, 2, 3], [0, 0, 0])).toThrow(
      /zero|magnitude/i,
    );
  });
});

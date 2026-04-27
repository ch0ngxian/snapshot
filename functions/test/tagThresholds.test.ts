/**
 * Unit test for the Remote Config threshold reader (tech-plan §5.8 / §5.9).
 * The reader caches Remote Config values for 60s in-memory so submitTag
 * doesn't pay an RC fetch on every tag attempt, but stays tunable without
 * a Function redeploy.
 *
 * Defaults must be present in code (0.65 / 0.10) so a missing or unparseable
 * RC template can't break tagging.
 */

const getTemplate = jest.fn();

jest.mock("firebase-admin", () => ({
  initializeApp: jest.fn(),
  remoteConfig: () => ({ getTemplate }),
}));

import {
  loadTagThresholds,
  __resetTagThresholdsCacheForTest,
} from "../src/tagThresholds";

const buildTemplate = (
  threshold: string | undefined,
  half: string | undefined,
) => {
  const parameters: Record<string, unknown> = {};
  if (threshold !== undefined) {
    parameters.tag_match_threshold = {
      defaultValue: { value: threshold },
    };
  }
  if (half !== undefined) {
    parameters.borderline_half_width = {
      defaultValue: { value: half },
    };
  }
  return { parameters };
};

beforeEach(() => {
  jest.clearAllMocks();
  __resetTagThresholdsCacheForTest();
});

describe("loadTagThresholds", () => {
  test("parses RC values on first call", async () => {
    getTemplate.mockResolvedValue(buildTemplate("0.72", "0.08"));
    const result = await loadTagThresholds();
    expect(result).toEqual({ threshold: 0.72, halfWidth: 0.08 });
    expect(getTemplate).toHaveBeenCalledTimes(1);
  });

  test("caches subsequent calls within TTL", async () => {
    getTemplate.mockResolvedValue(buildTemplate("0.7", "0.1"));
    await loadTagThresholds();
    await loadTagThresholds();
    await loadTagThresholds();
    expect(getTemplate).toHaveBeenCalledTimes(1);
  });

  test("refetches after TTL expires", async () => {
    getTemplate.mockResolvedValue(buildTemplate("0.7", "0.1"));
    const start = 1_000_000;
    const nowSpy = jest.spyOn(Date, "now").mockReturnValue(start);
    await loadTagThresholds();
    nowSpy.mockReturnValue(start + 30_000); // 30s — still cached
    await loadTagThresholds();
    nowSpy.mockReturnValue(start + 61_000); // 61s — past 60s TTL
    await loadTagThresholds();
    expect(getTemplate).toHaveBeenCalledTimes(2);
    nowSpy.mockRestore();
  });

  test("falls back to plan defaults when RC fetch throws", async () => {
    getTemplate.mockRejectedValue(new Error("rc unavailable"));
    const result = await loadTagThresholds();
    expect(result).toEqual({ threshold: 0.65, halfWidth: 0.1 });
  });

  test("falls back to plan defaults when parameter is missing", async () => {
    getTemplate.mockResolvedValue(buildTemplate(undefined, undefined));
    const result = await loadTagThresholds();
    expect(result).toEqual({ threshold: 0.65, halfWidth: 0.1 });
  });

  test("falls back to plan defaults when value is unparseable", async () => {
    getTemplate.mockResolvedValue(buildTemplate("not-a-number", "huh"));
    const result = await loadTagThresholds();
    expect(result).toEqual({ threshold: 0.65, halfWidth: 0.1 });
  });

  test("clamps absurd RC values to safe range", async () => {
    // Threshold above 1 or below -1 has no meaning for cosine similarity.
    // halfWidth must be non-negative.
    getTemplate.mockResolvedValue(buildTemplate("99", "-5"));
    const result = await loadTagThresholds();
    expect(result.threshold).toBeLessThanOrEqual(1);
    expect(result.threshold).toBeGreaterThanOrEqual(-1);
    expect(result.halfWidth).toBeGreaterThanOrEqual(0);
  });
});

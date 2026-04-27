import * as admin from "firebase-admin";
import { logger } from "firebase-functions";

/**
 * Per tech-plan §5.8 / §5.9: read the cosine acceptance threshold and the
 * borderline-band half-width from Firebase Remote Config, with a 60s
 * in-memory cache. Tunable from the RC console without a Function redeploy.
 *
 * Defaults are kept in code so a missing or unparseable RC template can't
 * break tagging — they match the values seeded into
 * `remoteconfig.template.json`.
 */
export interface TagThresholds {
  threshold: number;
  halfWidth: number;
}

export const DEFAULT_THRESHOLDS: TagThresholds = {
  threshold: 0.65,
  halfWidth: 0.1,
};

const CACHE_TTL_MS = 60_000;

interface CacheEntry {
  value: TagThresholds;
  fetchedAt: number;
}

let cache: CacheEntry | null = null;
let inFlight: Promise<TagThresholds> | null = null;

export async function loadTagThresholds(): Promise<TagThresholds> {
  const now = Date.now();
  if (cache && now - cache.fetchedAt < CACHE_TTL_MS) {
    return cache.value;
  }
  if (inFlight) return inFlight;
  inFlight = fetchAndCache(now).finally(() => {
    inFlight = null;
  });
  return inFlight;
}

async function fetchAndCache(now: number): Promise<TagThresholds> {
  let value: TagThresholds = DEFAULT_THRESHOLDS;
  try {
    const template = await admin.remoteConfig().getTemplate();
    value = parseThresholds(template.parameters);
  } catch (err) {
    logger.warn("loadTagThresholds: RC fetch failed, using defaults", {
      error: (err as Error).message,
    });
  }
  cache = { value, fetchedAt: now };
  return value;
}

function parseThresholds(
  parameters: Record<string, unknown> | undefined,
): TagThresholds {
  const threshold = clamp(
    parseRcNumber(parameters, "tag_match_threshold"),
    -1,
    1,
    DEFAULT_THRESHOLDS.threshold,
  );
  const halfWidth = clamp(
    parseRcNumber(parameters, "borderline_half_width"),
    0,
    2,
    DEFAULT_THRESHOLDS.halfWidth,
  );
  return { threshold, halfWidth };
}

function parseRcNumber(
  parameters: Record<string, unknown> | undefined,
  key: string,
): number | null {
  const param = (parameters ?? {})[key] as
    | { defaultValue?: { value?: unknown } }
    | undefined;
  const raw = param?.defaultValue?.value;
  if (typeof raw !== "string") return null;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function clamp(
  value: number | null,
  min: number,
  max: number,
  fallback: number,
): number {
  if (value === null) return fallback;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/** Test-only: drop the cache between cases. */
export function __resetTagThresholdsCacheForTest(): void {
  cache = null;
  inFlight = null;
}

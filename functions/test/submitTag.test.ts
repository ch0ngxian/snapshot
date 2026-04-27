/**
 * Unit test for submitTag — the server-authoritative tag verifier
 * (tech-plan §5.1, §5.8, §5.9, §326).
 *
 * Covers:
 *   - rejects unauthenticated callers
 *   - rejects bad inputs (missing fields, embedding length != 128,
 *     embedding values not numeric, blank modelVersion)
 *   - rejects when caller has no player record / is eliminated
 *   - rejects when lobby status != active
 *   - rejects when caller's modelVersion != stored snapshot version
 *   - cooldown: tag within 5s of caller's last attempt → result "cooldown"
 *   - idempotent: replaying the same tagId returns the prior verdict
 *   - immune: top opponent's lastTaggedAt within rules.immunitySeconds
 *   - no_match: top similarity below threshold
 *   - hit: top similarity at or above threshold → victim livesRemaining--
 *   - eliminated: livesRemaining hitting 0 sets status=eliminated
 *   - end-round: hit that drops alive count to ≤1 flips lobby to ended
 *   - retainPhoto: returns true iff |topSim - threshold| < halfWidth
 *
 * The mock harness mirrors startRound.test.ts / endRound.test.ts.
 */

import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

// ---------- Firestore mock plumbing ----------

interface FakeDoc<T> {
  exists: boolean;
  data: () => T | undefined;
  ref: { id: string };
}

const lobbyGet = jest.fn();
const lobbyUpdate = jest.fn();
const playerGetByUid: Record<string, jest.Mock> = {};
const playerUpdateByUid: Record<string, jest.Mock> = {};
const playerSetByUid: Record<string, jest.Mock> = {};
const playersAliveQueryGet = jest.fn();
const tagDocGet = jest.fn();
const tagDocSet = jest.fn();
const userDocGet = jest.fn();
const fcmSend = jest.fn();
const rcGetTemplate = jest.fn();

let lobbyState: Record<string, unknown> | null = null;
let playerStateByUid: Record<string, Record<string, unknown> | null> = {};
let aliveOpponents: { uid: string; data: Record<string, unknown> }[] = [];
let existingTagDoc: Record<string, unknown> | null = null;
let userDocByUid: Record<string, Record<string, unknown> | null> = {};

const lobbyRef = (() => {
  const playersCollection = {
    doc: (uid: string) => {
      playerGetByUid[uid] = playerGetByUid[uid] ?? jest.fn();
      playerUpdateByUid[uid] = playerUpdateByUid[uid] ?? jest.fn();
      playerSetByUid[uid] = playerSetByUid[uid] ?? jest.fn();
      const ref = {
        get: playerGetByUid[uid],
        update: playerUpdateByUid[uid],
        set: playerSetByUid[uid],
        id: uid,
      };
      return ref;
    },
    where: (..._args: unknown[]) => ({
      get: playersAliveQueryGet,
    }),
  };
  const tagsCollection = {
    doc: (_tagId: string) => ({
      get: tagDocGet,
      set: tagDocSet,
    }),
  };
  return {
    get: lobbyGet,
    update: lobbyUpdate,
    collection: (name: string) => {
      if (name === "players") return playersCollection;
      if (name === "tags") return tagsCollection;
      throw new Error(`unexpected collection ${name}`);
    },
  };
})();

const lobbiesCollection = { doc: () => lobbyRef };
const usersCollection = {
  doc: (uid: string) => ({
    get: () => {
      userDocGet(uid);
      const data = userDocByUid[uid];
      return Promise.resolve({
        exists: data !== null && data !== undefined,
        data: () => data ?? undefined,
      });
    },
  }),
};

const runTransaction = jest.fn(
  async (
    fn: (tx: {
      get: jest.Mock;
      update: jest.Mock;
      set: jest.Mock;
    }) => Promise<unknown>,
  ) => {
    const tx = {
      get: jest.fn(async (target: unknown) => {
        const t = target as
          | { get?: jest.Mock }
          | { _isAliveQuery?: boolean };
        if ((t as { _isAliveQuery?: boolean })._isAliveQuery) {
          return playersAliveQueryGet();
        }
        return (t as { get: jest.Mock }).get();
      }),
      update: jest.fn((target: { update: jest.Mock }, data: unknown) =>
        target.update(data),
      ),
      set: jest.fn((target: { set: jest.Mock }, data: unknown) =>
        target.set(data),
      ),
    };
    return fn(tx);
  },
);

jest.mock("firebase-admin", () => {
  const firestore: jest.Mock & { FieldValue?: unknown } = jest.fn(() => ({
    collection: (name: string) => {
      if (name === "lobbies") return lobbiesCollection;
      if (name === "users") return usersCollection;
      throw new Error(`unexpected collection ${name}`);
    },
    runTransaction,
  }));
  firestore.FieldValue = {
    serverTimestamp: () => "<<ts>>",
    increment: (n: number) => ({ __increment: n }),
  };
  return {
    initializeApp: jest.fn(),
    firestore,
    storage: () => ({ bucket: () => ({}) }),
    remoteConfig: () => ({ getTemplate: rcGetTemplate }),
    messaging: () => ({ send: fcmSend }),
  };
});

import { submitTag } from "../src/submitTag";
import { __resetTagThresholdsCacheForTest } from "../src/tagThresholds";

const handler = (
  submitTag as unknown as {
    run: (req: CallableRequest<unknown>) => Promise<unknown>;
  }
).run;

// ---------- helpers ----------

const v128 = (seed: number): number[] =>
  Array.from({ length: 128 }, (_, i) => Math.sin(seed + i * 0.01));

const buildReq = (
  uid: string | null,
  data: unknown,
): CallableRequest<unknown> =>
  ({
    auth: uid ? { uid, token: {} } : undefined,
    data,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<unknown>;

const baseInput = (overrides: Record<string, unknown> = {}) => ({
  lobbyId: "lobby-1",
  tagId: "tag-1",
  embedding: v128(0),
  modelVersion: "mobilefacenet-v1",
  ...overrides,
});

const setupActiveLobby = (rules: { immunitySeconds: number } = { immunitySeconds: 10 }) => {
  lobbyState = { status: "active", rules };
  lobbyGet.mockImplementation(async () => ({
    exists: lobbyState !== null,
    data: () => lobbyState,
  }));
};

const setupPlayer = (uid: string, data: Record<string, unknown>) => {
  playerStateByUid[uid] = data;
  if (!playerGetByUid[uid]) playerGetByUid[uid] = jest.fn();
  playerGetByUid[uid].mockImplementation(async () => ({
    exists: playerStateByUid[uid] !== null,
    data: () => playerStateByUid[uid],
    ref: { id: uid },
  }));
};

const setAliveOpponents = (
  opponents: { uid: string; data: Record<string, unknown> }[],
) => {
  aliveOpponents = opponents;
  playersAliveQueryGet.mockImplementation(async () => ({
    docs: opponents.map((o) => ({
      id: o.uid,
      data: () => o.data,
      ref: lobbyRef.collection("players").doc(o.uid),
    })),
    size: opponents.length,
  }));
};

const setupTagDoc = (existing: Record<string, unknown> | null) => {
  existingTagDoc = existing;
  tagDocGet.mockImplementation(async () => ({
    exists: existingTagDoc !== null,
    data: () => existingTagDoc,
  }));
};

beforeEach(() => {
  jest.clearAllMocks();
  __resetTagThresholdsCacheForTest();
  lobbyState = null;
  playerStateByUid = {};
  for (const k of Object.keys(playerGetByUid)) delete playerGetByUid[k];
  for (const k of Object.keys(playerUpdateByUid)) delete playerUpdateByUid[k];
  for (const k of Object.keys(playerSetByUid)) delete playerSetByUid[k];
  aliveOpponents = [];
  existingTagDoc = null;
  userDocByUid = {};
  rcGetTemplate.mockResolvedValue({
    parameters: {
      tag_match_threshold: { defaultValue: { value: "0.65" } },
      borderline_half_width: { defaultValue: { value: "0.10" } },
    },
  });
  fcmSend.mockResolvedValue("msg-id");
  setupTagDoc(null);
});

// ---------- tests ----------

describe("submitTag — input validation", () => {
  test("rejects unauthenticated callers", async () => {
    await expect(handler(buildReq(null, baseInput()))).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("rejects missing lobbyId", async () => {
    await expect(
      handler(buildReq("u1", baseInput({ lobbyId: "" }))),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects missing tagId", async () => {
    await expect(
      handler(buildReq("u1", baseInput({ tagId: "" }))),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects missing modelVersion", async () => {
    await expect(
      handler(buildReq("u1", baseInput({ modelVersion: "" }))),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects embedding of wrong length", async () => {
    await expect(
      handler(buildReq("u1", baseInput({ embedding: v128(0).slice(0, 64) }))),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects embedding with non-numeric values", async () => {
    const bad = v128(0).map((x, i) => (i === 5 ? ("hi" as unknown as number) : x));
    await expect(
      handler(buildReq("u1", baseInput({ embedding: bad }))),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });
});

describe("submitTag — preconditions", () => {
  test("rejects when lobby does not exist", async () => {
    lobbyGet.mockResolvedValue({ exists: false, data: () => undefined });
    setupPlayer("u1", { status: "alive", embeddingModelVersion: "mobilefacenet-v1" });
    await expect(handler(buildReq("u1", baseInput()))).rejects.toMatchObject({
      code: "not-found",
    });
  });

  test("rejects when lobby is waiting", async () => {
    lobbyState = { status: "waiting", rules: { immunitySeconds: 10 } };
    lobbyGet.mockImplementation(async () => ({ exists: true, data: () => lobbyState }));
    setupPlayer("u1", { status: "alive", embeddingModelVersion: "mobilefacenet-v1" });
    await expect(handler(buildReq("u1", baseInput()))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("rejects when caller is not a player in the lobby", async () => {
    setupActiveLobby();
    setupPlayer("u1", null as unknown as Record<string, unknown>);
    playerStateByUid["u1"] = null;
    await expect(handler(buildReq("u1", baseInput()))).rejects.toMatchObject({
      code: "permission-denied",
    });
  });

  test("rejects when caller is eliminated", async () => {
    setupActiveLobby();
    setupPlayer("u1", {
      status: "eliminated",
      embeddingModelVersion: "mobilefacenet-v1",
    });
    await expect(handler(buildReq("u1", baseInput()))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("rejects modelVersion mismatch", async () => {
    setupActiveLobby();
    setupPlayer("u1", { status: "alive", embeddingModelVersion: "mobilefacenet-v0" });
    await expect(
      handler(buildReq("u1", baseInput({ modelVersion: "mobilefacenet-v1" }))),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });
});

// ---------- helpers for the verdict tests ----------

const millisAgo = (ms: number) => ({
  toMillis: () => Date.now() - ms,
});

describe("submitTag — verdicts", () => {
  beforeEach(() => {
    setupActiveLobby({ immunitySeconds: 10 });
    setupPlayer("tagger", {
      status: "alive",
      embeddingModelVersion: "mobilefacenet-v1",
      lastTagAttemptAt: null,
    });
  });

  test("cooldown: caller last-attempted within 5s", async () => {
    setupPlayer("tagger", {
      status: "alive",
      embeddingModelVersion: "mobilefacenet-v1",
      lastTagAttemptAt: millisAgo(2000),
    });
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
    };
    expect(out.result).toBe("cooldown");
    expect(out.retainPhoto).toBe(false);
    // Cooldown short-circuits before opponents are loaded — alive query
    // and victim writes must never run.
    expect(playersAliveQueryGet).not.toHaveBeenCalled();
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({
        accepted: false,
        rejectReason: "cooldown",
      }),
    );
  });

  test("hit: top similarity above threshold decrements victim and writes tag", async () => {
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 3 } },
      { uid: "other", data: { status: "alive", embeddingSnapshot: v128(100), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
      victimLivesRemaining: number;
      eliminated: boolean;
      tagId: string;
    };
    expect(out.result).toBe("hit");
    expect(out.victimLivesRemaining).toBe(2);
    expect(out.eliminated).toBe(false);
    expect(playerUpdateByUid["victim"]).toHaveBeenCalledWith(
      expect.objectContaining({
        livesRemaining: 2,
      }),
    );
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({
        taggerUid: "tagger",
        resolvedTargetUid: "victim",
        accepted: true,
        modelVersion: "mobilefacenet-v1",
      }),
    );
  });

  test("no_match: best similarity below threshold", async () => {
    setAliveOpponents([
      { uid: "stranger", data: { status: "alive", embeddingSnapshot: v128(500), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
    };
    expect(out.result).toBe("no_match");
    expect(playerUpdateByUid["stranger"]).not.toHaveBeenCalled();
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({ accepted: false }),
    );
  });

  test("immune: top match's lastTaggedAt within immunitySeconds", async () => {
    setAliveOpponents([
      {
        uid: "victim",
        data: {
          status: "alive",
          embeddingSnapshot: v128(0),
          livesRemaining: 3,
          lastTaggedAt: millisAgo(4_000), // 4s ago, immunity 10s
        },
      },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
    };
    expect(out.result).toBe("immune");
    expect(playerUpdateByUid["victim"]).not.toHaveBeenCalled();
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({
        accepted: false,
        rejectReason: "immune",
      }),
    );
  });

  test("immunity expired: lastTaggedAt older than immunitySeconds → hit", async () => {
    setAliveOpponents([
      {
        uid: "victim",
        data: {
          status: "alive",
          embeddingSnapshot: v128(0),
          livesRemaining: 3,
          lastTaggedAt: millisAgo(15_000),
        },
      },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
    };
    expect(out.result).toBe("hit");
  });

  test("eliminated: livesRemaining hitting 0 sets status=eliminated", async () => {
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 1 } },
      { uid: "other", data: { status: "alive", embeddingSnapshot: v128(100), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      eliminated: boolean;
      victimLivesRemaining: number;
    };
    expect(out.result).toBe("hit");
    expect(out.eliminated).toBe(true);
    expect(out.victimLivesRemaining).toBe(0);
    expect(playerUpdateByUid["victim"]).toHaveBeenCalledWith(
      expect.objectContaining({ livesRemaining: 0, status: "eliminated" }),
    );
  });

  test("end-round on last alive: lobby flipped to ended", async () => {
    // Only one opponent left; eliminating them leaves only the tagger alive.
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 1 } },
    ]);
    await handler(buildReq("tagger", baseInput()));
    expect(lobbyUpdate).toHaveBeenCalledWith(
      expect.objectContaining({ status: "ended" }),
    );
  });

  test("retainPhoto: borderline band returns true", async () => {
    // Cosine ~ identical vectors; threshold 0.65 + halfWidth 0.10 → keep.
    // We tune RC threshold to exactly the cosine score so |sim - threshold| = 0.
    rcGetTemplate.mockResolvedValue({
      parameters: {
        tag_match_threshold: { defaultValue: { value: "1" } },
        borderline_half_width: { defaultValue: { value: "0.5" } },
      },
    });
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
    };
    expect(out.retainPhoto).toBe(true);
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({ photoStorageRef: null }),
    );
  });

  test("retainPhoto: clear-accept (far above threshold) returns false", async () => {
    rcGetTemplate.mockResolvedValue({
      parameters: {
        tag_match_threshold: { defaultValue: { value: "0.1" } },
        borderline_half_width: { defaultValue: { value: "0.05" } },
      },
    });
    setAliveOpponents([
      { uid: "victim", data: { status: "alive", embeddingSnapshot: v128(0), livesRemaining: 3 } },
    ]);
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
    };
    expect(out.result).toBe("hit");
    expect(out.retainPhoto).toBe(false);
    expect(tagDocSet).toHaveBeenCalledWith(
      expect.objectContaining({ photoStorageRef: "discarded" }),
    );
  });

  test("idempotent replay: existing tag doc returns prior verdict", async () => {
    setupTagDoc({
      result: "hit",
      retainPhoto: true,
      victimLivesRemaining: 2,
      eliminated: false,
      taggerUid: "tagger",
      resolvedTargetUid: "victim",
    });
    const out = (await handler(buildReq("tagger", baseInput()))) as {
      result: string;
      retainPhoto: boolean;
      victimLivesRemaining?: number;
      tagId: string;
    };
    expect(out.result).toBe("hit");
    expect(out.retainPhoto).toBe(true);
    expect(out.victimLivesRemaining).toBe(2);
    expect(tagDocSet).not.toHaveBeenCalled();
    expect(playerUpdateByUid["victim"]).toBeUndefined();
  });

  test("idempotent replay rejects when caller mismatches stored taggerUid", async () => {
    setupTagDoc({
      result: "hit",
      retainPhoto: true,
      taggerUid: "someone-else",
      resolvedTargetUid: "victim",
    });
    await expect(
      handler(buildReq("tagger", baseInput())),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  test("HttpsError instances bubble up unchanged", async () => {
    lobbyState = null; // not-found
    lobbyGet.mockImplementation(async () => ({ exists: false, data: () => undefined }));
    setupPlayer("tagger", {
      status: "alive",
      embeddingModelVersion: "mobilefacenet-v1",
    });
    await expect(handler(buildReq("tagger", baseInput()))).rejects.toBeInstanceOf(
      HttpsError,
    );
  });
});

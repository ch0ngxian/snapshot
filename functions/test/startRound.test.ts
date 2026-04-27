/**
 * Unit test for startRound. Mocks the admin SDK to verify:
 *   - rejects unauthenticated callers
 *   - rejects callers who aren't the host
 *   - rejects when status != waiting (already-active or already-ended)
 *   - rejects when fewer than 2 players have joined
 *   - rejects malformed / out-of-range rules
 *   - falls back to defaults when rules are partially specified
 *   - writes status=active, startedAt, rules; resets every player's lives
 */

import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

const lobbyGet = jest.fn();
const lobbyUpdate = jest.fn();
const playerUpdate = jest.fn();
const playersGet = jest.fn();

let lobbyData: Record<string, unknown> | null = null;
let playerDocs: { uid: string; ref: { update: jest.Mock } }[] = [];

const lobbyRef = {
  get: lobbyGet,
  update: lobbyUpdate,
  collection: (name: string) => {
    if (name !== "players") throw new Error(`unexpected ${name}`);
    return {
      get: playersGet,
    };
  },
};

const lobbiesCollection = {
  doc: () => lobbyRef,
};

const runTransaction = jest.fn(
  async (
    fn: (tx: {
      get: jest.Mock;
      update: jest.Mock;
    }) => Promise<unknown>,
  ) => {
    const tx = {
      get: jest.fn(async (target: { get?: jest.Mock }) => target.get!()),
      update: jest.fn((target: { update: jest.Mock }, data: unknown) =>
        target.update(data),
      ),
    };
    return fn(tx);
  },
);

jest.mock("firebase-admin", () => {
  const firestore: jest.Mock & { FieldValue?: unknown } = jest.fn(() => ({
    collection: (name: string) => {
      if (name === "lobbies") return lobbiesCollection;
      throw new Error(`unexpected collection ${name}`);
    },
    runTransaction,
  }));
  firestore.FieldValue = { serverTimestamp: () => "<<ts>>" };
  return {
    initializeApp: jest.fn(),
    firestore,
    storage: () => ({ bucket: () => ({}) }),
  };
});

import { startRound } from "../src/startRound";

const handler = (
  startRound as unknown as {
    run: (
      req: CallableRequest<{
        lobbyId?: string;
        rules?: Record<string, unknown>;
      }>,
    ) => Promise<unknown>;
  }
).run;

const auth = (
  uid: string | null,
  data: { lobbyId?: string; rules?: Record<string, unknown> } = {
    lobbyId: "lobby-1",
  },
) =>
  ({
    auth: uid ? { uid, token: {} } : undefined,
    data,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<{
    lobbyId?: string;
    rules?: Record<string, unknown>;
  }>;

beforeEach(() => {
  jest.clearAllMocks();
  lobbyData = {
    hostUid: "host-1",
    status: "waiting",
    code: "ABC123",
  };
  playerDocs = [
    { uid: "host-1", ref: { update: jest.fn() } },
    { uid: "joiner-1", ref: { update: jest.fn() } },
  ];
  lobbyGet.mockImplementation(async () => ({
    exists: lobbyData !== null,
    data: () => lobbyData,
  }));
  playersGet.mockImplementation(async () => ({
    size: playerDocs.length,
    docs: playerDocs,
  }));
});

describe("startRound", () => {
  test("rejects unauthenticated callers", async () => {
    await expect(handler(auth(null))).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("rejects callers who aren't the host", async () => {
    await expect(handler(auth("joiner-1"))).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(lobbyUpdate).not.toHaveBeenCalled();
  });

  test("rejects already-active lobbies", async () => {
    lobbyData = { ...(lobbyData as object), status: "active" };
    await expect(handler(auth("host-1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("rejects already-ended lobbies", async () => {
    lobbyData = { ...(lobbyData as object), status: "ended" };
    await expect(handler(auth("host-1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("rejects when fewer than 2 players have joined", async () => {
    playerDocs = [{ uid: "host-1", ref: { update: jest.fn() } }];
    await expect(handler(auth("host-1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
    expect(lobbyUpdate).not.toHaveBeenCalled();
  });

  test("rejects out-of-range startingLives", async () => {
    await expect(
      handler(auth("host-1", { lobbyId: "lobby-1", rules: { startingLives: 99 } })),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects non-integer durationSeconds", async () => {
    await expect(
      handler(
        auth("host-1", { lobbyId: "lobby-1", rules: { durationSeconds: 60.5 } }),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  test("rejects missing lobbyId", async () => {
    await expect(handler(auth("host-1", {}))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  test("falls back to defaults when rules are omitted", async () => {
    await handler(auth("host-1"));
    const call = lobbyUpdate.mock.calls[0][0];
    expect(call).toMatchObject({
      status: "active",
      rules: { startingLives: 3, durationSeconds: 600, immunitySeconds: 10 },
    });
    expect(call.startedAt).toBeDefined();
  });

  test("writes status, rules, startedAt and resets every player's lives", async () => {
    await handler(
      auth("host-1", {
        lobbyId: "lobby-1",
        rules: { startingLives: 5, durationSeconds: 300, immunitySeconds: 15 },
      }),
    );
    expect(lobbyUpdate).toHaveBeenCalledTimes(1);
    expect(lobbyUpdate.mock.calls[0][0]).toMatchObject({
      status: "active",
      rules: { startingLives: 5, durationSeconds: 300, immunitySeconds: 15 },
    });
    for (const p of playerDocs) {
      expect(p.ref.update).toHaveBeenCalledWith({ livesRemaining: 5 });
    }
  });

  test("ok response on success", async () => {
    const result = (await handler(auth("host-1"))) as { ok: boolean };
    expect(result).toEqual({ ok: true });
  });

  test("HttpsError instances bubble up unchanged", async () => {
    lobbyData = null;
    await expect(handler(auth("host-1"))).rejects.toBeInstanceOf(HttpsError);
  });
});

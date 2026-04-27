/**
 * Unit test for endRound. Verifies:
 *   - rejects unauthenticated callers
 *   - rejects callers who aren't a player in the lobby
 *   - rejects when status is `waiting` (round never started)
 *   - flips active → ended (writes status + endedAt)
 *   - is idempotent on already-ended lobbies (alreadyEnded: true, no write)
 */

import { CallableRequest } from "firebase-functions/v2/https";

const lobbyGet = jest.fn();
const lobbyUpdate = jest.fn();
const playerGet = jest.fn();

let lobbyData: Record<string, unknown> | null = null;
let playerExists = true;

const playerRef = { get: playerGet };
const lobbyRef = {
  get: lobbyGet,
  update: lobbyUpdate,
  collection: (name: string) => {
    if (name !== "players") throw new Error(`unexpected ${name}`);
    return { doc: () => playerRef };
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

import { endRound } from "../src/endRound";

const handler = (
  endRound as unknown as {
    run: (
      req: CallableRequest<{ lobbyId?: string }>,
    ) => Promise<unknown>;
  }
).run;

const auth = (
  uid: string | null,
  data: { lobbyId?: string } = { lobbyId: "lobby-1" },
) =>
  ({
    auth: uid ? { uid, token: {} } : undefined,
    data,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<{ lobbyId?: string }>;

beforeEach(() => {
  jest.clearAllMocks();
  lobbyData = { status: "active" };
  playerExists = true;
  lobbyGet.mockImplementation(async () => ({
    exists: lobbyData !== null,
    data: () => lobbyData,
  }));
  playerGet.mockImplementation(async () => ({ exists: playerExists }));
});

describe("endRound", () => {
  test("rejects unauthenticated callers", async () => {
    await expect(handler(auth(null))).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("rejects missing lobbyId", async () => {
    await expect(handler(auth("u1", {}))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  test("rejects callers who aren't a player", async () => {
    playerExists = false;
    await expect(handler(auth("stranger"))).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(lobbyUpdate).not.toHaveBeenCalled();
  });

  test("rejects when status is waiting", async () => {
    lobbyData = { status: "waiting" };
    await expect(handler(auth("u1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("flips active → ended and stamps endedAt", async () => {
    const result = (await handler(auth("u1"))) as {
      ok: boolean;
      alreadyEnded: boolean;
    };
    expect(result).toEqual({ ok: true, alreadyEnded: false });
    expect(lobbyUpdate).toHaveBeenCalledTimes(1);
    const update = lobbyUpdate.mock.calls[0][0];
    expect(update).toMatchObject({ status: "ended" });
    expect(update.endedAt).toBeDefined();
  });

  test("idempotent on already-ended lobbies", async () => {
    lobbyData = { status: "ended" };
    const result = (await handler(auth("u1"))) as {
      ok: boolean;
      alreadyEnded: boolean;
    };
    expect(result).toEqual({ ok: true, alreadyEnded: true });
    expect(lobbyUpdate).not.toHaveBeenCalled();
  });
});

/**
 * Unit test for joinLobby. Mocks the admin SDK to verify:
 *   - rejects unauthenticated callers
 *   - rejects callers without a users/{uid} profile
 *   - rejects unknown / non-waiting codes
 *   - rejects when the lobby is full (>= MAX_PLAYERS)
 *   - is idempotent if the caller is already a player
 *   - writes lobbies/{lobbyId}/players/{uid} with snapshotted embedding
 */

import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

const codeQueryGet = jest.fn();
const playersGet = jest.fn();
const playerDocGet = jest.fn();
const playerDocSet = jest.fn();
const userDocGet = jest.fn();

let lobbyId = "lobby-xyz";

const lobbyDocRef = (id: string) => ({
  id,
  collection: (name: string) => {
    if (name !== "players") throw new Error(`unexpected ${name}`);
    return {
      get: playersGet,
      doc: () => ({
        get: playerDocGet,
        set: playerDocSet,
      }),
    };
  },
});

const lobbiesCollection = {
  where: () => ({
    where: () => ({ limit: () => ({ get: codeQueryGet }) }),
  }),
  doc: (id: string) => lobbyDocRef(id),
};

const usersCollection = {
  doc: () => ({ get: userDocGet }),
};

jest.mock("firebase-admin", () => {
  const firestore: jest.Mock & { FieldValue?: unknown } = jest.fn(() => ({
    collection: (name: string) => {
      if (name === "lobbies") return lobbiesCollection;
      if (name === "users") return usersCollection;
      throw new Error(`unexpected collection ${name}`);
    },
  }));
  firestore.FieldValue = { serverTimestamp: () => "<<ts>>" };
  return {
    initializeApp: jest.fn(),
    firestore,
    storage: () => ({ bucket: () => ({}) }),
  };
});

import { joinLobby } from "../src/joinLobby";

const handler = (joinLobby as unknown as {
  run: (req: CallableRequest<{ code?: string }>) => Promise<unknown>;
}).run;

const auth = (uid: string, data: { code?: string } = { code: "ABC123" }) =>
  ({
    auth: { uid, token: {} },
    data,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<{ code?: string }>;

const profileSnap = (data: Record<string, unknown> | null) => ({
  exists: data != null,
  data: () => data,
});

describe("joinLobby", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    lobbyId = "lobby-xyz";
    playerDocSet.mockResolvedValue(undefined);
    playerDocGet.mockResolvedValue(profileSnap(null));
    playersGet.mockResolvedValue({ size: 1 });
    codeQueryGet.mockResolvedValue({
      empty: false,
      docs: [
        {
          id: lobbyId,
          ref: lobbyDocRef(lobbyId),
          data: () => ({
            status: "waiting",
            rules: { startingLives: 3, durationSeconds: 600, immunitySeconds: 10 },
          }),
        },
      ],
    });
    userDocGet.mockResolvedValue(
      profileSnap({
        displayName: "Bob",
        faceEmbedding: Array.from({ length: 128 }, () => 0.2),
        embeddingModelVersion: "mobilefacenet-v1",
      }),
    );
  });

  test("rejects unauthenticated callers", async () => {
    const unauth = {
      data: { code: "ABC123" },
      rawRequest: {},
      acceptsStreaming: false,
    } as unknown as CallableRequest<{ code: string }>;
    await expect(handler(unauth)).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("rejects missing or malformed codes", async () => {
    await expect(handler(auth("u1", { code: "" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    await expect(handler(auth("u1", { code: "abc" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
  });

  test("rejects callers without an onboarded profile", async () => {
    userDocGet.mockResolvedValueOnce(profileSnap(null));
    await expect(handler(auth("u1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("rejects unknown codes", async () => {
    codeQueryGet.mockResolvedValueOnce({ empty: true, docs: [] });
    await expect(handler(auth("u1"))).rejects.toMatchObject({
      code: "not-found",
    });
  });

  test("rejects when the lobby is full", async () => {
    playersGet.mockResolvedValueOnce({ size: 20 });
    await expect(handler(auth("u1"))).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    expect(playerDocSet).not.toHaveBeenCalled();
  });

  test("is idempotent when the caller already joined", async () => {
    playerDocGet.mockResolvedValueOnce(
      profileSnap({ displayName: "Bob", status: "alive" }),
    );
    const result = (await handler(auth("u1"))) as { lobbyId: string };
    expect(result.lobbyId).toBe(lobbyId);
    expect(playerDocSet).not.toHaveBeenCalled();
  });

  test("writes player record with snapshotted embedding", async () => {
    const result = (await handler(auth("user-7"))) as { lobbyId: string };
    expect(result.lobbyId).toBe(lobbyId);
    expect(playerDocSet).toHaveBeenCalledTimes(1);
    const player = playerDocSet.mock.calls[0][0];
    expect(player).toMatchObject({
      displayName: "Bob",
      livesRemaining: 3,
      status: "alive",
      embeddingModelVersion: "mobilefacenet-v1",
    });
    expect(player.embeddingSnapshot).toHaveLength(128);
    expect(player.joinedAt).toBeDefined();
  });

  test("normalizes mixed-case codes", async () => {
    await handler(auth("user-9", { code: "abc123" }));
    expect(playerDocSet).toHaveBeenCalledTimes(1);
  });
});

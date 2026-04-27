/**
 * Unit test for createLobby. Mocks the admin SDK to verify:
 *   - rejects unauthenticated callers
 *   - rejects callers without a users/{uid} profile
 *   - generates a 6-char base36 (A-Z 0-9) code
 *   - retries on code collision
 *   - writes lobbies/{lobbyId} (status=waiting, default rules) and
 *     lobbies/{lobbyId}/players/{hostUid} with snapshotted embedding
 */

import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

// --- mock state ---
const lobbyDocSet = jest.fn();
const playerDocSet = jest.fn();
const codeQueryGet = jest.fn();
const userDocGet = jest.fn();

let nextLobbyId = "auto-id";
const collectionImpls: Record<string, jest.Mock> = {};

const lobbiesCollection = {
  where: () => ({ where: () => ({ limit: () => ({ get: codeQueryGet }) }) }),
  doc: (id?: string) => ({
    id: id ?? nextLobbyId,
    set: lobbyDocSet,
    collection: (name: string) => {
      if (name === "players") {
        return { doc: () => ({ set: playerDocSet }) };
      }
      throw new Error(`unexpected subcollection ${name}`);
    },
  }),
};

const usersCollection = {
  doc: () => ({ get: userDocGet }),
};

jest.mock("firebase-admin", () => {
  const firestore: jest.Mock & { FieldValue?: unknown } = jest.fn(() => ({
    collection: (name: string) => {
      if (name === "lobbies") return lobbiesCollection;
      if (name === "users") return usersCollection;
      const fn = collectionImpls[name];
      if (fn) return fn();
      throw new Error(`unexpected collection ${name}`);
    },
  }));
  firestore.FieldValue = {
    serverTimestamp: () => "<<serverTimestamp>>",
  };
  return {
    initializeApp: jest.fn(),
    firestore,
    storage: () => ({ bucket: () => ({}) }),
  };
});

import { createLobby } from "../src/createLobby";

const handler = (createLobby as unknown as {
  run: (req: CallableRequest<unknown>) => Promise<unknown>;
}).run;

const auth = (uid: string) =>
  ({
    auth: { uid, token: {} },
    data: undefined,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<unknown>;

const profileSnap = (data: Record<string, unknown> | null) => ({
  exists: data != null,
  data: () => data,
});

describe("createLobby", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    nextLobbyId = "lobby-abc";
    lobbyDocSet.mockResolvedValue(undefined);
    playerDocSet.mockResolvedValue(undefined);
    codeQueryGet.mockResolvedValue({ empty: true });
    userDocGet.mockResolvedValue(
      profileSnap({
        displayName: "Alice",
        faceEmbedding: Array.from({ length: 128 }, () => 0.1),
        embeddingModelVersion: "mobilefacenet-v1",
      }),
    );
  });

  test("rejects unauthenticated callers", async () => {
    const unauth = {
      data: undefined,
      rawRequest: {},
      acceptsStreaming: false,
    } as unknown as CallableRequest<unknown>;
    await expect(handler(unauth)).rejects.toBeInstanceOf(HttpsError);
    await expect(handler(unauth)).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("rejects callers without an onboarded profile", async () => {
    userDocGet.mockResolvedValueOnce(profileSnap(null));
    await expect(handler(auth("host-1"))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  test("returns 6-char base36 code on success", async () => {
    const result = (await handler(auth("host-1"))) as {
      lobbyId: string;
      code: string;
    };
    expect(result.lobbyId).toBe("lobby-abc");
    expect(result.code).toMatch(/^[A-Z0-9]{6}$/);
  });

  test("writes lobby doc + host player record", async () => {
    await handler(auth("host-42"));
    expect(lobbyDocSet).toHaveBeenCalledTimes(1);
    const lobbyData = lobbyDocSet.mock.calls[0][0];
    expect(lobbyData).toMatchObject({
      hostUid: "host-42",
      status: "waiting",
      rules: { startingLives: 3, durationSeconds: 600, immunitySeconds: 10 },
    });
    expect(lobbyData.code).toMatch(/^[A-Z0-9]{6}$/);
    expect(lobbyData.createdAt).toBeDefined();

    expect(playerDocSet).toHaveBeenCalledTimes(1);
    const playerData = playerDocSet.mock.calls[0][0];
    expect(playerData).toMatchObject({
      displayName: "Alice",
      livesRemaining: 3,
      status: "alive",
    });
    expect(playerData.embeddingSnapshot).toHaveLength(128);
    expect(playerData.joinedAt).toBeDefined();
  });

  test("retries when generated code collides with an active lobby", async () => {
    // First two checks find a collision, third is empty.
    codeQueryGet
      .mockResolvedValueOnce({ empty: false })
      .mockResolvedValueOnce({ empty: false })
      .mockResolvedValueOnce({ empty: true });
    const result = (await handler(auth("host-1"))) as { code: string };
    expect(codeQueryGet).toHaveBeenCalledTimes(3);
    expect(result.code).toMatch(/^[A-Z0-9]{6}$/);
    expect(lobbyDocSet).toHaveBeenCalledTimes(1);
  });

  test("fails after max retries", async () => {
    codeQueryGet.mockResolvedValue({ empty: false });
    await expect(handler(auth("host-1"))).rejects.toMatchObject({
      code: "resource-exhausted",
    });
    expect(lobbyDocSet).not.toHaveBeenCalled();
  });
});

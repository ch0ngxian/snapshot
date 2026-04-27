import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

import { generateLobbyCode } from "./lobbyCode";

interface CreateLobbyResult {
  lobbyId: string;
  code: string;
}

// Phase 1 lobby defaults (tech-plan §322). The configurable-rules UI lands
// in a follow-up; for now we bake defaults into the lobby doc so the rest
// of the round-lifecycle plumbing (startRound, immunity window, etc.) has
// a consistent shape to read from.
const DEFAULT_RULES = {
  startingLives: 3,
  durationSeconds: 600,
  immunitySeconds: 10,
} as const;

const MAX_CODE_RETRIES = 5;

/**
 * Per tech-plan §319 / §103: creates a lobby doc with a 6-char base36 code,
 * retrying on collision against any existing lobby in `waiting` or `active`
 * status (codes are recycled once the lobby ends). Also writes the host as
 * the first player, snapshotting their embedding from `users/{hostUid}` so
 * the tag check (Phase 2) can read all opponent embeddings via a single
 * subcollection query (§111).
 */
export const createLobby = onCall(
  { region: "asia-southeast1" },
  async (request: CallableRequest<unknown>): Promise<CreateLobbyResult> => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "createLobby requires an authenticated caller",
      );
    }
    const hostUid = request.auth.uid;
    const db = admin.firestore();

    const userSnap = await db.collection("users").doc(hostUid).get();
    if (!userSnap.exists) {
      throw new HttpsError(
        "failed-precondition",
        "user must complete onboarding before creating a lobby",
      );
    }
    const userData = userSnap.data()!;

    const code = await pickUniqueCode(db);

    const lobbiesRef = db.collection("lobbies");
    const lobbyRef = lobbiesRef.doc();
    const now = admin.firestore.FieldValue.serverTimestamp();

    await lobbyRef.set({
      code,
      hostUid,
      status: "waiting",
      rules: { ...DEFAULT_RULES },
      createdAt: now,
    });

    await lobbyRef
      .collection("players")
      .doc(hostUid)
      .set({
        displayName: userData.displayName,
        livesRemaining: DEFAULT_RULES.startingLives,
        status: "alive",
        joinedAt: now,
        embeddingSnapshot: userData.faceEmbedding,
        embeddingModelVersion: userData.embeddingModelVersion,
      });

    logger.info("lobby created", { lobbyId: lobbyRef.id, hostUid, code });
    return { lobbyId: lobbyRef.id, code };
  },
);

async function pickUniqueCode(db: admin.firestore.Firestore): Promise<string> {
  const lobbies = db.collection("lobbies");
  for (let attempt = 0; attempt < MAX_CODE_RETRIES; attempt++) {
    const candidate = generateLobbyCode();
    const collision = await lobbies
      .where("code", "==", candidate)
      .where("status", "in", ["waiting", "active"])
      .limit(1)
      .get();
    if (collision.empty) return candidate;
    logger.warn("lobby code collision, retrying", { candidate, attempt });
  }
  throw new HttpsError(
    "resource-exhausted",
    "failed to allocate a unique lobby code; try again",
  );
}

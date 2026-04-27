import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

import { buildPlayerDoc, requireOnboardedCaller } from "./lobbyAuth";
import { generateLobbyCode } from "./lobbyCode";

interface CreateLobbyResult {
  lobbyId: string;
  code: string;
}

const DEFAULT_RULES = {
  startingLives: 3,
  durationSeconds: 600,
  immunitySeconds: 10,
} as const;

const MAX_CODE_RETRIES = 5;

/**
 * Per tech-plan §319 / §103: creates a lobby doc with a 6-char base36 code,
 * retrying on collision against any existing lobby in `waiting` or `active`
 * status. Also writes the host as the first player.
 */
export const createLobby = onCall(
  // Explicit region in addition to the global default in index.ts. The
  // Flutter client hard-codes `asia-southeast1`; pinning per-function
  // removes any risk of a region split-brain if module-load ordering of
  // setGlobalOptions changes.
  { region: "asia-southeast1" },
  async (request: CallableRequest<unknown>): Promise<CreateLobbyResult> => {
    const db = admin.firestore();
    const { uid: hostUid, user } = await requireOnboardedCaller(request, db);

    const code = await pickUniqueCode(db);
    const lobbyRef = db.collection("lobbies").doc();
    const now = admin.firestore.FieldValue.serverTimestamp();

    await Promise.all([
      lobbyRef.set({
        code,
        hostUid,
        status: "waiting",
        rules: { ...DEFAULT_RULES },
        createdAt: now,
      }),
      lobbyRef
        .collection("players")
        .doc(hostUid)
        .set(buildPlayerDoc(user, DEFAULT_RULES.startingLives)),
    ]);

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

import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

interface JoinLobbyRequest {
  code?: string;
}

interface JoinLobbyResult {
  lobbyId: string;
}

const CODE_PATTERN = /^[A-Z0-9]{6}$/;

// Caps the player count to keep `submitTag`'s opponent fan-in bounded
// (tech-plan §111, §125 — ≤20 players per lobby).
const MAX_PLAYERS = 20;

// Default starting lives (tech-plan §322). `joinLobby` reads from the
// lobby doc rather than a hardcoded default so a host who tweaks rules in
// a follow-up PR doesn't need a function deploy. Falls back to this
// constant only if the lobby doc is missing the field.
const FALLBACK_STARTING_LIVES = 3;

/**
 * Per tech-plan §319/§321: looks up a lobby by its 6-char code and adds the
 * caller as a player. Idempotent — re-running on a code the caller already
 * joined returns the same lobbyId without rewriting the player doc (so a
 * double-tap on the QR scanner doesn't reset their lives).
 *
 * Embedding is snapshotted from `users/{uid}` at join time (§111) so the
 * Phase 2 tag check reads opponents in a single subcollection query rather
 * than fanning out across `users/*`.
 */
export const joinLobby = onCall(
  { region: "asia-southeast1" },
  async (request: CallableRequest<JoinLobbyRequest>): Promise<JoinLobbyResult> => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "joinLobby requires an authenticated caller",
      );
    }
    const uid = request.auth.uid;
    const rawCode = (request.data?.code ?? "").trim().toUpperCase();
    if (!CODE_PATTERN.test(rawCode)) {
      throw new HttpsError(
        "invalid-argument",
        "code must be 6 characters (A-Z, 0-9)",
      );
    }

    const db = admin.firestore();
    const userSnap = await db.collection("users").doc(uid).get();
    if (!userSnap.exists) {
      throw new HttpsError(
        "failed-precondition",
        "user must complete onboarding before joining a lobby",
      );
    }
    const user = userSnap.data()!;

    const matches = await db
      .collection("lobbies")
      .where("code", "==", rawCode)
      .where("status", "==", "waiting")
      .limit(1)
      .get();
    if (matches.empty) {
      throw new HttpsError(
        "not-found",
        "no waiting lobby with that code (it may have started or ended)",
      );
    }
    const lobbyDoc = matches.docs[0];
    const lobbyRef = lobbyDoc.ref;
    const lobbyId = lobbyDoc.id;

    const existing = await lobbyRef.collection("players").doc(uid).get();
    if (existing.exists) {
      logger.info("joinLobby idempotent — caller already a player", {
        lobbyId,
        uid,
      });
      return { lobbyId };
    }

    const players = await lobbyRef.collection("players").get();
    if (players.size >= MAX_PLAYERS) {
      throw new HttpsError("resource-exhausted", "lobby is full");
    }

    const lobbyData = lobbyDoc.data() as {
      rules?: { startingLives?: number };
    };
    const startingLives =
      lobbyData.rules?.startingLives ?? FALLBACK_STARTING_LIVES;

    await lobbyRef
      .collection("players")
      .doc(uid)
      .set({
        displayName: user.displayName,
        livesRemaining: startingLives,
        status: "alive",
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
        embeddingSnapshot: user.faceEmbedding,
        embeddingModelVersion: user.embeddingModelVersion,
      });

    logger.info("player joined lobby", { lobbyId, uid });
    return { lobbyId };
  },
);

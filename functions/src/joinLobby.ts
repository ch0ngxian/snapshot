import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

import { buildPlayerDoc, requireOnboardedCaller } from "./lobbyAuth";

interface JoinLobbyRequest {
  code?: string;
}

interface JoinLobbyResult {
  lobbyId: string;
}

const CODE_PATTERN = /^[A-Z0-9]{6}$/;

// Caps the player count so `submitTag`'s opponent fan-in stays bounded
// (tech-plan §111, §125 — ≤20 players per lobby).
const MAX_PLAYERS = 20;

/**
 * Per tech-plan §319/§321: looks up a lobby by its 6-char code and adds the
 * caller as a player. Idempotent — re-running on a code the caller already
 * joined returns the same lobbyId without rewriting the player doc.
 *
 * NOTE: cap + existing-player check are read-then-write rather than
 * transactional. At v1 friends/family scale (≤20-player parties, no
 * concurrent-join contention) the race is theoretical; tightening to a
 * proper transaction is tracked under Phase 3 hardening (§336).
 */
export const joinLobby = onCall(
  { region: "asia-southeast1" },
  async (request: CallableRequest<JoinLobbyRequest>): Promise<JoinLobbyResult> => {
    const rawCode = (request.data?.code ?? "").trim().toUpperCase();
    if (!CODE_PATTERN.test(rawCode)) {
      throw new HttpsError(
        "invalid-argument",
        "code must be 6 characters (A-Z, 0-9)",
      );
    }

    const db = admin.firestore();
    const [{ uid, user }, matches] = await Promise.all([
      requireOnboardedCaller(request, db),
      db
        .collection("lobbies")
        .where("code", "==", rawCode)
        .where("status", "==", "waiting")
        .limit(1)
        .get(),
    ]);

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

    const startingLives = (lobbyDoc.data() as {
      rules: { startingLives: number };
    }).rules.startingLives;

    await lobbyRef
      .collection("players")
      .doc(uid)
      .set(buildPlayerDoc(user, startingLives));

    logger.info("player joined lobby", { lobbyId, uid });
    return { lobbyId };
  },
);

import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

interface StartRoundRules {
  startingLives?: unknown;
  durationSeconds?: unknown;
  immunitySeconds?: unknown;
}

interface StartRoundRequest {
  lobbyId?: string;
  rules?: StartRoundRules;
}

interface StartRoundResult {
  ok: true;
}

interface NormalizedRules {
  startingLives: number;
  durationSeconds: number;
  immunitySeconds: number;
}

// Validation ranges. Tech-plan §322 only fixes the defaults (3 lives /
// 10 min / 10s); the bounds below are picked to keep the host UI's
// stepper from generating values that'd make the round nonsensical
// (zero-duration rounds, hour-long immunity, etc.).
const MIN_LIVES = 1;
const MAX_LIVES = 5;
const MIN_DURATION_SECONDS = 60; // 1 min
const MAX_DURATION_SECONDS = 1800; // 30 min
const MIN_IMMUNITY_SECONDS = 0;
const MAX_IMMUNITY_SECONDS = 60;
const MIN_PLAYERS_TO_START = 2;

const DEFAULT_RULES: NormalizedRules = {
  startingLives: 3,
  durationSeconds: 600,
  immunitySeconds: 10,
};

/**
 * Per tech-plan §323: host-only transition that flips a `waiting` lobby to
 * `active`, stamps `startedAt`, and writes the host's chosen rules. Resets
 * `livesRemaining` on every player to `rules.startingLives` — players were
 * stamped with `livesRemaining = startingLives` at join time, but the host
 * may have changed `startingLives` in the rules editor since then, so the
 * pre-existing values would be stale.
 *
 * "Locks the player list" is implicit: `joinLobby` only matches lobbies in
 * `waiting` status, so the moment we flip to `active` no new joiners can
 * enter (tech-plan §323).
 */
export const startRound = onCall(
  { region: "asia-southeast1" },
  async (
    request: CallableRequest<StartRoundRequest>,
  ): Promise<StartRoundResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "authenticated caller required");
    }
    const callerUid = request.auth.uid;
    const lobbyId = (request.data?.lobbyId ?? "").trim();
    if (!lobbyId) {
      throw new HttpsError("invalid-argument", "lobbyId required");
    }
    const rules = parseRules(request.data?.rules);

    const db = admin.firestore();
    const lobbyRef = db.collection("lobbies").doc(lobbyId);

    await db.runTransaction(async (tx) => {
      const lobbySnap = await tx.get(lobbyRef);
      if (!lobbySnap.exists) {
        throw new HttpsError("not-found", "lobby does not exist");
      }
      const lobby = lobbySnap.data() as { hostUid: string; status: string };
      if (lobby.hostUid !== callerUid) {
        throw new HttpsError(
          "permission-denied",
          "only the host can start the round",
        );
      }
      if (lobby.status !== "waiting") {
        throw new HttpsError(
          "failed-precondition",
          `lobby status is ${lobby.status}, expected waiting`,
        );
      }
      const players = await tx.get(lobbyRef.collection("players"));
      if (players.size < MIN_PLAYERS_TO_START) {
        throw new HttpsError(
          "failed-precondition",
          "need at least 2 players to start",
        );
      }

      tx.update(lobbyRef, {
        status: "active",
        rules,
        startedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      for (const p of players.docs) {
        tx.update(p.ref, { livesRemaining: rules.startingLives });
      }
    });

    logger.info("round started", { lobbyId, hostUid: callerUid, rules });
    return { ok: true };
  },
);

function parseRules(raw: StartRoundRules | undefined): NormalizedRules {
  return {
    startingLives: clampInteger(
      raw?.startingLives,
      MIN_LIVES,
      MAX_LIVES,
      DEFAULT_RULES.startingLives,
      "startingLives",
    ),
    durationSeconds: clampInteger(
      raw?.durationSeconds,
      MIN_DURATION_SECONDS,
      MAX_DURATION_SECONDS,
      DEFAULT_RULES.durationSeconds,
      "durationSeconds",
    ),
    immunitySeconds: clampInteger(
      raw?.immunitySeconds,
      MIN_IMMUNITY_SECONDS,
      MAX_IMMUNITY_SECONDS,
      DEFAULT_RULES.immunitySeconds,
      "immunitySeconds",
    ),
  };
}

function clampInteger(
  value: unknown,
  min: number,
  max: number,
  fallback: number,
  name: string,
): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new HttpsError("invalid-argument", `${name} must be an integer`);
  }
  if (value < min || value > max) {
    throw new HttpsError(
      "invalid-argument",
      `${name} must be in [${min}, ${max}]`,
    );
  }
  return value;
}

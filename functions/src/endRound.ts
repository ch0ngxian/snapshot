import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

interface EndRoundRequest {
  lobbyId?: string;
}

interface EndRoundResult {
  ok: true;
  alreadyEnded: boolean;
}

/**
 * Per tech-plan §324: flips an `active` lobby to `ended` and stamps
 * `endedAt`. Idempotent — calling on a lobby that's already `ended` is a
 * no-op. Any player in the lobby may call this; the round timer expires
 * on every client at roughly the same time and they all race to call,
 * so the transaction has to be safe under concurrent end-attempts.
 *
 * Last-one-alive end is tech-plan §324 too but lives next to `submitTag`
 * (Phase 2, §326) — the elimination transaction can detect "0 alive
 * opponents remain" and trigger the same status flip.
 */
export const endRound = onCall(
  { region: "asia-southeast1" },
  async (
    request: CallableRequest<EndRoundRequest>,
  ): Promise<EndRoundResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "authenticated caller required");
    }
    const callerUid = request.auth.uid;
    const lobbyId = (request.data?.lobbyId ?? "").trim();
    if (!lobbyId) {
      throw new HttpsError("invalid-argument", "lobbyId required");
    }

    const db = admin.firestore();
    const lobbyRef = db.collection("lobbies").doc(lobbyId);

    const result = await db.runTransaction(async (tx) => {
      const lobbySnap = await tx.get(lobbyRef);
      if (!lobbySnap.exists) {
        throw new HttpsError("not-found", "lobby does not exist");
      }
      const lobby = lobbySnap.data() as { status: string };

      const playerSnap = await tx.get(
        lobbyRef.collection("players").doc(callerUid),
      );
      if (!playerSnap.exists) {
        throw new HttpsError(
          "permission-denied",
          "only players in this lobby can end it",
        );
      }

      if (lobby.status === "ended") {
        return { alreadyEnded: true };
      }
      if (lobby.status !== "active") {
        throw new HttpsError(
          "failed-precondition",
          `lobby status is ${lobby.status}, expected active`,
        );
      }
      tx.update(lobbyRef, {
        status: "ended",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { alreadyEnded: false };
    });

    logger.info("round ended", { lobbyId, callerUid, ...result });
    return { ok: true, alreadyEnded: result.alreadyEnded };
  },
);

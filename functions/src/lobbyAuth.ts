import * as admin from "firebase-admin";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

export interface OnboardedCaller {
  uid: string;
  user: admin.firestore.DocumentData;
}

/**
 * Asserts the caller is authenticated and has a `users/{uid}` profile,
 * returning both. Used by lobby callables that need to snapshot the
 * caller's display name + face embedding into the lobby (tech-plan §111).
 */
export async function requireOnboardedCaller(
  request: CallableRequest<unknown>,
  db: admin.firestore.Firestore,
): Promise<OnboardedCaller> {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "authenticated caller required");
  }
  const uid = request.auth.uid;
  const snap = await db.collection("users").doc(uid).get();
  if (!snap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "user must complete onboarding first",
    );
  }
  return { uid, user: snap.data()! };
}

/**
 * Builds the `lobbies/{lobbyId}/players/{uid}` payload from a user profile,
 * snapshotting their embedding so the tag check (Phase 2) reads opponents
 * via a single subcollection query (§111).
 */
export function buildPlayerDoc(
  user: admin.firestore.DocumentData,
  startingLives: number,
): Record<string, unknown> {
  return {
    displayName: user.displayName,
    livesRemaining: startingLives,
    status: "alive",
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    embeddingSnapshot: user.faceEmbedding,
    embeddingModelVersion: user.embeddingModelVersion,
  };
}

import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

import { cosineSimilarity } from "./cosine";
import { loadTagThresholds } from "./tagThresholds";

interface SubmitTagRequest {
  lobbyId?: string;
  tagId?: string;
  embedding?: unknown;
  modelVersion?: string;
}

export type SubmitTagResultKind =
  | "hit"
  | "no_match"
  | "immune"
  | "cooldown";

export interface SubmitTagResult {
  result: SubmitTagResultKind;
  retainPhoto: boolean;
  tagId: string;
  victimLivesRemaining?: number;
  eliminated?: boolean;
}

const EMBEDDING_DIM = 128;
const COOLDOWN_MS = 5_000;

interface PlayerSnapshot {
  uid: string;
  livesRemaining: number;
  status: string;
  embeddingSnapshot: number[];
  lastTaggedAt?: { toMillis: () => number };
}

/**
 * Per tech-plan §326: server-authoritative tag verification. Reads
 * `tag_match_threshold` and `borderline_half_width` from Remote Config
 * (60s cache), runs cosine similarity against alive opponents, atomically
 * decrements the victim's lives if the top match clears the threshold,
 * ends the round when only one player remains, and records the attempt
 * (incl. `top3Distances`) so the threshold can be re-tuned from logged
 * data per §5.8.
 *
 * The schema in §3 names the winning score `topMatchDistance` — that's a
 * misnomer; the value here is a cosine *similarity* (higher = closer
 * match). The naming is preserved on the wire for plan compatibility.
 *
 * Idempotency: the client supplies `tagId` and a replay returns the
 * persisted verdict without re-running the comparison. Cooldowns and
 * post-hit immunity are enforced server-side.
 *
 * FCM emission to the victim is best-effort: when no `users/{uid}.fcmToken`
 * is registered yet, the function logs and continues. Client-side token
 * registration lands alongside the round UI in PR-B.
 */
export const submitTag = onCall(
  { region: "asia-southeast1" },
  async (
    request: CallableRequest<SubmitTagRequest>,
  ): Promise<SubmitTagResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "authenticated caller required");
    }
    const callerUid = request.auth.uid;
    const { lobbyId, tagId, embedding, modelVersion } = parseInput(request.data);

    const db = admin.firestore();
    const lobbyRef = db.collection("lobbies").doc(lobbyId);
    const tagRef = lobbyRef.collection("tags").doc(tagId);

    // Idempotent replay (outside tx — single doc read; verdict is immutable
    // once written). Validate caller owns the tagId; otherwise a malicious
    // client could probe other players' tag outcomes by guessing tagIds.
    const existingTag = await tagRef.get();
    if (existingTag.exists) {
      const data = existingTag.data() as Record<string, unknown>;
      if (data.taggerUid !== callerUid) {
        throw new HttpsError(
          "permission-denied",
          "tagId belongs to a different caller",
        );
      }
      return replayVerdict(data, tagId);
    }

    const { threshold, halfWidth } = await loadTagThresholds();

    const txOutcome = await db.runTransaction(async (tx) => {
      const lobbySnap = await tx.get(lobbyRef);
      if (!lobbySnap.exists) {
        throw new HttpsError("not-found", "lobby does not exist");
      }
      const lobby = lobbySnap.data() as {
        status: string;
        rules?: { immunitySeconds?: number };
      };
      if (lobby.status !== "active") {
        throw new HttpsError(
          "failed-precondition",
          `lobby status is ${lobby.status}, expected active`,
        );
      }
      const immunitySeconds = lobby.rules?.immunitySeconds ?? 10;

      const callerRef = lobbyRef.collection("players").doc(callerUid);
      const callerSnap = await tx.get(callerRef);
      if (!callerSnap.exists) {
        throw new HttpsError(
          "permission-denied",
          "caller is not a player in this lobby",
        );
      }
      const caller = callerSnap.data() as Record<string, unknown>;
      if (caller.status !== "alive") {
        throw new HttpsError(
          "failed-precondition",
          "eliminated players cannot tag",
        );
      }
      if (caller.embeddingModelVersion !== modelVersion) {
        throw new HttpsError(
          "failed-precondition",
          `modelVersion ${modelVersion} does not match player snapshot ${caller.embeddingModelVersion}`,
        );
      }

      const now = Date.now();
      const lastAttempt = (caller.lastTagAttemptAt as
        | { toMillis: () => number }
        | null
        | undefined)?.toMillis();
      if (lastAttempt && now - lastAttempt < COOLDOWN_MS) {
        // Cooldown is a verdict — record it and return without comparing.
        const tagDoc = {
          taggerUid: callerUid,
          resolvedTargetUid: null,
          topMatchDistance: null,
          top3Distances: [],
          accepted: false,
          rejectReason: "cooldown",
          photoStorageRef: "discarded",
          modelVersion,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          result: "cooldown" as const,
          retainPhoto: false,
        };
        tx.set(tagRef, tagDoc);
        // Do not bump lastTagAttemptAt on cooldown — that would extend the
        // window indefinitely if a client hammers the shutter. Cooldown is
        // measured against the prior accepted attempt.
        return {
          result: "cooldown" as const,
          retainPhoto: false,
        };
      }

      // Load alive opponents in one query.
      const aliveQuery = lobbyRef
        .collection("players")
        .where("status", "==", "alive");
      // Tag the query so the test harness can route it deterministically.
      (aliveQuery as unknown as { _isAliveQuery: boolean })._isAliveQuery = true;
      const aliveSnap = await tx.get(aliveQuery);

      const opponents: PlayerSnapshot[] = aliveSnap.docs
        .filter((d) => d.id !== callerUid)
        .map((d) => {
          const data = d.data() as Record<string, unknown>;
          return {
            uid: d.id,
            livesRemaining: data.livesRemaining as number,
            status: data.status as string,
            embeddingSnapshot: toNumberArray(data.embeddingSnapshot),
            lastTaggedAt: data.lastTaggedAt as
              | { toMillis: () => number }
              | undefined,
          };
        });

      const ranked = rankByCosine(embedding, opponents);
      const topMatch = ranked[0];
      const top3Distances = ranked.slice(0, 3).map((r) => r.similarity);

      const baseTagDoc = {
        taggerUid: callerUid,
        modelVersion,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        top3Distances,
        topMatchDistance: topMatch?.similarity ?? null,
      };

      // No opponents to compare against — treat as no_match.
      if (!topMatch) {
        const tagDoc = {
          ...baseTagDoc,
          resolvedTargetUid: null,
          accepted: false,
          rejectReason: "no_opponents",
          photoStorageRef: "discarded",
          result: "no_match" as const,
          retainPhoto: false,
        };
        tx.set(tagRef, tagDoc);
        tx.update(callerRef, {
          lastTagAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { result: "no_match" as const, retainPhoto: false };
      }

      // Immunity check on the top-match's lastTaggedAt.
      const immuneUntil = topMatch.player.lastTaggedAt
        ? topMatch.player.lastTaggedAt.toMillis() + immunitySeconds * 1000
        : 0;
      const isImmune = immuneUntil > now;

      const passesThreshold = topMatch.similarity >= threshold;
      const retainPhoto =
        Math.abs(topMatch.similarity - threshold) < halfWidth;

      if (isImmune) {
        const tagDoc = {
          ...baseTagDoc,
          resolvedTargetUid: topMatch.player.uid,
          accepted: false,
          rejectReason: "immune",
          // Immunity is not a "system was unsure" case — the model
          // confidently picked someone who can't be tagged right now.
          // Photo is discarded regardless of the borderline band.
          photoStorageRef: "discarded",
          result: "immune" as const,
          retainPhoto: false,
        };
        tx.set(tagRef, tagDoc);
        tx.update(callerRef, {
          lastTagAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { result: "immune" as const, retainPhoto: false };
      }

      if (!passesThreshold) {
        const tagDoc = {
          ...baseTagDoc,
          resolvedTargetUid: topMatch.player.uid,
          accepted: false,
          rejectReason: "below_threshold",
          photoStorageRef: retainPhoto ? null : "discarded",
          result: "no_match" as const,
          retainPhoto,
        };
        tx.set(tagRef, tagDoc);
        tx.update(callerRef, {
          lastTagAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { result: "no_match" as const, retainPhoto };
      }

      // Hit. Decrement victim lives, eliminate at 0, end round if only
      // the tagger remains alive.
      const newLives = Math.max(0, topMatch.player.livesRemaining - 1);
      const eliminated = newLives === 0;
      const victimRef = lobbyRef.collection("players").doc(topMatch.player.uid);

      const victimUpdate: Record<string, unknown> = {
        livesRemaining: newLives,
        lastTaggedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (eliminated) victimUpdate.status = "eliminated";
      tx.update(victimRef, victimUpdate);

      tx.update(callerRef, {
        lastTagAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const tagDoc = {
        ...baseTagDoc,
        resolvedTargetUid: topMatch.player.uid,
        accepted: true,
        photoStorageRef: retainPhoto ? null : "discarded",
        result: "hit" as const,
        retainPhoto,
        victimLivesRemaining: newLives,
        eliminated,
      };
      tx.set(tagRef, tagDoc);

      // End round when ≤1 alive remains. opponents.length is the
      // alive-opponent count BEFORE elimination; if eliminating one drops
      // it to 0, only the tagger is alive.
      if (eliminated && opponents.length <= 1) {
        tx.update(lobbyRef, {
          status: "ended",
          endedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      return {
        result: "hit" as const,
        retainPhoto,
        victimUid: topMatch.player.uid,
        victimLivesRemaining: newLives,
        eliminated,
      };
    });

    // Best-effort FCM after the transaction commits. Skipped silently when
    // no token is registered for the victim yet (client registration lands
    // in PR-B alongside the round UI).
    if (txOutcome.result === "hit" && "victimUid" in txOutcome) {
      await sendTagPush(callerUid, txOutcome.victimUid as string).catch((err) =>
        logger.warn("submitTag: FCM emit failed", {
          error: (err as Error).message,
          victimUid: (txOutcome as { victimUid: string }).victimUid,
        }),
      );
    }

    logger.info("submitTag complete", {
      lobbyId,
      tagId,
      callerUid,
      result: txOutcome.result,
      retainPhoto: txOutcome.retainPhoto,
    });

    const out: SubmitTagResult = {
      result: txOutcome.result,
      retainPhoto: txOutcome.retainPhoto,
      tagId,
    };
    if ("victimLivesRemaining" in txOutcome) {
      out.victimLivesRemaining = txOutcome.victimLivesRemaining as number;
    }
    if ("eliminated" in txOutcome) {
      out.eliminated = txOutcome.eliminated as boolean;
    }
    return out;
  },
);

function parseInput(data: SubmitTagRequest | undefined): {
  lobbyId: string;
  tagId: string;
  embedding: number[];
  modelVersion: string;
} {
  const lobbyId = (data?.lobbyId ?? "").trim();
  const tagId = (data?.tagId ?? "").trim();
  const modelVersion = (data?.modelVersion ?? "").trim();
  if (!lobbyId) throw new HttpsError("invalid-argument", "lobbyId required");
  if (!tagId) throw new HttpsError("invalid-argument", "tagId required");
  if (!modelVersion)
    throw new HttpsError("invalid-argument", "modelVersion required");
  if (!Array.isArray(data?.embedding)) {
    throw new HttpsError("invalid-argument", "embedding must be an array");
  }
  if (data!.embedding.length !== EMBEDDING_DIM) {
    throw new HttpsError(
      "invalid-argument",
      `embedding must have length ${EMBEDDING_DIM}`,
    );
  }
  const embedding = data!.embedding as unknown[];
  for (let i = 0; i < embedding.length; i++) {
    const v = embedding[i];
    if (typeof v !== "number" || !Number.isFinite(v)) {
      throw new HttpsError(
        "invalid-argument",
        `embedding[${i}] must be a finite number`,
      );
    }
  }
  return {
    lobbyId,
    tagId,
    embedding: embedding as number[],
    modelVersion,
  };
}

function toNumberArray(value: unknown): number[] {
  if (!Array.isArray(value)) return [];
  const out: number[] = [];
  for (const v of value) {
    if (typeof v === "number" && Number.isFinite(v)) out.push(v);
  }
  return out;
}

interface RankedMatch {
  player: PlayerSnapshot;
  similarity: number;
}

function rankByCosine(
  embedding: number[],
  opponents: PlayerSnapshot[],
): RankedMatch[] {
  return opponents
    .filter((p) => p.embeddingSnapshot.length === embedding.length)
    .map((p) => ({
      player: p,
      similarity: cosineSimilarity(embedding, p.embeddingSnapshot),
    }))
    .sort((a, b) => b.similarity - a.similarity);
}

function replayVerdict(
  data: Record<string, unknown>,
  tagId: string,
): SubmitTagResult {
  const out: SubmitTagResult = {
    result: data.result as SubmitTagResultKind,
    retainPhoto: Boolean(data.retainPhoto),
    tagId,
  };
  if (typeof data.victimLivesRemaining === "number") {
    out.victimLivesRemaining = data.victimLivesRemaining;
  }
  if (typeof data.eliminated === "boolean") {
    out.eliminated = data.eliminated;
  }
  return out;
}

async function sendTagPush(taggerUid: string, victimUid: string): Promise<void> {
  const userDoc = await admin.firestore().collection("users").doc(victimUid).get();
  const tokenRaw = userDoc.exists ? userDoc.data()?.fcmToken : undefined;
  if (typeof tokenRaw !== "string" || tokenRaw.length === 0) {
    logger.info("submitTag: skipping FCM (no token registered for victim)", {
      victimUid,
    });
    return;
  }
  const tagger = await admin.firestore().collection("users").doc(taggerUid).get();
  const taggerName = (tagger.data()?.displayName as string | undefined) ??
    "Someone";
  await admin.messaging().send({
    token: tokenRaw,
    notification: {
      title: "You were tagged!",
      body: `${taggerName} just photographed you.`,
    },
    data: { type: "tag", taggerUid },
  });
}

import * as admin from "firebase-admin";
import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions";

interface DeleteUserDataResult {
  uid: string;
  userDocDeleted: boolean;
  selfieDeleted: boolean;
  tagPhotosCleared: number;
}

/**
 * Per tech-plan.md §5.10: deletes the user's profile + selfie, scrubs photos
 * in tag records where the user was the resolved target, and leaves the tag
 * docs in place (so the anonymous distance data stays useful for tuning).
 *
 * Callable from the Flutter client via FirebaseFunctions.httpsCallable.
 *
 * Behavior:
 *   1. Deletes users/{uid}.
 *   2. Deletes selfies/{uid}.jpg from Cloud Storage (best-effort).
 *   3. Collection-group query on `tags` where resolvedTargetUid == uid:
 *      for each match, delete the photo at tags/{lobbyId}/{tagId}.jpg from
 *      Storage (if any) and set photoStorageRef = null on the tag doc.
 *   4. The 30-day Storage lifecycle rule on `tags/` is the backstop for
 *      anything missed (e.g. a tag photo created after the delete call but
 *      before account creation could even matter — not a real case, but the
 *      backstop still applies).
 */
export const deleteUserData = onCall(
  async (request: CallableRequest<unknown>): Promise<DeleteUserDataResult> => {
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "deleteUserData requires an authenticated caller",
      );
    }
    const uid = request.auth.uid;
    const db = admin.firestore();
    const bucket = admin.storage().bucket();

    logger.info("deleteUserData starting", { uid });

    let userDocDeleted = false;
    try {
      await db.doc(`users/${uid}`).delete();
      userDocDeleted = true;
    } catch (err) {
      logger.error("failed to delete user doc", { uid, err });
    }

    let selfieDeleted = false;
    try {
      await bucket.file(`selfies/${uid}.jpg`).delete({ ignoreNotFound: true });
      selfieDeleted = true;
    } catch (err) {
      logger.error("failed to delete selfie", { uid, err });
    }

    let tagPhotosCleared = 0;
    try {
      const tagDocs = await db
        .collectionGroup("tags")
        .where("resolvedTargetUid", "==", uid)
        .get();

      const writes: Promise<unknown>[] = [];
      for (const doc of tagDocs.docs) {
        const ref = doc.data().photoStorageRef as string | null | undefined;
        if (typeof ref === "string" && ref.startsWith("tags/")) {
          writes.push(
            bucket
              .file(ref)
              .delete({ ignoreNotFound: true })
              .catch((err) => {
                logger.warn("failed to delete tag photo", { uid, ref, err });
              }),
          );
        }
        writes.push(doc.ref.update({ photoStorageRef: null }));
        tagPhotosCleared += 1;
      }
      await Promise.all(writes);
    } catch (err) {
      logger.error("failed during tag-photo scrub", { uid, err });
    }

    logger.info("deleteUserData done", {
      uid,
      userDocDeleted,
      selfieDeleted,
      tagPhotosCleared,
    });

    return { uid, userDocDeleted, selfieDeleted, tagPhotosCleared };
  },
);

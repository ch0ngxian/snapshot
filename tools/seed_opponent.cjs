#!/usr/bin/env node

const { randomUUID } = require("node:crypto");
const { execFileSync } = require("node:child_process");
const { readFileSync, unlinkSync } = require("node:fs");
const { readFile } = require("node:fs/promises");
const os = require("node:os");
const { dirname, resolve } = require("node:path");
const { parseArgs } = require("node:util");

let admin;
try {
  // Reuse the Functions dependency tree so this script stays runnable from the
  // repo root without introducing a second package.json just for tooling.
  admin = require("../functions/node_modules/firebase-admin");
} catch (error) {
  console.error(
    "Missing functions dependencies. Run `cd functions && npm install` first.",
  );
  throw error;
}

const DEFAULT_PROJECT_ID = "cx-snapshot";
const DEFAULT_DISPLAY_NAME = "Seed Opponent";
const ALLOWED_LOBBY_STATUSES = new Set(["waiting", "active"]);
const DEFAULT_FLUTTER_BIN = process.env.SNAPSHOT_FLUTTER_BIN || "flutter";
const REPO_ROOT = resolve(dirname(__filename), "..");

function printUsage() {
  console.log(
    [
      "Usage:",
      "  node tools/seed_opponent.cjs (--lobby-id <lobbyId> | --code <code>) [options]",
      "",
      "Seeds a fake alive player into lobbies/{lobbyId}/players/{fakeUid} and",
      "creates the matching users/{fakeUid} profile by cloning an existing",
      "user's embedding. With no --clone-from-uid, it defaults to the lobby",
      "host, which is the fastest single-device self-tag setup.",
      "",
      "Options:",
      "  --lobby-id <id>            Firestore lobby document ID.",
      "  --code <code>              6-character lobby code from the phone UI.",
      "  --clone-from-uid <uid>     Source user whose embedding is copied.",
      "  --face-photo <path>        Seed from a local portrait/headshot instead",
      "                             of an existing Firestore user.",
      "  --crop <l,t,w,h>           Optional manual crop for --face-photo.",
      "  --display-name <name>      Fake player's display name.",
      "                             Default: Seed Opponent",
      "  --fake-uid <uid>           Explicit uid for the fake player.",
      "  --project-id <id>          Firebase project ID.",
      `                             Default: ${DEFAULT_PROJECT_ID}`,
      "  --service-account <path>   Service-account JSON file. Optional if",
      "                             GOOGLE_APPLICATION_CREDENTIALS or",
      "                             gcloud ADC is already configured.",
      "  -h, --help                 Show this help.",
      "",
      "Auth:",
      "  For production Firestore, use one of:",
      "  - gcloud auth application-default login",
      "  - export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/service-account.json",
      "  - pass --service-account /abs/path/service-account.json",
      "",
      "Examples:",
      "  node tools/seed_opponent.cjs --code K4Z9Q1",
      "  node tools/seed_opponent.cjs --lobby-id abc123 --display-name Dummy",
      "  node tools/seed_opponent.cjs --code K4Z9Q1 --clone-from-uid realUid",
      "  node tools/seed_opponent.cjs --code K4Z9Q1 --face-photo ./ada.jpg",
    ].join("\n"),
  );
}

function fail(message) {
  throw new Error(message);
}

async function loadCredential(serviceAccountPath) {
  const raw = await readFile(resolve(serviceAccountPath), "utf8");
  return admin.credential.cert(JSON.parse(raw));
}

function buildFakeUid(lobbyId) {
  return `seed-${lobbyId.slice(0, 6)}-${randomUUID().slice(0, 8)}`;
}

function isValidEmbedding(value) {
  return Array.isArray(value) && value.length === 128 && value.every((n) => typeof n === "number");
}

function parseCli() {
  const { values } = parseArgs({
    options: {
      code: { type: "string" },
      "clone-from-uid": { type: "string" },
      crop: { type: "string" },
      "display-name": { type: "string" },
      "face-photo": { type: "string" },
      "fake-uid": { type: "string" },
      help: { type: "boolean", short: "h" },
      "lobby-id": { type: "string" },
      "project-id": { type: "string" },
      "service-account": { type: "string" },
    },
    strict: true,
  });

  if (values.help) {
    printUsage();
    process.exit(0);
  }

  if (!values["lobby-id"] && !values.code) {
    printUsage();
    fail("pass either --lobby-id or --code");
  }

  if (values["lobby-id"] && values.code) {
    fail("pass only one of --lobby-id or --code");
  }
  if (values["clone-from-uid"] && values["face-photo"]) {
    fail("pass only one of --clone-from-uid or --face-photo");
  }
  if (values.crop && !values["face-photo"]) {
    fail("--crop is only valid together with --face-photo");
  }

  return {
    code: values.code?.trim().toUpperCase(),
    cloneFromUid: values["clone-from-uid"]?.trim(),
    crop: values.crop?.trim(),
    displayName: values["display-name"]?.trim() || DEFAULT_DISPLAY_NAME,
    facePhoto: values["face-photo"]?.trim(),
    fakeUid: values["fake-uid"]?.trim(),
    lobbyId: values["lobby-id"]?.trim(),
    projectId: values["project-id"]?.trim() || DEFAULT_PROJECT_ID,
    serviceAccount: values["service-account"]?.trim(),
  };
}

async function initFirestore(projectId, serviceAccountPath) {
  const isEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
  const options = { projectId };

  if (serviceAccountPath) {
    options.credential = await loadCredential(serviceAccountPath);
  } else if (!isEmulator) {
    options.credential = admin.credential.applicationDefault();
  }

  admin.initializeApp(options);
  return admin.firestore();
}

async function main() {
  const {
    code,
    cloneFromUid: cloneFromUidArg,
    crop,
    displayName,
    facePhoto,
    fakeUid: fakeUidArg,
    lobbyId,
    projectId,
    serviceAccount,
  } = parseCli();

  const db = await initFirestore(projectId, serviceAccount);
  const { lobbyId: resolvedLobbyId, lobbyRef, lobbySnap } = await resolveLobby({
    code,
    db,
    lobbyId,
  });
  const effectiveLobbyId = resolvedLobbyId;

  const lobby = lobbySnap.data() || {};
  const lobbyStatus = lobby.status;
  if (!ALLOWED_LOBBY_STATUSES.has(lobbyStatus)) {
    fail(
      `lobby ${effectiveLobbyId} has status ${String(lobbyStatus)}; expected waiting or active`,
    );
  }

  const cloneFromUid = facePhoto
    ? cloneFromUidArg || null
    : cloneFromUidArg || lobby.hostUid;
  if (!facePhoto && !cloneFromUid) {
    fail("could not infer source user; pass --clone-from-uid explicitly");
  }

  const fakeUid = fakeUidArg || buildFakeUid(effectiveLobbyId);
  if (cloneFromUid && fakeUid === cloneFromUid) {
    fail("fake uid must differ from clone-from uid");
  }

  const [fakeUserSnap, existingPlayerSnap] = await Promise.all([
    db.collection("users").doc(fakeUid).get(),
    lobbyRef.collection("players").doc(fakeUid).get(),
  ]);

  if (fakeUserSnap.exists) {
    fail(`users/${fakeUid} already exists; pass a different --fake-uid`);
  }
  if (existingPlayerSnap.exists) {
    fail(
      `lobbies/${effectiveLobbyId}/players/${fakeUid} already exists; pass a different --fake-uid`,
    );
  }

  const seed = facePhoto
    ? await seedFromFacePhoto(facePhoto, crop)
    : await seedFromExistingUser(db, cloneFromUid);

  const startingLives =
    typeof lobby.rules?.startingLives === "number" ? lobby.rules.startingLives : 3;
  const timestamp = admin.firestore.FieldValue.serverTimestamp();
  const batch = db.batch();

  batch.set(db.collection("users").doc(fakeUid), {
    createdAt: timestamp,
    displayName,
    embeddingModelVersion: seed.embeddingModelVersion,
    faceEmbedding: seed.faceEmbedding,
  });
  batch.set(lobbyRef.collection("players").doc(fakeUid), {
    displayName,
    embeddingModelVersion: seed.embeddingModelVersion,
    embeddingSnapshot: seed.faceEmbedding,
    joinedAt: timestamp,
    livesRemaining: startingLives,
    status: "alive",
  });

  await batch.commit();

  console.log(
    JSON.stringify(
      {
        displayName,
        fakeUid,
        lobbyCode: lobby.code || null,
        lobbyId: effectiveLobbyId,
        lobbyStatus,
        projectId,
        cloneFromUid,
        seedMode: seed.mode,
        seedSource: seed.source,
        startingLives,
      },
      null,
      2,
    ),
  );
  console.log("");
  console.log(
    seed.mode === "photo"
      ? "Seeded fake opponent from photo. Start the round, then tag that same person/photo on another screen."
      : "Seeded fake opponent. Start the round, then tag the same face as the cloned source user.",
  );
}

async function seedFromExistingUser(db, cloneFromUid) {
  const sourceUserSnap = await db.collection("users").doc(cloneFromUid).get();
  if (!sourceUserSnap.exists) {
    fail(`source user ${cloneFromUid} does not exist`);
  }

  const sourceUser = sourceUserSnap.data() || {};
  if (!isValidEmbedding(sourceUser.faceEmbedding)) {
    fail(
      `users/${cloneFromUid}.faceEmbedding is missing or not a 128-number array`,
    );
  }
  if (
    typeof sourceUser.embeddingModelVersion !== "string" ||
    sourceUser.embeddingModelVersion.length === 0
  ) {
    fail(
      `users/${cloneFromUid}.embeddingModelVersion is missing or invalid`,
    );
  }

  return {
    embeddingModelVersion: sourceUser.embeddingModelVersion,
    faceEmbedding: sourceUser.faceEmbedding,
    mode: "clone",
    source: cloneFromUid,
  };
}

async function seedFromFacePhoto(facePhoto, crop) {
  const outputPath = resolve(
    os.tmpdir(),
    `snapshot-seed-embedding-${randomUUID()}.json`,
  );
  const args = [
    "test",
    "tools/embed_face_test.dart",
    "--plain-name",
    "embed face tool",
  ];
  const env = {
    ...process.env,
    FLUTTER_SUPPRESS_ANALYTICS: "true",
    SNAPSHOT_EMBED_FACE_IMAGE: resolve(facePhoto),
    SNAPSHOT_EMBED_FACE_MODEL: resolve(
      REPO_ROOT,
      "assets/models/mobilefacenet.tflite",
    ),
    SNAPSHOT_EMBED_FACE_MODEL_VERSION: "mobilefacenet-v1",
    SNAPSHOT_EMBED_FACE_OUT: outputPath,
  };
  if (crop) {
    env.SNAPSHOT_EMBED_FACE_CROP = crop;
  }

  let raw;
  try {
    execFileSync(DEFAULT_FLUTTER_BIN, args, {
      cwd: REPO_ROOT,
      encoding: "utf8",
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    raw = readFileSync(outputPath, "utf8");
  } catch (error) {
    const stderr = error.stderr ? String(error.stderr).trim() : "";
    const stdout = error.stdout ? String(error.stdout).trim() : "";
    const logs = [stdout, stderr].filter(Boolean).join("\n");
    fail(
      `failed to embed --face-photo via Flutter (${DEFAULT_FLUTTER_BIN}).` +
        `${logs ? `\n${logs}` : ""}\n` +
        "If your machine has multiple Flutter installs, set SNAPSHOT_FLUTTER_BIN=/abs/path/to/flutter.",
    );
  } finally {
    try {
      unlinkSync(outputPath);
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    fail(`could not parse tools/embed_face_test.dart output as JSON:\n${raw}`);
  }

  if (!isValidEmbedding(parsed.embedding)) {
    fail("tools/embed_face_test.dart returned an invalid embedding");
  }
  if (
    typeof parsed.modelVersion !== "string" ||
    parsed.modelVersion.length === 0
  ) {
    fail("tools/embed_face_test.dart returned an invalid modelVersion");
  }

  return {
    embeddingModelVersion: parsed.modelVersion,
    faceEmbedding: parsed.embedding,
    mode: "photo",
    source: parsed.imagePath,
  };
}

async function resolveLobby({ code, db, lobbyId }) {
  if (lobbyId) {
    const lobbyRef = db.collection("lobbies").doc(lobbyId);
    const lobbySnap = await lobbyRef.get();
    if (!lobbySnap.exists) {
      fail(`lobby ${lobbyId} does not exist`);
    }
    return { lobbyId, lobbyRef, lobbySnap };
  }

  const matches = await db
    .collection("lobbies")
    .where("code", "==", code)
    .where("status", "in", Array.from(ALLOWED_LOBBY_STATUSES))
    .limit(2)
    .get();
  if (matches.empty) {
    fail(`no waiting or active lobby found for code ${code}`);
  }
  if (matches.size > 1) {
    fail(`multiple live lobbies found for code ${code}; pass --lobby-id explicitly`);
  }

  const lobbySnap = matches.docs[0];
  return {
    lobbyId: lobbySnap.id,
    lobbyRef: lobbySnap.ref,
    lobbySnap,
  };
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});

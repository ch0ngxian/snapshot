# Snapshot v1 — Status Overview

_Last updated: 2026-04-28_

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 — Foundations | Flutter scaffold, Firebase setup, FaceEmbedder (MobileFaceNet via TFLite), onboarding + consent, `deleteUserData` | ✅ shipped + deployed |
| 1 — Lobby lifecycle | `createLobby`, QR + 6-char code join, host waiting room, rules editor, `startRound`, round timer | ✅ shipped + deployed |
| 2 — Tag mechanic | In-round camera, `submitTag` (cosine, atomic life decrement, end-on-last-alive), scoreboard, FCM client, conditional photo upload, storage rules | ✅ shipped + deployed |
| 3 — Polish & hardening | See breakdown below | 🟡 in progress |

## Phase 3 detail

| Item | Status |
|---|---|
| Server-side cooldown (5s tagger) | ✅ in `submitTag` |
| Server-side immunity (10s post-hit) | ✅ in `submitTag` |
| Idempotency key on `submitTag` | ✅ in `submitTag` |
| Auto-rejoin lobby/round on app relaunch | ✅ shipped (PR #17) |
| Immersive viewfinder rebuild | 🟡 in progress (see breakdown below) |
| Host-disconnect auto-promote | ❌ TODO |
| Mutual elimination → tie (last 2 alive) | ❌ TODO |
| BigQuery view + threshold tuning script | ❌ TODO |
| Friends-family playtest | 🟡 solo verified; multi-device pending |
| Accuracy gate (false-accept rate at 0.65) | ❌ pending playtest data |
| Privacy policy | ❌ TODO (required before TestFlight) |
| TestFlight + Android internal track | ❌ TODO |

## Immersive viewfinder (per `GAMEPLAY.md`)

Replaces the `image_picker` shutter hand-off with a long-lived rear-camera preview + HUD overlay. 7-step ship order:

| Step | Scope | Status |
|---|---|---|
| 1 | Live `CameraPreview` + HUD layout (lives top-left, timer top-center, opponents top-right, shutter bottom-center) + bottom-half tap-to-fire zone + portrait lock + `RoundCamera` lifecycle abstraction | ✅ shipped (PR #21) |
| 2 | Cooldown ring around the shutter + haptics + timer urgency ramp (amber under 60s, red+pulsing under 10s) | ❌ TODO |
| 3 | Live face-detection reticle (white → green when target is centered) | ❌ TODO |
| 4 | "You got hit" feedback — red flash, camera shake, heart pulse-out, vibration | ❌ TODO |
| 5 | Live kill feed toasts ("Alice → Bob (2 left)") | ❌ TODO |
| 6 | Round-start 3-2-1 cinematic + eliminated state polish (grayscale viewfinder, spectator banner) | ❌ TODO |
| 7 | End-of-round photo montage on results screen | ❌ TODO |

Real-device smoke test for step 1 still pending — see PR #21 test plan checklist.

## Recent session changes (2026-04-28)

- **Immersive viewfinder step 1 shipped (PR #21).** Round screen rebuilt as a full-bleed `CameraPreview` with HUD overlay (hearts top-left, mm:ss timer top-center, opponents+scoreboard top-right, shutter bottom-center) and a bottom-half tap-to-fire zone. New `RoundCamera` abstraction owns the camera lifecycle (init / pause on background / resume / dispose). `cameraFactory` threaded through `SnapshotApp` → lobby flow so widget tests inject `FakeRoundCamera`. Real-device smoke test still pending.
- Bumped `mobile_scanner` 5.x → 7.x to resolve the MLKit version conflict on iOS pod install (PR #18 merged; iOS `pod install` + device QR-scan smoke test still pending — see PR #18 test plan).
- Deployed Phase 1+2 callables, firestore/storage rules, and remote config to `cx-snapshot` (was previously stuck on `deleteUserData` only).
- Granted `allUsers` Cloud Run invoker on all six callables (root cause of the `UNAUTHENTICATED` error).
- Solo-device test loop validated end-to-end via `tools/seed_opponent.cjs` clone-host workflow (tooling shipped in PR #19).
- Auto-rejoin on app relaunch shipped (PR #17): closing/reopening mid-round restores the lobby/round screen instead of dropping the player.

## Where you are right now

First playable build is live and the full `submitTag` pipeline has been validated solo. The immersive viewfinder rebuild has begun (step 1 of 7 shipped). Remaining v1 work splits between finishing the viewfinder polish loop, hardening edge cases, building the threshold-tuning tool, and getting the app into testers' hands.

## Three natural next directions

- **Immersive viewfinder steps 2–4** → cooldown ring + haptics, face-detection reticle, "you got hit" feedback. The "feel" uplift the rebuild was for; each step is independently mergeable.
- **Data-driven iteration** → PR-A (BigQuery view + threshold tuning script). Lets you tune from the data you generate.
- **Multi-device readiness** → PR-B (host-disconnect + mutual-elim) → privacy policy → TestFlight + Android internal track.

## Out of scope for v1

Per `tech-plan.md`: matchmaking, deep-link invites, defense/counter-tag, AR overlays, share-card image gen, spectator/replays, monetization, multi-region, web client.

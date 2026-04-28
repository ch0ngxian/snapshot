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
| 2 | Cooldown ring around the shutter + haptics + timer urgency ramp (amber under 60s, red+pulsing under 10s) | ✅ shipped (PR #23) |
| 3 | Live face-detection reticle (white → green when target is centered) | ✅ shipped (PR #24) |
| 4 | "You got hit" feedback — red flash, camera shake, heart pulse-out, vibration | ✅ shipped (PR #TBD) |
| 5 | Live kill feed toasts ("Alice → Bob (2 left)") | ❌ TODO |
| 6 | Round-start 3-2-1 cinematic + eliminated state polish (grayscale viewfinder, spectator banner) | ❌ TODO |
| 7 | End-of-round photo montage on results screen | ❌ TODO |

Real-device smoke test for step 1 still pending — see PR #21 test plan checklist.

## Recent session changes (2026-04-28)

- **Immersive viewfinder step 4 shipped (PR #TBD).** "You got hit" feedback. `RoundScreen` now subscribes directly to the players stream, watches the local player's `livesRemaining` for drops, and on a strict decrease raises a single `_HitEvent` (timestamped) that fans out to three feedback channels: a full-bleed red flash overlay (fade in fast, fade out slow), a horizontal viewfinder-only shake (decaying sine over ~450ms — HUD stays steady), and a per-heart pulse-out animation on the just-lost slot in the lives row. Adds a heavy-impact haptic on the victim side (distinct from the existing per-verdict shooter haptics). First emission is treated as a baseline so an auto-rejoin into a round where you've already taken hits doesn't replay the flash on cold launch. Three feedback widgets share a `_PlayOnEventTimestamp` mixin that re-keys their controller off `hitEvent.at`, so a back-to-back hit (rare given server immunity) re-arms cleanly. New `InMemoryLobbyRepository.debugApplyHit` helper drives the flow from widget tests. Real-device smoke test still pending.
- **Immersive viewfinder step 3 shipped (PR #24).** Live face-detection reticle. New `FaceTracker` interface + `MlKitFaceTracker` that subscribes to the round camera's preview-frame stream, throttles ML Kit detections to ~6 Hz (configurable), and emits a normalized bounding box pre-rotated into preview-widget space. `RoundCamera` gains `startImageStream`/`stopImageStream` + `sensorOrientation`; `PackageCameraRoundCamera` switches to NV21 (Android) / BGRA (iOS) so frames are ML-Kit-friendly. The reticle widget overlays a rounded white border around the tracked face, flips to green when the tracker reports an aim-lock (face roughly centered AND tall enough that a tag is likely to match — heuristic, configurable thresholds). Tracker lifecycle pauses with the camera on background and restarts on resume; tests inject `FakeFaceTracker` and capture the instance to drive emissions. Real-device smoke test still pending.
- **Immersive viewfinder step 2 shipped (PR #23).** Cooldown ring sweeps around the shutter for the 5s post-fire window (amber arc, drains 12 o'clock clockwise). Shutter + tap-to-fire zone gate themselves while the ring is sweeping; client-side no-face bail does NOT engage cooldown. Haptics layered onto every verdict (selectionClick on press, mediumImpact on hit, double `heavyImpact` on elimination, lightImpact on miss/immune/cooldown). Timer color ramps white → amber under 60s → red + pulsing under 10s. Cooldown verdict now suppresses the redundant "Slow down" toast (the ring already says it).
- **Immersive viewfinder step 1 shipped (PR #21).** Round screen rebuilt as a full-bleed `CameraPreview` with HUD overlay (hearts top-left, mm:ss timer top-center, opponents+scoreboard top-right, shutter bottom-center) and a bottom-half tap-to-fire zone. New `RoundCamera` abstraction owns the camera lifecycle (init / pause on background / resume / dispose). `cameraFactory` threaded through `SnapshotApp` → lobby flow so widget tests inject `FakeRoundCamera`. Real-device smoke test still pending.
- Bumped `mobile_scanner` 5.x → 7.x to resolve the MLKit version conflict on iOS pod install (PR #18 merged; iOS `pod install` + device QR-scan smoke test still pending — see PR #18 test plan).
- Deployed Phase 1+2 callables, firestore/storage rules, and remote config to `cx-snapshot` (was previously stuck on `deleteUserData` only).
- Granted `allUsers` Cloud Run invoker on all six callables (root cause of the `UNAUTHENTICATED` error).
- Solo-device test loop validated end-to-end via `tools/seed_opponent.cjs` clone-host workflow (tooling shipped in PR #19).
- Auto-rejoin on app relaunch shipped (PR #17): closing/reopening mid-round restores the lobby/round screen instead of dropping the player.

## Where you are right now

First playable build is live and the full `submitTag` pipeline has been validated solo. The immersive viewfinder rebuild is 3 of 7 steps in. Remaining v1 work splits between finishing the viewfinder polish loop, hardening edge cases, building the threshold-tuning tool, and getting the app into testers' hands.

## Three natural next directions

- **Immersive viewfinder steps 4–5** → "you got hit" feedback (red flash, camera shake, heart pulse-out, vibration), then live kill-feed toasts ("Alice → Bob (2 left)"). Each step is independently mergeable.
- **Data-driven iteration** → PR-A (BigQuery view + threshold tuning script). Lets you tune from the data you generate.
- **Multi-device readiness** → PR-B (host-disconnect + mutual-elim) → privacy policy → TestFlight + Android internal track.

## Out of scope for v1

Per `tech-plan.md`: matchmaking, deep-link invites, defense/counter-tag, AR overlays, share-card image gen, spectator/replays, monetization, multi-region, web client.

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
| Host-disconnect auto-promote | ❌ TODO |
| Mutual elimination → tie (last 2 alive) | ❌ TODO |
| BigQuery view + threshold tuning script | ❌ TODO |
| Friends-family playtest | 🟡 solo verified; multi-device pending |
| Accuracy gate (false-accept rate at 0.65) | ❌ pending playtest data |
| Privacy policy | ❌ TODO (required before TestFlight) |
| TestFlight + Android internal track | ❌ TODO |

## Recent session changes (2026-04-28)

- Bumped `mobile_scanner` 5.x → 7.x to resolve MLKit version conflict on iOS pod install.
- Deployed Phase 1+2 callables, firestore/storage rules, and remote config to `cx-snapshot` (was previously stuck on `deleteUserData` only).
- Granted `allUsers` Cloud Run invoker on all six callables (root cause of the `UNAUTHENTICATED` error).
- Solo-device test loop validated end-to-end via `tools/seed_opponent.cjs` clone-host workflow.

## Where you are right now

First playable build is live and the full `submitTag` pipeline has been validated solo. Remaining v1 work is hardening edge cases, building the threshold-tuning tool, and getting the app into testers' hands.

## Two natural next directions

- **Data-driven iteration** → PR-A (BigQuery view + threshold tuning script). Lets you tune from the data you generate.
- **Multi-device readiness** → PR-B (host-disconnect + mutual-elim) → privacy policy → TestFlight + Android internal track.

## Out of scope for v1

Per `tech-plan.md`: matchmaking, deep-link invites, defense/counter-tag, AR overlays, share-card image gen, spectator/replays, monetization, multi-region, web client.

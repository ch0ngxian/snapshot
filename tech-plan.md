# Snapshot — Tech Plan (Draft, ready for review)

> Mobile multiplayer game. Players in the same physical area join a lobby; during the round they "tag" each other by taking a photo with their phone camera, which deducts a life from the photographed player. Last player(s) alive win.

**State:** ready to execute. All Key Decisions locked; remaining variability is empirical (threshold tuning, latency-gate result) and tracked in §5.7 / §5.8 validation gates.
**v1 target:** playable MVP for friends/family (~4–6 weeks).

## Open questions

_None._ All v1 decisions locked. Remaining variability is empirical (threshold tuning during playtest, latency-gate result on low-end Android) and tracked in §5.7 / §5.8 validation gates.

## 1. High-Level Architecture

```
                       ┌────────────────────────────────────────────┐
                       │                MOBILE CLIENT               │
                       │  (Flutter — iOS + Android, single codebase)│
                       │                                            │
   Onboard ──► Selfie ──► [FaceEmbedder]* ──┐                       │
                       │                    │                       │
   In round ──► Camera ──► [FaceEmbedder]* ─┤   embedding (~2KB) ──►│
                       │                    │   photo only if       │
                       │                    │   server says retain  │
                       │  Lobby UI / Score ◄┘   (borderline; §5.9)  │
                       └─────────────┬──────────────────────────────┘
                                     │ HTTPS / Firestore stream
                                     ▼
                       ┌────────────────────────────────────────────┐
                       │                FIREBASE BACKEND            │
                       │                                            │
                       │  Auth ──► Firestore ──► Cloud Functions    │
                       │   │          │              │              │
                       │   │     lobbies/players/tags │              │
                       │   │          │              ▼              │
                       │   │          │     submitTag (verify)      │
                       │   │          │      • cosine vs opponents  │
                       │   │          │      • atomic life decrement│
                       │   │          │      • emit FCM to victim   │
                       │   │          ▼                             │
                       │   │     Audit log (all attempts) ──► BQ    │
                       │   │                                        │
                       │   └─► Storage (borderline tag photos only, │
                       │                30-day lifecycle; §5.9)     │
                       │                                            │
                       │   FCM ──► push notifications to clients    │
                       └────────────────────────────────────────────┘

   *FaceEmbedder is a switchable abstraction.
    v1 model: MobileFaceNet via TFLite (locked — see §5.7).
    Future swap candidates: ArcFace, FaceNet (heavier TFLite models).
    Rejected: Apple Vision / ML Kit native — embeddings not comparable across platforms.
```

**What it does.** Onboarding extracts a face embedding from a selfie and stores it on the user profile. During a round, the client extracts an embedding from each shutter press and POSTs it to a Cloud Function, which compares it against all alive opponents in that lobby. Closest match above threshold wins the tag, life is decremented atomically, victim gets a push. The photo itself is uploaded *only* if the server's response says to retain it (borderline cases — see §5.9).

**Pluggability.** The face embedder is wrapped behind a thin client-side interface so the model can be swapped without changing call sites. Backend code only sees a fixed-dimension float vector — it doesn't care which model produced it, only that everyone in a given app version uses the same one. `modelVersion` is logged with every tag for cross-version comparison.

## 2. User Interaction

Single role: **Player**. (No merchant, no spectator in v1.)

### Onboarding (first launch)
- Sign in (Firebase Auth — anonymous + display name; email/Google deferred).
- Capture selfie in a guided UI (face centered, good lighting hint).
- On-device extracts embedding; embedding + a small thumbnail is stored on the user profile.
- Consent screen: "We store a numeric representation of your face on our servers to make this game work. We keep an actual photo only when our system is unsure about a tag — for at most 30 days — to improve accuracy. You can delete your data any time." (Retention: §5.9. Delete flow + ownership: §5.10.)

### Hosting / joining a round
- **Host** taps *Create Lobby*. Waiting-room screen shows the QR code + the 6-char code side-by-side, plus the live player list. Sets rules (starting lives, round duration, post-hit immunity). Taps *Start*.
- **Joiner** taps *Join* → camera opens to scan host's QR (default path) → name appears in host's list. Fallback: tap *Enter code instead* → type 6 chars → join. Either path → waits for start → countdown → camera screen.

### In round
- Camera screen is the primary surface. Top-bar shows remaining lives, round timer, and an *opponents alive* count.
- Tap shutter → flash → loading spinner (~300ms) → toast result:
  - ✅ "You hit Alice. She has 2 lives left."
  - ❌ "No match. (Cooldown 5s)"
  - ⚠️ "Alice is immune for 4s."
- If you are tagged: push notification + in-app banner + haptic. Lives counter ticks down. No counter-action available in v1.
- Live scoreboard accessible via swipe-up sheet — names, lives, eliminated badge.

### Round end
- Triggered by timer or one player remaining.
- Results screen: standings, your tags landed/received, MVP, share button (deferred — share image generation is v2).

### Scope boundaries
- **In scope v1:** lobby create/join, selfie onboarding, tag-by-photo, lives, immunity window, scoreboard, push notifs, end-of-round screen.
- **Not in scope v1:** matchmaking, friends list, social feed, replays, AR overlays, monetization, defense / counter-tag, multi-region routing, web client, age verification beyond ToS checkbox.

## 3. Database

Firestore (single project, single region — `asia-southeast1` / Singapore, picked for SEA-based playtest pool).

### Collections

| Path                                  | Purpose                                                                                    |
|---------------------------------------|--------------------------------------------------------------------------------------------|
| `users/{uid}`                         | `displayName`, `faceEmbedding` (base64 Float32, dim ~192), `embeddingModelVersion`, `selfieThumbUrl`, `createdAt` |
| `lobbies/{lobbyId}`                   | `code` (6 char, unique while active), `hostUid`, `status` (`waiting`/`active`/`ended`), `rules` map, `createdAt`, `startedAt`, `endedAt` |
| `lobbies/{lobbyId}/players/{uid}`     | `displayName`, `livesRemaining`, `lastTaggedAt`, `status` (`alive`/`eliminated`), `joinedAt`, `embeddingSnapshot` (denormalized at join time) |
| `lobbies/{lobbyId}/tags/{tagId}`      | `taggerUid`, `resolvedTargetUid`, `topMatchDistance`, `top3Distances`, `accepted`, `rejectReason`, `photoStorageRef` (string — `null` while awaiting client upload of a borderline tag, `"discarded"` for clear-accept/reject tags, or `"tags/{lobbyId}/{tagId}.jpg"` once uploaded; §5.9), `modelVersion`, `createdAt` |

### Indexes
- `lobbies` by `code` (unique constraint enforced via Cloud Function `createLobby` retry-on-collision).
- `lobbies/{id}/tags` composite: `(accepted, createdAt)` for round summary queries.

### Storage (Cloud Storage for Firebase)
- `selfies/{uid}.jpg` — onboarding selfie thumbnail (small, ~30KB).
- `tags/{lobbyId}/{tagId}.jpg` — tag photo, **uploaded only when borderline** (`abs(topMatchDistance − threshold) < 0.10`). Lifecycle rule auto-deletes after 30 days. Clear accepts and clear rejects keep no photo server-side. See §5.9.

### Why denormalize embedding to player doc
The opponent embeddings need to be loaded fast for every tag check. Reading them from `users/*` would be a fan-out read across 10–20 docs per tag. Snapshotting at lobby-join time turns the tag check into a single subcollection query. Trade-off: a user who updates their selfie mid-round won't see the new embedding take effect until the next lobby — acceptable.

## 4. Performance Handling

- **Tag check latency target:** p95 < 600ms end-to-end (shutter → toast). Budget: 100ms photo capture, 50ms ML Kit face detect + crop, 150ms on-device embed (MobileFaceNet), 100ms upload, 100ms server compare, 50ms response, ~50ms slack. Per §5.7, no-face-detected short-circuits before the embed step.
- **Caching:** none needed. Tag data is write-heavy and per-round; cache hit rate would be near zero.
- **N+1:**
  - Scoreboard subscribes to `lobbies/{id}/players` collection (≤20 docs) via `onSnapshot`. Single listener, batched updates.
  - `submitTag` reads all alive players in the lobby in one query — no fan-out per opponent.
- **Sync vs async:**
  - **Sync:** the tag check itself (player is staring at the screen).
  - **Async:** audit log writes to BigQuery, conditional photo upload (only if server response says `retainPhoto: true` — borderline tags, fire-and-forget after the verdict toast renders), end-of-round summary computation.
- **Race conditions:**
  - Two players tag the same victim simultaneously → Firestore transaction on the player doc. First write wins; second sees `livesRemaining` already decremented and re-evaluates (still applies if > 0, no-ops if eliminated). Eliminated player can't be tagged again.
  - Tagger spamming the shutter → server-side cooldown (5s) keyed on `(taggerUid, lobbyId)`. Enforced in the Function, not client-trusted.
- **Rate limiting:** Cloud Function caps `submitTag` at 1 req / 2s per user via in-memory token bucket per instance + Firestore-backed cooldown for cross-instance coverage.
- **Job concurrency caps:** N/A in v1 — no Sidekiq-style worker pool; everything is request-scoped Functions.
- **Hot-path concerns:**
  - Embedding payload is ~2KB, fine for cellular at a party.
  - Photo bytes are *not* on the hot path — the verdict is returned from the embedding alone. If the server says retain, the photo is uploaded after the toast renders, so the user never waits on it.
- **Inherited risks** (flag, not fixing in v1):
  - Firestore Functions cold starts can spike to 2–3s on first request after idle. For an MVP playtest this is acceptable; warm with a scheduled ping if it becomes painful.
  - No region failover — single-region Firebase. Acceptable for friends/family.

## 5. Key Decisions

### 5.1 Face recognition runs on-device, comparison runs server-side

**What.** Embeddings are computed locally on the player's phone. The client uploads the embedding (a ~192-float vector) to a Cloud Function which performs cosine similarity against alive opponents in the same lobby and returns the verdict.

**From first principles.** The face image is sensitive personal data; the round is real-time so latency matters; embeddings are small and cheap to ship. Doing the heavy ML on-device removes the photo from the network in the common case and keeps round responsiveness independent of backend ML capacity. The *verdict* must be server-authoritative, however, because anything client-decided is trivially cheatable.

**Why not pure server-side ML.** Photo upload latency on hotel/cafe Wi-Fi at a party kills the feel. Backend GPU cost scales linearly with player-rounds. Larger privacy surface (raw photos pile up server-side).

**Why not pure on-device (download opponent embeddings, match locally).** Client could lie: "I matched user X" without ever taking a photo. Server-authoritative comparison closes this loophole.

**Trade-offs accepted.** Older Android devices without TFLite acceleration may take >300ms to embed; we'll detect and show a slightly slower spinner. iOS and Android must run *the same model* so embeddings are comparable — rules out each platform's native ML and forces a single cross-platform model (locked to MobileFaceNet — see §5.7).

### 5.2 Embedding model is wrapped behind a switchable abstraction, version stamped on every tag

**What.** A `FaceEmbedder` interface in client code with the active model implementation injected. Every embedding stored on `users/{uid}` and every tag record carries `modelVersion`. Cloud Function refuses to compare embeddings with mismatched `modelVersion` — explicit failure beats silent garbage matches. Switching models means bumping the version and updating the client; backend code is untouched.

**From first principles.** Face recognition is a young, fast-moving area; we will want to upgrade. Treating the embedder as a swappable component prevents the codebase from quietly assuming "the model" exists. Version stamping lets us A/B model accuracy by re-running comparisons offline against historical tags. Strict version matching prevents the silent-corruption failure mode where two incompatible embeddings get cosine-compared and produce a meaningless number.

**Why not hardcode the model.** Locks us in; makes "let's try ArcFace next month" a refactor rather than a config flip.

**Why not multiple concurrent models.** Embeddings from different models aren't comparable — would multiply complexity for zero MVP benefit.

**Trade-offs accepted.** Slightly more boilerplate up front. One model active at a time per app version; users on old app versions stay on old embeddings until they update. Bumping the model in the future means: ship a client update, prompt users to re-take their selfie, run with both versions briefly, then phase the old one out.

### 5.3 Lobby join via QR scan (primary) + 6-char code (fallback), no invite links or matchmaking

**What.** Host creates a lobby and the waiting-room screen shows two things at once: a QR code (encoding the 6-char code) and the human-readable code itself. Joiners default to scanning the QR with their camera; the manual code-entry field is one tap away for anyone who can't or won't scan. Both paths hit the same `joinLobby` validation against the same code namespace.

**From first principles.** v1 players are physically co-located (same room) — the host has a phone visible. Pointing a camera at it is faster, more reliable, and less error-prone than reading out characters at a party where ambient noise and "is that an O or a 0?" are real failure modes. The QR is just a delivery mechanism for the same ephemeral code; the underlying validation, collision handling, and namespace are unchanged. Manual entry is the fallback for accessibility (older devices, broken cameras, or when the host isn't physically reachable).

**Why not deep-link invites.** Adds infra (link service, deep-link routing per platform, link previews) for no v1 gain. Defer to v2 when remote join becomes a real use case.

**Why not auto-matchmaking.** Pointless without a player base; conflicts with the "co-located" model — random matchmaking implies remote play.

**Why not QR-only (drop manual entry).** Camera permission denial, broken cameras, or simply being across the room from the host are real failure modes. The manual-entry fallback costs almost nothing once the code system already exists.

**Why 6-char codes specifically.** 36^6 ≈ 2B possibilities, far more than concurrent active lobbies will need. 4 chars (1.6M) is also plenty at v1 scale and feels less bureaucratic; defaulting to 6 is conservative and gives more headroom for namespace recycling timing edge cases. Cheap to revisit later.

**Trade-offs accepted.** Adds a QR-scan plugin (`mobile_scanner` or equivalent — well-maintained for Flutter) and a QR-render plugin (`qr_flutter`). Both are first-class. Camera permission for joiners is requested at scan time; if denied, the manual-entry path still works. Code collisions are possible but rare; `createLobby` retries on insert collision. Codes are ephemeral (active lobby lifetime ~30 min) so the namespace recycles fast.

### 5.4 Firebase (Firestore + Functions + FCM) over Supabase or custom

**What.** Firebase is the backend: Auth for users, Firestore for state, Cloud Functions for `submitTag` and `createLobby`, FCM for push, Cloud Storage for photos.

**From first principles.** Real-time scoreboard updates and reliable push are the two backend hard problems for this game. Firestore solves the first natively; FCM solves the second with the tightest mobile integration. Auth is bundled. The total amount of "real backend code" is a handful of Functions.

**Why not Supabase.** Comparable feature set, but FCM integration is less mature than Firebase's native pairing. v1 is mobile-first, push-heavy.

**Why not custom (Node/Postgres/Redis).** Ops burden is wildly disproportionate for a friends-and-family MVP. Would need to build push, real-time sync, auth, storage from primitives — months of work for no MVP-relevant gain.

**Trade-offs accepted.** Vendor lock-in. We isolate Firestore access behind a `Repository` layer in client code so a future migration is feasible. ML/anti-cheat logic is constrained by what Cloud Functions can do — fine for v1, may need a real backend later.

### 5.5 No defense / counter-tag in v1

**What.** When you're tagged you lose a life and that's it. No window to counter-tag; no shield mechanic.

**From first principles.** First playable's job is to validate the core loop ("is photographing your friends actually fun?"). Defense mechanics introduce timing windows, race conditions, and UX clarity issues that need their own design iteration. Adding them before validating the core loop risks debugging a system that nobody enjoys playing.

**Why not counter-tag.** Counter-tags need a defined response window, UI for "you have 3s to respond", race-condition handling for simultaneous shots, and tutorial overhead. Defer to v2 once the base loop is fun.

**Why not shield power-ups.** Same reasoning + introduces inventory, which is more state than v1 needs.

**Trade-offs accepted.** Pile-on risk (one player gets photographed by 3 others in 5 seconds and dies instantly). Mitigated by a configurable post-hit immunity window (default 10s). If playtesters report pile-on still feels bad, we tune the window before adding mechanics.

### 5.6 Cross-platform Flutter over native, RN, or Unity

**What.** Single Flutter codebase ships to iOS and Android. Locked.

**From first principles.** v1 needs both iOS and Android friends to actually play together — that's the whole game. Halving development cost matters more than squeezing the last 10% of camera UX. The camera, TFLite, and Firebase plugins for Flutter are first-party Google packages, which aligns directly with the rest of our stack (Firebase backend, MobileFaceNet via TFLite). Builder is new to mobile dev, so a single opinionated framework with a strong default "way" reduces decision fatigue and config-pitfall risk during the steepest part of the learning curve.

**Why not native (Swift + Kotlin).** ~2× dev cost. Right call only if camera UX is the differentiator (it isn't — it's the *gameplay* that's the differentiator). Doubles the surface area for someone learning mobile dev for the first time.

**Why not React Native.** Reasonable alternative on the merits, but: (a) builder has no existing React/JS investment that would tilt the choice, (b) RN has a richer config-pitfall surface (CocoaPods, gradle, native module version drift) that hurts more when you're learning, (c) our two heaviest plugin dependencies (TFLite, Firebase) are Google-maintained — first-party Flutter plugins, community-maintained RN plugins. Small but consistent edge in our exact stack.

**Why not Unity / game engine.** Overkill. We're not rendering 3D scenes, we're rendering a camera viewfinder and a scoreboard. Engine bloat (binary size, build time) outweighs the game-feel features for a v1 MVP.

**Trade-offs accepted.** TFLite integration is plugin-mediated; if the plugin lags a TF release we may need a native bridge. Dart is a new language to learn (~1 week productive ramp). Acceptable for both.

### 5.7 v1 face embedding model is MobileFaceNet (TFLite), locked

**What.** Two-stage on-device pipeline: **(1) detect & crop** the largest face in the captured frame using ML Kit Face Detection (free, on-device, both platforms), **(2) embed** the cropped face using MobileFaceNet via TFLite. Bundle the same MobileFaceNet `.tflite` file in iOS and Android builds. Embedding dimension ~192. `modelVersion = "mobilefacenet-v1"` stamped on every embedding stored and every tag record. If quantization is needed for low-end Android perf, that ships as `mobilefacenet-v1-q` — a separate version, not a silent swap. If no face is detected in the captured frame, the client returns "no match" without calling `submitTag` — saves a Function invocation and gives the user faster feedback.

**Why the detect-then-embed two-stage pipeline.** Feeding a full-frame photo to MobileFaceNet (where the face occupies maybe 10% of the image) produces embeddings dominated by background pixels and is empirically much less accurate than feeding a tight face crop. ML Kit Face Detection is the standard production pattern for this preprocessing step — fast (<50ms), no model file to bundle, and free. The detection model is separate from the embedding model so it doesn't muddy the `modelVersion` story.

**From first principles.** v1 has three hard requirements: (a) cross-platform comparable embeddings — an iOS player and an Android player must be able to tag each other; (b) on-device extraction (Decision 5.1) — no raw photos transit the network in the common case; (c) lightweight enough to ship in a friends/family MVP. MobileFaceNet is the only widely-available option that satisfies all three. The model defines its own embedding space; embeddings from different models are not comparable, so cross-platform consistency *requires* one shared model regardless of platform.

**Why not Apple Vision (iOS) + ML Kit (Android) native.** Each platform's native face system produces a different embedding space — Vision's `VNFaceObservation` features and ML Kit's outputs are not comparable. An iOS player and an Android player at the same party literally could not tag each other. ML Kit also doesn't expose a stable recognition embedding (it's tuned for detection). Dealbreaker for the friends/family MVP, where mixed phones are the norm.

**Why not ArcFace / FaceNet.** Higher accuracy on poor lighting and partial faces, but 10–30MB binary and 200–400ms extraction on mid-tier Android. At v1 scale (≤20 players per lobby) the comparison space is tiny — accuracy gains matter more when matching against millions of identities, not twenty. Reserved as the natural upgrade path if playtest shows MobileFaceNet hitting an accuracy ceiling.

**Why not hosted server-side embeddings (Vertex AI, Rekognition).** Solves cross-platform automatically, but reverses Decision 5.1: photo must travel to the server. Adds 200–500ms per tag, recurring per-call cost, and a privacy surface (raw face photos transiting our infra). Worth revisiting only if on-device proves too inconsistent across devices during playtest.

**Trade-offs accepted.**
- **Lighting tolerance.** Parties are dim; MobileFaceNet may struggle. Mitigation: capture-time UI hints (good lighting prompt), and a lower-bar threshold tuned during playtest. Escalation path: swap to ArcFace via §5.2.
- **App size.** ~5MB added to each platform binary. Acceptable.
- **Older Android perf.** Mid-tier devices may need the quantized variant (~2% accuracy hit for ~2× speedup). Validated in Phase 0.

**Validation gates before declaring this stable** (Phase 0 / Phase 3):
- On-device extraction p95 <250ms on a low-end Android (e.g. Pixel 4a / Galaxy A-series). Else ship quantized.
- False-accept rate at threshold 0.65 with 5–10 friends' selfies in mixed lighting. Tighten threshold first; only swap models if tightening cripples true-accept rate.
- Lighting tolerance: well-lit selfie matches dim photo of the same person.

### 5.8 Cosine threshold ships at 0.65, stored in Remote Config, tuned from playtest data

**What.** `submitTag` accepts a tag when `cosine_similarity(taggerEmbedding, opponentEmbedding) >= threshold`, where `threshold` is read from Firebase Remote Config (key `tag_match_threshold`, default `0.65`). Single global value — no per-lobby override in v1. Every tag attempt (including rejects) records `topMatchDistance` and `top3Distances` so the threshold can be re-tuned from logged data without re-running the model.

**From first principles.** The "right" threshold is empirical — it depends on the model's actual distance distribution at typical phone-camera quality, the lighting variance in real play environments, and the demographic spread of the player pool. None of this is knowable up front. The right move is to ship a sensible default, log richly enough that we can re-derive the optimum from the data, and put the value somewhere we can change it without a deploy.

**Why 0.65 specifically.** Published MobileFaceNet implementations cluster between 0.6 and 0.7 for accept thresholds on similar phone-quality inputs. 0.65 is the middle of that range — minimizes how far we have to move on the first tune, regardless of which direction the data points to.

**Why Remote Config, not hardcoded.** During playtest we expect to tune this multiple times between sessions. A Cloud Function redeploy is ~2 minutes, manageable but disruptive when you're in a feedback loop. Remote Config is `~30 min` of setup once, then zero-friction tuning forever. Cloud Function reads cache the value with a short TTL — no hot-path cost.

**Why not a Firestore document the Function reads.** Marginally cheaper than Remote Config but adds a per-call read on the hot path; you'd need to add caching anyway. Remote Config has caching built in.

**Why no per-lobby override in v1.** Adds tester-facing UX surface ("what does 'easy mode' actually do?") before testers have a calibrated intuition for what the dial means. Defer until we've seen at least one playtest.

**Trade-offs accepted.**
- Until first tune, we will see *some* false accepts or false rejects in playtest. That's the point — that's the data we're collecting.
- Remote Config has client-side caching too; for the *server-side* read in `submitTag` we use the Admin SDK which we configure with a 60s cache to balance tunability with cost.
- Threshold is global; if one demographic's faces cluster differently, we eat that until we have enough data to consider per-cohort thresholds (almost certainly never needed for v1 scale).

### 5.9 Tag photos retained only when borderline, 30-day lifecycle

**What.** `submitTag` uploads the tag photo to `tags/{lobbyId}/{tagId}.jpg` **only when** `abs(topMatchDistance − threshold) < 0.10` — i.e. only when the system was near the decision boundary. Clear accepts (well below the distance threshold = strong match) and clear rejects (well above = obviously not a match) keep no photo server-side. Stored photos are deleted by a Cloud Storage lifecycle rule after 30 days.

**From first principles.** A tag photo exists only to (a) tune the threshold and (b) resolve disputes. Both require a human looking at it. For tuning, the only photos that carry information are the ones near the decision boundary — a clear-accept (distance 0.45 vs threshold 0.65) doesn't teach you anything new, and neither does a clear-reject (distance 0.85). For disputes, the cases most likely to be contested are the borderline ones. So the borderline band is where the *signal* is, and storing the rest is privacy cost without benefit.

**Why not store all tag photos.** Larger privacy surface (every photo of every player accumulates server-side). The clear-accept and clear-reject photos provide near-zero marginal information for tuning. Most tag photos taken in a session would never be looked at, but their existence still has to be disclosed and defended.

**Why not store nothing server-side.** Tuning would have to rely solely on distance distributions, with no labelled ground truth. Disputes would have no evidence at all. For a game that depends on a calibrated similarity threshold, going completely dark on photos kneecaps our ability to make the threshold work.

**Why not store all forever (no auto-delete).** Indefensible for face data even in a friends/family MVP. Promise of deletion is a baseline trust commitment.

**Why the ±0.10 band specifically.** Empirical: that's the typical width of the "uncertain zone" in MobileFaceNet distance distributions on phone-quality input. Configurable in Remote Config (key `borderline_half_width`, default `0.10`) so we can widen during early playtest if data is sparse, narrow once tuned.

**Trade-offs accepted.**
- **More complex `submitTag`.** Function decides at write-time whether to keep the photo. Photo is uploaded by the *client* (so server doesn't double-handle bytes), but the server returns a "discard or keep" verdict that the client honors. Worst case the client lies and uploads anyway — caught by Storage security rules (below) and the same lifecycle rule that deletes within 30 days.
- **Sparse data for boundary far from current threshold.** If we tune the threshold to e.g. 0.70 we lose 30 days of accumulated 0.55–0.65 borderline photos, since they were borderline-vs-the-old-threshold. Acceptable — we just collect more under the new band.
- **Dispute coverage is partial.** Clear-reject disputes ("you said no but it was me!") have no photo evidence. Mitigated by the 10s post-hit immunity reducing the rate of contested losses; if a player feels strongly they can replay the scenario.

**Storage security rules.** Cloud Storage rules on the `tags/` prefix enforce that a client can only `create` an object at `tags/{lobbyId}/{tagId}.jpg` if (a) the request is authenticated as the user who owns `tagId` (matched against `lobbies/{lobbyId}/tags/{tagId}.taggerUid`), and (b) the tag doc's `accepted` field is set *and* `photoStorageRef` is `null` (i.e. the upload slot exists and hasn't been filled). The server-issued "retain photo" verdict is what causes `submitTag` to leave `photoStorageRef` writeable; clear-accept and clear-reject tags get `photoStorageRef = "discarded"` written immediately, blocking client upload. Defense-in-depth on top of the trust model — the lifecycle rule still backstops anything that slips through.

**Consent disclosure.** §2 onboarding consent message is updated to: "We keep an actual photo only when our system is unsure about a tag — for at most 30 days — to improve accuracy."

### 5.10 Delete-my-data covers selfie + tag photos featuring the user; privacy policy deferred to Phase 3

**What.** "Delete my data" runs a Cloud Function `deleteUserData` that:
1. Deletes `users/{uid}` (selfie embedding + display name).
2. Deletes `selfies/{uid}.jpg` from Storage.
3. Queries `tags` collection-group for any docs where `resolvedTargetUid == uid`, deletes the corresponding `tags/{lobbyId}/{tagId}.jpg` from Storage, and clears the `photoStorageRef` field on the doc.
4. Leaves the `tags` doc itself in place (anonymous distance data is useful for threshold tuning) but with no photo and no resolvable identity.

The 30-day Cloud Storage lifecycle rule from §5.9 still applies as a backstop — even if a user never explicitly deletes, photos auto-expire.

Builder (chongxian.goh@gmail.com) is the named privacy contact in v1. The full privacy policy text is deferred until Phase 3 (TestFlight handoff), at which point a generator (Termly / iubenda / Termsfeed) produces a baseline that gets edited to match this plan's specific data flows: MobileFaceNet embedding, on-device extraction, server-side comparison only, borderline-only photo retention, 30-day lifecycle, deletion on request via the in-app hook.

**From first principles.** Promising "delete on request" is meaningless if photos featuring the user persist under a different player's `tagId`. The only honest delete flow is one that finds and removes those photos too. We can do this cheaply because `resolvedTargetUid` is already on every tag doc — no schema change needed.

**Why both explicit delete + 30-day backstop.** Explicit delete makes the consent promise truthful immediately. The lifecycle rule covers the case where a user simply uninstalls without going through the delete flow — which will be common in a friends/family MVP. The two together are stronger than either alone and cost essentially nothing.

**Why not a "delete user doc + selfie only" v1.** It would force a less honest consent message ("photos featuring you will auto-delete within 30 days" rather than "you can delete now"). Saves maybe 30 minutes of Cloud Function code in exchange for a weaker trust commitment. Bad trade.

**Why defer the privacy policy text to Phase 3.** Phases 0–2 are pre-public; only the small playtest group sees the app, and they all know the builder personally. Apple/Google review is the first time a real privacy policy *must* exist, and that aligns with the Phase 3 TestFlight handoff. Premature drafting risks getting out of sync with the plan if anything moves.

**Trade-offs accepted.**
- **`tags` collection-group query on delete.** Requires a collection-group index on `resolvedTargetUid` (cheap one-time setup). Query is fast at v1 scale.
- **Tag docs survive delete with `photoStorageRef = null`.** Audit log still references the user via `taggerUid` / `resolvedTargetUid`. If a user wants those scrubbed too we'd add a second tier of "anonymize" — defer until requested.
- **No business entity yet.** Personal email as the named contact is fine for friends/family scope. Migrate to a real entity / business email if/when going public.

## Implementation breakdown

Phased work items — what `upload-plan` should turn into milestones.

### Phase 0 — Foundations (~Week 1)
- Flutter project scaffold, CI (GitHub Actions: lint, test, build artifacts).
- Firebase project: Auth (anonymous), Firestore, Functions, Storage (with 30-day lifecycle rule on `tags/`), FCM, Remote Config (`tag_match_threshold = 0.65`, `borderline_half_width = 0.10`), BigQuery export for `tags` collection.
- `FaceEmbedder` interface + two-stage on-device pipeline: ML Kit Face Detection (detect & crop) → MobileFaceNet TFLite (embed) for both platforms (`modelVersion = "mobilefacenet-v1"`). No-face-detected short-circuits to a local "no match" without calling `submitTag`.
- **Latency gate**: measure on-device pipeline p95 (detect + crop + embed) on a low-end Android (Pixel 4a / Galaxy A-series). If >300ms, ship quantized embedder variant (`mobilefacenet-v1-q`) — keep ML Kit detector as-is.
- Onboarding: anonymous auth + display name + selfie capture + on-device embedding + write to `users/{uid}`.
- Consent screen (text per §5.9) + `deleteUserData` Cloud Function: deletes `users/{uid}`, `selfies/{uid}.jpg`, and any retained tag photos where `resolvedTargetUid == uid` (collection-group query on `tags`, requires composite index). Tag docs survive with `photoStorageRef = null`. See §5.10.

### Phase 1 — Lobby & round lifecycle (~Week 2)
- `createLobby` Cloud Function with collision-retry for the 6-char code.
- Host waiting-room screen: QR code (rendered via `qr_flutter`) + 6-char code displayed together, live player list (Firestore listener).
- Joiner flow: QR scan via `mobile_scanner` (primary) + manual code-entry screen (fallback). Both call the same `joinLobby` Function.
- Host configurable rules: starting lives (default 3), duration (default 10 min), immunity window (default 10s).
- `startRound` transition: locks the player list, snapshots embeddings into `lobbies/{id}/players/{uid}`.
- Round timer + end-of-round transition (timer expiry or 1 alive).

### Phase 2 — Tag mechanic (~Week 3)
- In-round camera screen.
- `submitTag` Cloud Function: read `tag_match_threshold` and `borderline_half_width` from Remote Config (60s cache) → load alive opponents → cosine similarity → pick top match above threshold → atomic `livesRemaining` decrement → mark eliminated if 0 → write tag record (incl. `topMatchDistance`, `top3Distances`) → return `{result, retainPhoto: bool}` → FCM to victim.
- Client toast for tag results (hit / no match / immune / cooldown).
- Live scoreboard sheet.
- Push notification handling (foreground banner + background notification).
- Conditional photo upload: client uploads to `tags/{lobbyId}/{tagId}.jpg` **only if** server response says `retainPhoto: true` (borderline band). Async, after tag verdict received.
- Cloud Storage security rules (per §5.9): allow `create` at `tags/{lobbyId}/{tagId}.jpg` only when authenticated as `taggerUid` AND the `tags/{tagId}` doc has `accepted` set AND `photoStorageRef == null`. Clear-accept and clear-reject tags get `photoStorageRef = "discarded"` set by `submitTag`, blocking client upload at the rules layer.

### Phase 3 — Polish & hardening (~Week 4)
- Cooldowns (5s tagger), immunity (10s post-hit), enforced server-side.
- Edge cases: host disconnect (auto-promote), last 2 alive (mutual elimination → tie), network drop mid-tag (idempotency key on `submitTag`).
- BigQuery view + a one-shot script for tuning the cosine threshold from playtest data.
- Friends-and-family playtest cycle: 2–3 sessions, threshold tuning between sessions.
- **Accuracy gate**: false-accept rate at threshold 0.65 with 5–10 friends' selfies in mixed (incl. dim) lighting. Tighten threshold first; only escalate to a model swap (ArcFace via §5.2) if tightening collapses true-accept rate.
- **Privacy policy** (per §5.10): generate baseline via Termly/iubenda/Termsfeed, hand-edit the face-data section to match this plan (MobileFaceNet embedding, on-device extraction, borderline-only photo retention, 30-day lifecycle, delete-on-request). Builder's email is the named contact. Required before TestFlight submission.
- TestFlight + Android internal track for testers (still pre-public).

### Out of scope for v1 (note for future phases)
- Public matchmaking, deep-link invites
- Defense / counter-tag mechanics, power-ups
- AR overlays, photo filters, share-card image gen
- Spectator mode, replays
- Monetization, store listing, age gating beyond ToS
- Multi-region failover
- Web spectator dashboard

# Snapshot

A real-world, in-person multiplayer photo-tag game for phones. You and your friends are in the same physical space (party, gathering, office); your phone's camera is your weapon, and everyone's **face is their hitbox**. Last player(s) standing win.

Built as a Flutter app on iOS + Android with a Firebase backend (Auth, Firestore, Cloud Functions, Storage, FCM). The face-matching pipeline runs **on-device** — ML Kit detects/crops the face, MobileFaceNet (TFLite) produces the embedding, and only the embedding is sent to the server for matching. No raw photos leave the phone except in borderline cases flagged for review.

The round screen is built as an **immersive viewfinder experience** — the live camera fills the screen and acts as both the game world and the weapon. The HUD is a thin overlay on top of it. There is no "open the camera" step; the camera is the game.

---

## Setup (once per device)

**Onboarding** — three short screens:
1. Pick a display name.
2. Take an **enrollment selfie**. The face embedding from this selfie is what opponents have to match in-round.
3. Accept the consent screen — players are told the viewfinder stays live for the entire round, not just at shutter press.

After that, the app remembers you. You skip straight to the home screen on subsequent launches.

---

## Lobby flow

- **Host:** taps *Create lobby*. Gets a 6-character join code + a QR code. Lands in the waiting room.
- **Joiners:** tap *Join lobby*, either type the code or scan the QR.
- **Waiting room** shows the live player list. The **host** can tweak the rules:
  - Starting lives (e.g. 3)
  - Round duration (e.g. 5 minutes)
  - Immunity seconds after being hit (e.g. 10s)
- Once >= 2 players are in, the host hits **Start**. Everyone is auto-routed into the round simultaneously.
- If the app is killed mid-round, **auto-rejoin** drops you back into the lobby/round you were in — you don't lose your spot.

---

## The round (the actual game)

The screen orientation is locked to portrait. The entire screen is a live `CameraPreview` from the rear camera. The HUD floats on top in a translucent layer.

### Layout

```
┌──────────────────────────────────┐
│ ♥ ♥ ♥          00:42             │  <- top-left: lives   top-center: timer
│                                  │
│                                  │
│         ╭─────────────╮          │
│         │             │          │  <- live face-detection reticle
│         │   reticle   │          │     (green when locked, white otherwise)
│         │             │          │
│         ╰─────────────╯          │
│                                  │
│      [live kill feed toast]      │  <- e.g. "Alice → Bob (2 left)"
│                                  │
│                                  │
│                                  │
│                                  │
│             (   ◉   )            │  <- bottom-center: shutter button
│                                  │     with cooldown ring
│   ▒▒▒▒ tap-to-fire zone ▒▒▒▒    │  <- entire bottom half = shoot
└──────────────────────────────────┘
```

### HUD elements

- **Top-left — Lives.** Heart icons (one per remaining life). When a life is lost, a heart animates out (shake + fade). When you're eliminated they all go grey.
- **Top-center — Timer.** Large mm:ss countdown.
  - White-on-translucent under normal play.
  - Amber under 60s.
  - Red and pulsing under 10s, with an optional ambient tick sound.
- **Top-right (subtle) — Opponents alive count + scoreboard icon.** Swipe up anywhere or tap the icon to peek at the live scoreboard sheet.
- **Bottom-center — Shutter button.** Big circular button. A **cooldown ring** sweeps around it while the per-shooter cooldown is active (replaces the "Slow down" toast).
- **Bottom half of screen — invisible tap-to-fire zone.** Tapping anywhere in the bottom half also fires. To prevent pocket-grip / accidental fires:
  - The tap zone only activates **after the cooldown ring completes**, AND
  - Only when a face is detected in the live preview (the reticle is showing).

### Aiming & feedback

- **Live face-detection reticle.** ML Kit runs on a throttled subset of preview frames (e.g. every Nth frame) and draws a reticle around any detected face.
  - Reticle is **white** by default.
  - Turns **green** when a face is centered and large enough that a match is likely — an aim-assist signal that doesn't reveal *who* the face is.
- **Haptics on every verdict.**
  - Light tick on shutter press.
  - Success bump on **hit**.
  - Double-thud on **elimination**.
  - Soft buzz on **miss**.
- **Audio cues** (mute toggle in a corner for stealth players):
  - Shutter click on fire.
  - Hit ding / miss thud / elimination sting.
  - Ambient ticking in the last 10s.

### Tagging a player

You physically chase / sneak up on / ambush another player and frame their face in the viewfinder.

1. Center their face in the reticle. Wait for the reticle to go green (optional but recommended).
2. **Fire** by tapping the shutter button OR tapping anywhere in the bottom half of the screen.
3. **On-device:** ML Kit looks for a face in the captured frame.
   - **No face detected** -> instant "No face detected" toast. No server call, no cooldown wasted.
4. If a face is found, MobileFaceNet computes its embedding, and the app calls the `submitTag` Cloud Function with `{lobbyId, tagId, embedding, modelVersion}`.
5. The server compares your embedding against every alive player's enrollment embedding (cosine similarity vs. a tunable threshold) and returns one of four verdicts:

| Verdict | Meaning | Effect |
|---|---|---|
| **Hit** | Match above threshold | Victim loses 1 life. If their lives hit 0 -> eliminated. Toast: "You hit X — N lives left." or "You eliminated your target!" |
| **No match** | No alive player matched | "No match. (Cooldown 5s)" — cooldown ring starts on the shutter. |
| **Immune** | Target was hit very recently | "Target is immune. Try again soon." |
| **Cooldown** | You're shooting too fast | Visual: cooldown ring still sweeping. Toast suppressed (the ring already says it). |

6. **Borderline matches** (similarity near the threshold) flag the photo for retention — it's uploaded to Storage so the system can audit/tune the threshold later. Otherwise the photo never leaves your phone.

### When *you* get tagged

Currently silent until the scoreboard updates. The immersive version makes hits to you tangible:

- **Red flash** across the screen.
- **Camera shake** animation on the viewfinder.
- **Heart pulse-out** in the top-left lives counter.
- **Vibration buzz**.
- Triggered by an FCM "you-were-hit" push or the players-stream lives delta.

### Mechanics that shape play

- **Lives** — a buffer; you survive a few hits. Run out -> you're **eliminated**:
  - Viewfinder desaturates to grayscale.
  - Shutter button disables.
  - "ELIMINATED — spectating" banner pins to the top.
  - Scoreboard remains accessible.
- **Immunity window** — right after being hit, you can't be tagged again for a few seconds. Stops one player from camping a victim and farming hits.
- **Per-shooter cooldown** — you can't spam the shutter; misses cost you tempo. Visualised as the cooldown ring around the shutter.
- **Live kill feed.** As hits happen anywhere in the lobby, fading toasts surface near the bottom HUD: "Alice → Bob (2 left)", "Carol eliminated Dave". Makes the lobby feel alive instead of silent-until-scoreboard.
- **Live scoreboard** — swipe up any time to see who's still alive, who's hurt, who's already out.

### Round-start cinematic

Before the round goes hot, the viewfinder dims and a **3-2-1 countdown** plays full-screen. This sets the tone, gives the camera a moment to focus and warm up, and synchronises everyone's start.

---

## End of round

Two ways the round ends:
1. **Timer expires** — any client whose timer hits zero calls `endRound` (idempotent server-side, so the race is fine).
2. **Last one alive** — comes online in Phase 2 of the plan; in v1 the timer is the primary terminator.

Everyone is auto-routed to the **results screen**: final scoreboard, ranking, who eliminated whom. From there you head back home and can start another lobby.

### End-of-round montage

Results page opens with a quick reel of the round's kept photos — borderline retentions plus elimination shots, if you choose to retain those. Huge replay/share value, and turns the retained-photo policy into a feature instead of a privacy footnote.

---

## Vibe

It's basically **laser tag, except the gun is your phone camera and the hit detection is a face-recognition model** — and the whole game is played through the live viewfinder. The interesting design tension is physical: you have to get close enough to get a clean face shot, but close enough means *they* can shoot *you* too. Lighting, angles, and footwork matter. The HUD-on-viewfinder + haptics + live kill feed make the loop feel punchy and continuous: you never leave the world to "use the camera" — you *are* in the camera the entire round.

---

## Implementation notes

- **`image_picker` -> `camera` package.** The current shutter path opens the system camera sheet via `image_picker`. The immersive build replaces it with a long-lived `CameraController` + `CameraPreview` that owns the lifecycle for the whole round.
  - Pause on `AppLifecycleState.inactive`, resume on `resumed`, dispose on screen exit.
  - The injectable `pickPhoto` boundary in `RoundScreen` becomes a `captureFrame()` against the live controller; tests get a fake camera controller.
- **Throttled face-detection on preview frames.** ML Kit on every frame is too expensive on low-end Android. Sample every Nth frame and skip if the previous detection is still in flight.
- **Battery / thermal cost.** Always-on camera is fine for a 5–10 min round; longer rounds will heat up phones and may drop preview FPS. Watch p95 on a Pixel 4a / Galaxy A-series and degrade gracefully (lower preview resolution, reduce face-detection frequency).
- **Privacy posture.** "Camera always on for the duration of the round" must be reflected in the consent screen copy.
- **Accidental-fire guard.** The bottom-half tap zone is gated on (cooldown complete) AND (face detected in preview), to avoid pocket-grip burning shots.

## Suggested ship order

1. Core: live preview + HUD layout (lives top-left, timer top-center, shutter bottom-center) + tap-to-shoot bottom-half zone.
2. Cooldown ring + haptics + timer urgency ramp (cheap, huge feel uplift).
3. Live face-detection reticle (the headline immersion feature).
4. "You got hit" feedback — flash + shake + heart pulse + vibration.
5. Live kill feed toasts.
6. Round-start 3-2-1 cinematic + eliminated state (grayscale viewfinder, disabled shutter, spectator banner).
7. End-of-round photo montage.

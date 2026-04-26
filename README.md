# Snapshot

Mobile multiplayer photo-tag game. Players in the same physical area join a lobby; during a round they tag each other by taking a photo with their phone camera, which deducts a life from the photographed player. Last player(s) alive win.

## Status

v1 MVP — friends/family scope. See [`tech-plan.md`](./tech-plan.md) for the full plan, key decisions, and milestones.

## Stack

- **Client:** Flutter (iOS + Android, single codebase)
- **Backend:** Firebase (Auth, Firestore, Cloud Functions, Storage, FCM, Remote Config) — region `asia-southeast1`
- **Face pipeline (on-device):** ML Kit Face Detection (detect & crop) → MobileFaceNet via TFLite (embed)

## Local development

### Prerequisites

- Flutter SDK 3.38.x stable (`flutter --version`)
- Node.js 20+ (for Cloud Functions)
- Firebase CLI (`npm install -g firebase-tools`)
- Xcode (for iOS builds) / Android Studio + SDK (for Android builds)

### Run the Flutter app

```bash
flutter pub get
flutter run
```

The app currently shows a Phase 0 placeholder home with a *Try onboarding (demo mode)* button — that runs the onboarding flow against in-memory fakes (no Firebase, no real face model needed) so the UI can be hand-tested before production wiring lands.

### Tests

```bash
# Flutter unit + widget tests
flutter analyze
flutter test

# Cloud Functions tests
cd functions
npm install
npm test
```

### Local Firebase emulator

After running `flutterfire configure` (see Phase 0 followups below):

```bash
firebase emulators:start
```

Auth (9099), Firestore (8080), Functions (5001), Storage (9199), and the Emulator UI are all wired up via `firebase.json`.

## Repository layout

```
lib/
  face/                 — FaceEmbedder interface + MobileFaceNet + ML Kit pipeline
  models/               — Plain-data classes (UserProfile, …)
  onboarding/           — Three-screen onboarding flow + orchestrator
  services/             — Service interfaces + test fakes
functions/              — TypeScript Cloud Functions
  src/deleteUserData.ts — per tech-plan.md §5.10
firestore.rules         — Firestore security rules (Phase 0: users only)
storage.rules           — Cloud Storage rules (Phase 0: selfies only)
firestore.indexes.json  — composite index on tags.resolvedTargetUid
remoteconfig.template.json — tag_match_threshold + borderline_half_width defaults
firebase.json           — emulator + deploy config
tools/fetch_model.sh    — sourcing script for the MobileFaceNet TFLite asset
```

## Phase 0 manual followups

These steps require interactive auth, physical hardware, or external decisions and aren't automated by CI:

- [ ] **Firebase project**: create in `asia-southeast1` and link via `firebase use --add`.
- [ ] **`flutterfire configure`**: generates `lib/firebase_options.dart` and the platform config files (`google-services.json`, `GoogleService-Info.plist`). Required before adding `firebase_*` packages to the Flutter app.
- [ ] **Production wiring follow-up PR**: add `firebase_core` / `firebase_auth` / `cloud_firestore` / `firebase_storage` deps, write the concrete `FirebaseAuthBootstrap` + `FirestoreUserRepository`, and replace `_PlaceholderHome` in `main.dart` with the real bootstrap.
- [ ] **Deploy**: `firebase deploy --only firestore:rules,storage:rules,firestore:indexes,remoteconfig,functions`.
- [ ] **Storage lifecycle rule**: configure the 30-day auto-delete on the `tags/` prefix in the GCS console (per §5.9; not expressible in `storage.rules`).
- [ ] **MobileFaceNet asset**: pin a verified Apache-2.0 mirror in `tools/fetch_model.sh` (`MODEL_URL` + `MODEL_SHA256`) and drop the binary at `assets/models/mobilefacenet.tflite`.
- [ ] **Latency gate**: run on a low-end Android (Pixel 4a / Galaxy A-series). On-device pipeline p95 must be <300ms. If it isn't, swap to the quantized embedder per §5.7.

## License

TBD.

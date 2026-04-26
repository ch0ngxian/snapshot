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

### Run the app

```bash
flutter pub get
flutter run
```

### Tests

```bash
flutter analyze
flutter test
```

## Phase 0 manual followups

These steps require interactive auth or physical hardware and aren't automated by CI:

- [ ] Create the Firebase project in `asia-southeast1` and link it via `firebase use`.
- [ ] Run `firebase deploy --only firestore:rules,storage:rules,firestore:indexes,remoteconfig,functions` once PR #3 lands.
- [ ] Configure Cloud Storage 30-day lifecycle rule on the `tags/` prefix (per §5.9 of the plan).
- [ ] Run the latency gate on a low-end Android (Pixel 4a / Galaxy A-series): on-device pipeline p95 must be <300ms. If it isn't, swap to the quantized embedder per §5.7.

## License

TBD.

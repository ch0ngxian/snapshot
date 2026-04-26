# MobileFaceNet TFLite asset

The file `mobilefacenet.tflite` in this directory is a third-party model used
for on-device face embedding (per tech-plan.md §5.7).

## Source

- Reference repo: <https://github.com/sirius-ai/MobileFaceNet_TF>
- License: Apache 2.0
- Build pipeline: `tools/build_model.py` (downloads upstream frozen graph, converts to tflite)
- Hosted on this repo's GitHub Release [`model/mobilefacenet-v1`](https://github.com/ch0ngxian/snapshot/releases/tag/model/mobilefacenet-v1)
- Fetched at setup time via `tools/fetch_model.sh` (default = float32; `VARIANT=q` for int8 dynamic-range)

## Model contract

The Dart pipeline in `lib/face/mobilefacenet_embedder.dart` expects:

| Field        | Value                                                |
|--------------|------------------------------------------------------|
| Input shape  | `1 × 112 × 112 × 3` (NHWC)                           |
| Input dtype  | `float32`, normalized to `[-1, 1]` (`(p − 127.5) / 127.5`) |
| Output shape | `1 × 128`                                            |
| Output dtype | `float32` (L2-normalized before cosine compare)      |

Any drop-in replacement must match this contract or `mobilefacenet_embedder.dart`
will need updating, plus a `modelVersion` bump to a new identifier.

## Status

The binary is not committed to the repo (`*.tflite` is gitignored). Run
`bash tools/fetch_model.sh` after cloning to pull the float32 variant
(`mobilefacenet-v1`) from the pinned GitHub Release; the script verifies
SHA256 before placing the file at `assets/models/mobilefacenet.tflite`.
Then `flutter pub get && flutter run`.

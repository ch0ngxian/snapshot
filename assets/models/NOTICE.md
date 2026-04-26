# MobileFaceNet TFLite asset

The file `mobilefacenet.tflite` in this directory is a third-party model used
for on-device face embedding (per tech-plan.md §5.7).

## Source

- Reference repo: <https://github.com/sirius-ai/MobileFaceNet_TF>
- License: Apache 2.0
- Sourcing: see `tools/fetch_model.sh`

## Model contract

The Dart pipeline in `lib/face/mobilefacenet_embedder.dart` expects:

| Field        | Value                                                |
|--------------|------------------------------------------------------|
| Input shape  | `1 × 112 × 112 × 3` (NHWC)                           |
| Input dtype  | `float32`, normalized to `[-1, 1]` (`(p − 127.5) / 127.5`) |
| Output shape | `1 × 192`                                            |
| Output dtype | `float32` (L2-normalized before cosine compare)      |

Any drop-in replacement must match this contract or `mobilefacenet_embedder.dart`
will need updating, plus a `modelVersion` bump to a new identifier.

## Status

The binary is intentionally not committed yet — see `tools/fetch_model.sh` for
the fetching plan. Until that script's `MODEL_URL` and `MODEL_SHA256` are pinned
to a verified Apache-2.0 mirror, drop a compatible file here manually and rerun
`flutter pub get`.

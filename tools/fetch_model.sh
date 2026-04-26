#!/usr/bin/env bash
#
# Fetches the MobileFaceNet TFLite model into assets/models/mobilefacenet.tflite.
#
# Per tech-plan.md §5.7, the v1 model is locked to MobileFaceNet (Apache-2.0).
# Reference repo: https://github.com/sirius-ai/MobileFaceNet_TF
# Build pipeline: tools/build_model.py
#
# Expected model contract:
#   input  : 1 × 112 × 112 × 3 NHWC float32, normalized to [-1, 1]
#   output : 1 × 128 float32 (L2-normalize before cosine compare)
#
# Variants hosted on the repo's GitHub Release `model/mobilefacenet-v1`:
#
#   default (this script):  mobilefacenet.tflite       — float32, ~5 MB
#                                                        modelVersion = mobilefacenet-v1
#
#   alternate:              mobilefacenet-v1-q.tflite  — int8 dynamic-range, ~1.5 MB
#                                                        modelVersion = mobilefacenet-v1-q
#
# Per §314, ship the float32 variant first. Switch to the quantized variant
# (set VARIANT=q below) only if the latency gate (p95 > 300 ms on a low-end
# Android) demands it — that swap is *not* silent: bump the embedder's
# modelVersion stamp at the same time.
#
# Usage:
#   bash tools/fetch_model.sh           # float32 (default)
#   VARIANT=q bash tools/fetch_model.sh # int8 dynamic-range

set -euo pipefail

DEST="assets/models/mobilefacenet.tflite"
RELEASE_BASE="https://github.com/ch0ngxian/snapshot/releases/download/model/mobilefacenet-v1"

case "${VARIANT:-}" in
  ""|f32|float32)
    MODEL_URL="$RELEASE_BASE/mobilefacenet.tflite"
    MODEL_SHA256="fc7cd9723fa9dcbc5d59024c930deb328db65a38dd1b5713dec5e40d76ab468f"
    ;;
  q|int8|quantized)
    MODEL_URL="$RELEASE_BASE/mobilefacenet-v1-q.tflite"
    MODEL_SHA256="1d4b0d5b5cc3b9d93ae97ce8abf01a46f187e034ab3c52be60597950cb6cf126"
    ;;
  *)
    echo "tools/fetch_model.sh: unknown VARIANT=$VARIANT (expected: f32, q)" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$DEST")"

curl --fail --location --silent --show-error --output "$DEST" "$MODEL_URL"

actual_sha=$(shasum -a 256 "$DEST" | awk '{print $1}')
if [[ "$actual_sha" != "$MODEL_SHA256" ]]; then
  echo "tools/fetch_model.sh: checksum mismatch" >&2
  echo "  expected: $MODEL_SHA256" >&2
  echo "  actual:   $actual_sha" >&2
  rm -f "$DEST"
  exit 1
fi

echo "Fetched MobileFaceNet TFLite to $DEST"

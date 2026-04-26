#!/usr/bin/env bash
#
# Fetches the MobileFaceNet TFLite model into assets/models/mobilefacenet.tflite.
#
# Per tech-plan.md §5.7, the v1 model is locked to MobileFaceNet (Apache-2.0).
# Reference repo: https://github.com/sirius-ai/MobileFaceNet_TF
#
# IMPORTANT: a stable Apache-2.0-licensed pre-converted .tflite mirror has not
# yet been pinned for this repo. Until MODEL_URL + MODEL_SHA256 below are
# filled in, drop a compatible model file at the destination path manually.
#
# Expected model contract:
#   input  : 1 × 112 × 112 × 3 NHWC float32, normalized to [-1, 1]
#   output : 1 × 128 float32 (L2-normalize before cosine compare)
#
# Usage: bash tools/fetch_model.sh

set -euo pipefail

DEST="assets/models/mobilefacenet.tflite"
MODEL_URL=""        # TODO: pin to a stable Apache-2.0 mirror
MODEL_SHA256=""     # TODO: pin checksum once URL is chosen

mkdir -p "$(dirname "$DEST")"

if [[ -z "$MODEL_URL" || -z "$MODEL_SHA256" ]]; then
  echo "tools/fetch_model.sh: MODEL_URL / MODEL_SHA256 not yet pinned." >&2
  echo "Drop a compatible mobilefacenet.tflite at $DEST manually." >&2
  echo "See assets/models/NOTICE.md for the model contract." >&2
  exit 1
fi

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

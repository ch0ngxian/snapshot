#!/usr/bin/env python3
"""Convert sirius-ai/MobileFaceNet_TF's pretrained frozen graph to TFLite.

Reference repo: https://github.com/sirius-ai/MobileFaceNet_TF
License: Apache-2.0

Outputs (under assets/models/):
  mobilefacenet.tflite       — float32, matches modelVersion = 'mobilefacenet-v1'
  mobilefacenet-v1-q.tflite  — int8 dynamic-range, matches 'mobilefacenet-v1-q'

Both produce 1×128 L2-normalizable embeddings from a 1×112×112×3 input
in NHWC float32 normalized to [-1, 1]. The Dart pipeline in
lib/face/mobilefacenet_embedder.dart applies the L2 normalization itself
on the output, so we don't bake it into the graph here.

Setup:
  python3 -m venv tools/.venv-build
  source tools/.venv-build/bin/activate
  pip install --upgrade pip
  pip install "tensorflow>=2.15" numpy
  python tools/build_model.py
"""

from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path

import tensorflow as tf  # type: ignore[import-untyped]

# sirius-ai's pretrained frozen graph (raw GitHub URL).
# If this 404s, the repo may have moved the file — update PB_URL.
PB_URL = (
    "https://github.com/sirius-ai/MobileFaceNet_TF/raw/master/"
    "arch/pretrained_model/MobileFaceNet_9925_9680.pb"
)

# Input/output tensor names in the frozen graph (sirius-ai convention).
# Verify via Netron if conversion errors out on missing names.
INPUT_NAME = "img_inputs"
OUTPUT_NAME = "embeddings"
INPUT_SHAPE = (1, 112, 112, 3)
EXPECTED_OUTPUT_SHAPE = (1, 128)

REPO_ROOT = Path(__file__).resolve().parent.parent
WORK_DIR = REPO_ROOT / "tools" / ".build-model"
ASSETS_DIR = REPO_ROOT / "assets" / "models"


def fetch_pb() -> Path:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    pb_path = WORK_DIR / "mobilefacenet.pb"
    if pb_path.exists():
        print(f"  cached: {pb_path} ({pb_path.stat().st_size / 1024:.1f} KB)")
        return pb_path
    print(f"  downloading {PB_URL}")
    urllib.request.urlretrieve(PB_URL, pb_path)
    print(f"  saved {pb_path.stat().st_size / 1024:.1f} KB to {pb_path}")
    return pb_path


def convert_to_tflite(pb_path: Path, *, quantize: bool, out: Path) -> None:
    converter = tf.compat.v1.lite.TFLiteConverter.from_frozen_graph(
        graph_def_file=str(pb_path),
        input_arrays=[INPUT_NAME],
        output_arrays=[OUTPUT_NAME],
        input_shapes={INPUT_NAME: list(INPUT_SHAPE)},
    )
    if quantize:
        # Dynamic-range quantization: weights → int8, activations → float at
        # runtime. No representative dataset needed; ~75% smaller, ~1.5×
        # faster on CPU, sub-1% accuracy hit on most architectures.
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_bytes = converter.convert()
    out.write_bytes(tflite_bytes)
    print(f"  wrote {len(tflite_bytes) / 1024:.1f} KB to {out}")


def verify(tflite_path: Path) -> None:
    interp = tf.lite.Interpreter(model_path=str(tflite_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    print(f"  input:  shape={tuple(inp['shape'])} dtype={inp['dtype'].__name__}")
    print(f"  output: shape={tuple(out['shape'])} dtype={out['dtype'].__name__}")
    assert tuple(inp["shape"]) == INPUT_SHAPE, (
        f"input shape mismatch: got {tuple(inp['shape'])}, expected {INPUT_SHAPE}"
    )
    assert tuple(out["shape"]) == EXPECTED_OUTPUT_SHAPE, (
        f"output shape mismatch: got {tuple(out['shape'])}, "
        f"expected {EXPECTED_OUTPUT_SHAPE}"
    )
    digest = hashlib.sha256(tflite_path.read_bytes()).hexdigest()
    print(f"  sha256: {digest}")


def main() -> int:
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"TensorFlow {tf.__version__}")
    print("\n[1/3] fetch frozen graph")
    pb_path = fetch_pb()

    print("\n[2/3] mobilefacenet-v1 (float32)")
    f32_out = ASSETS_DIR / "mobilefacenet.tflite"
    convert_to_tflite(pb_path, quantize=False, out=f32_out)
    verify(f32_out)

    print("\n[3/3] mobilefacenet-v1-q (int8 dynamic-range)")
    q_out = ASSETS_DIR / "mobilefacenet-v1-q.tflite"
    convert_to_tflite(pb_path, quantize=True, out=q_out)
    verify(q_out)

    print("\nDone. Both .tflite files are ready under assets/models/.")
    print(
        "Next: upload to a GitHub Release on this repo (or another stable\n"
        "      Apache-2.0 mirror) and pin MODEL_URL + MODEL_SHA256 in\n"
        "      tools/fetch_model.sh."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

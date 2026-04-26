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
from pathlib import Path

import numpy as np
import requests  # type: ignore[import-untyped]
import tensorflow as tf  # type: ignore[import-untyped]

# sirius-ai's pretrained frozen graph (raw GitHub URL) + checksum pin.
# If the upstream file ever changes the checksum mismatch will halt the build
# (supply-chain boundary — don't trust whatever GitHub serves on a given day).
# To bump: update PB_URL, run once with PB_SHA256="" to print the new digest,
# then paste it here.
PB_URL = (
    "https://github.com/sirius-ai/MobileFaceNet_TF/raw/master/"
    "arch/pretrained_model/MobileFaceNet_9925_9680.pb"
)
PB_SHA256 = "fb046e5f723a70020962c6772a08c3c915a443ca19aaade732c2b84eea613f09"

# Input/output tensor names in the frozen graph (sirius-ai convention).
# Verify via Netron if conversion errors out on missing names.
INPUT_NAME = "img_inputs"
OUTPUT_NAME = "embeddings"
INPUT_SHAPE = (1, 112, 112, 3)
EXPECTED_OUTPUT_SHAPE = (1, 128)
EXPECTED_DTYPE = np.float32

REPO_ROOT = Path(__file__).resolve().parent.parent
WORK_DIR = REPO_ROOT / "tools" / ".build-model"
ASSETS_DIR = REPO_ROOT / "assets" / "models"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_pb() -> Path:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    pb_path = WORK_DIR / "mobilefacenet.pb"
    tmp_path = WORK_DIR / "mobilefacenet.pb.tmp"

    if pb_path.exists():
        cached_sha = _sha256(pb_path)
        if cached_sha == PB_SHA256:
            print(f"  cached: {pb_path} ({pb_path.stat().st_size / 1024:.1f} KB)")
            return pb_path
        print(f"  cached file has wrong sha256 ({cached_sha}), re-downloading")
        pb_path.unlink()

    print(f"  downloading {PB_URL}")
    # Two reasons we don't use `urllib.request.urlretrieve` here:
    #   1. macOS Python.framework doesn't auto-trust system root certs;
    #      `requests` ships its own certifi bundle.
    #   2. We want atomic-on-success semantics — write to a .tmp path, verify
    #      the checksum, then rename. A partial download (Ctrl-C, network
    #      drop) leaves only the .tmp behind, which the next run re-fetches.
    if tmp_path.exists():
        tmp_path.unlink()
    try:
        resp = requests.get(PB_URL, stream=True, timeout=60)
        resp.raise_for_status()
        with tmp_path.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1 << 20):
                if chunk:
                    f.write(chunk)
        actual_sha = _sha256(tmp_path)
        if PB_SHA256 and actual_sha != PB_SHA256:
            raise RuntimeError(
                f"upstream .pb checksum mismatch (supply-chain check): "
                f"expected {PB_SHA256}, got {actual_sha}. "
                f"Either the upstream repo updated the file or the download "
                f"was corrupted. Verify the new digest before pinning."
            )
        if not PB_SHA256:
            print(f"  (no PB_SHA256 pinned yet; observed digest: {actual_sha})")
        tmp_path.replace(pb_path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

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
    # `assert` is wrong here — `python -O` strips them. These are contract
    # checks at a build-time supply-chain boundary, so they must always run.
    interp = tf.lite.Interpreter(model_path=str(tflite_path))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    in_shape = tuple(inp["shape"])
    out_shape = tuple(out["shape"])
    in_dtype = inp["dtype"]
    out_dtype = out["dtype"]
    print(f"  input:  shape={in_shape} dtype={in_dtype.__name__}")
    print(f"  output: shape={out_shape} dtype={out_dtype.__name__}")

    if in_shape != INPUT_SHAPE:
        raise ValueError(
            f"input shape mismatch: got {in_shape}, expected {INPUT_SHAPE}"
        )
    if out_shape != EXPECTED_OUTPUT_SHAPE:
        raise ValueError(
            f"output shape mismatch: got {out_shape}, "
            f"expected {EXPECTED_OUTPUT_SHAPE}"
        )
    # Dynamic-range quantization keeps I/O float32 (only weights go int8).
    # Full int8 quantization would change these dtypes — guard against
    # accidentally producing a model the Dart pipeline can't feed.
    if in_dtype != EXPECTED_DTYPE:
        raise ValueError(
            f"input dtype mismatch: got {in_dtype}, expected {EXPECTED_DTYPE}"
        )
    if out_dtype != EXPECTED_DTYPE:
        raise ValueError(
            f"output dtype mismatch: got {out_dtype}, expected {EXPECTED_DTYPE}"
        )

    digest = _sha256(tflite_path)
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

#!/usr/bin/env python3
"""
Shrink neucodec_decoder.safetensors to BF16 weights.

The neutts Rust loader upcasts BF16 tensors to f32 at load time
(src/codec.rs: F32 or BF16 accepted), so re-quantising the fp32
conversion output halves the voice-pack download with no runtime change.
Hyper-parameter metadata is copied verbatim.

Usage (needs a venv with: safetensors numpy ml_dtypes):

    python tool/shrink_neucodec_bf16.py <decoder.safetensors>
"""
import sys

import numpy as np
from ml_dtypes import bfloat16
from safetensors import safe_open
from safetensors.numpy import save_file


def to_bf16(x: np.ndarray) -> np.ndarray:
    """Round-to-nearest-even truncation fp32 -> bf16 via integer math."""
    u = x.astype(np.float32).view(np.uint32).astype(np.uint64)
    lsb = (u >> 16) & np.uint64(1)  # tie-to-even
    r = (u + np.uint64(0x7FFF) + lsb) & np.uint64(0xFFFF0000)
    r >>= np.uint64(16)
    return r.astype("<u2").view(bfloat16)


def main() -> None:
    path = sys.argv[1]
    with safe_open(path, framework="np") as f:
        metadata = f.metadata() or {}
        tensors = {k: to_bf16(f.get_tensor(k)) for k in f.keys()}
    save_file(tensors, path, metadata=metadata)  # in-place
    print(f"{path}: {len(tensors)} tensors -> BF16")


if __name__ == "__main__":
    main()

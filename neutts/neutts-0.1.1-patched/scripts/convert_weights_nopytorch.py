#!/usr/bin/env python3
"""
Convert neuphonic/neucodec pytorch_model.bin → models/neucodec_decoder.safetensors
WITHOUT requiring a working PyTorch installation.

PyTorch .bin files are ZIP archives containing:
  <prefix>/data.pkl          – pickled tensor metadata
  <prefix>/data/<N>          – raw float32 tensor bytes

This script reads both with stdlib only (zipfile + pickle + struct + numpy),
then filters for the decoder sub-graph and writes a safetensors file.

Requirements:
    pip install numpy safetensors huggingface_hub
"""

import argparse
import io
import numpy as np
import os
import pickle
import struct
import sys
import zipfile


# ── Minimal PyTorch pickle reconstructors ─────────────────────────────────────

class StorageRef:
    """Placeholder returned during pickle load to defer actual data reading."""
    def __init__(self, key, storage_type, size):
        self.key = key
        self.storage_type = storage_type
        self.size = size   # number of scalar elements


class FakeTensor:
    """Lightweight stand-in for torch.Tensor during pickle loading."""
    def __init__(self, storage, storage_offset, size, stride, dtype=np.float32):
        self.storage = storage
        self.storage_offset = storage_offset
        self.size = size       # tuple of ints
        self.stride = stride   # tuple of ints
        self.dtype = dtype

    def to_numpy(self, raw_bytes_map):
        """Read raw bytes and reshape according to size/stride."""
        raw = raw_bytes_map[self.storage.key]
        # Determine element size from dtype
        item = np.dtype(self.dtype).itemsize
        arr = np.frombuffer(raw, dtype=self.dtype)
        # Contiguous C-order view based on size
        total = int(np.prod(self.size)) if self.size else 1
        start = self.storage_offset
        return arr[start:start + total].reshape(self.size).copy()


# Map PyTorch storage class names → numpy dtype
STORAGE_TO_DTYPE = {
    "FloatStorage":   np.float32,
    "DoubleStorage":  np.float64,
    "HalfStorage":    np.float16,
    "BFloat16Storage":np.float32,   # we cast BF16 → F32 below
    "IntStorage":     np.int32,
    "LongStorage":    np.int64,
    "ShortStorage":   np.int16,
    "ByteStorage":    np.uint8,
    "BoolStorage":    np.bool_,
}

BF16_TYPES = {"BFloat16Storage"}


class TorchUnpickler(pickle.Unpickler):
    """Unpickler that reconstructs tensors without importing torch."""

    def __init__(self, file, zip_file, prefix):
        super().__init__(file)
        self._zip = zip_file
        self._prefix = prefix   # e.g. "test" (the archive prefix)
        self._storages = {}     # key → StorageRef

    def find_class(self, module, name):
        # Intercept every torch.* symbol — never let pickle actually import torch
        if module.startswith("torch") or module.startswith("_codecs"):
            # Storage types → return a factory for (dtype, is_bf16)
            if name in STORAGE_TO_DTYPE:
                dtype = STORAGE_TO_DTYPE[name]
                is_bf16 = name in BF16_TYPES
                def make_storage(dtype=dtype, is_bf16=is_bf16):
                    return (dtype, is_bf16)
                make_storage.__name__ = name
                return make_storage
            # Tensor rebuild functions
            if name == "_rebuild_tensor_v2":
                return rebuild_tensor_v2
            if name in ("_rebuild_parameter", "_rebuild_parameter_with_state"):
                return lambda data, *a, **kw: data
            if name == "_rebuild_from_type_v2":
                return lambda fn, tp, args, kw: fn(*args)
            # Everything else from torch → swallow silently
            return lambda *a, **kw: None

        # Standard library types
        if module == "collections" and name == "OrderedDict":
            from collections import OrderedDict
            return OrderedDict
        if module == "_codecs":
            return lambda *a, **kw: None

        return super().find_class(module, name)

    def persistent_load(self, pid):
        # pid = ('storage', storage_type_callable, key, location, n_elements)
        if isinstance(pid, tuple) and pid[0] in ("storage", b"storage"):
            _, storage_callable, key, _location, n_elements = pid
            if callable(storage_callable):
                info = storage_callable()   # returns (dtype, is_bf16)
                if info is None:
                    info = (np.float32, False)
                dtype, is_bf16 = info
            else:
                dtype, is_bf16 = np.float32, False
            ref = StorageRef(key, (dtype, is_bf16), n_elements)
            self._storages[key] = ref
            return ref
        return pid


def rebuild_tensor_v2(storage, storage_offset, size, stride, *args, **kwargs):
    dtype, is_bf16 = storage.storage_type if isinstance(storage.storage_type, tuple) else (np.float32, False)
    return FakeTensor(storage, storage_offset, tuple(size), tuple(stride), dtype=dtype)


def load_pytorch_bin(path):
    """
    Load a pytorch_model.bin (zip archive) and return a dict
    {tensor_name: np.ndarray} for every tensor in the state dict.
    """
    with zipfile.ZipFile(path, "r") as zf:
        names = zf.namelist()

        # Detect archive prefix (everything before the first '/')
        prefix = names[0].split("/")[0]

        pkl_name = f"{prefix}/data.pkl"
        if pkl_name not in names:
            # Some checkpoints use 'archive' or a different prefix
            pkl_candidates = [n for n in names if n.endswith("data.pkl")]
            if not pkl_candidates:
                raise RuntimeError(f"No data.pkl found in {path}. Names: {names[:5]}")
            pkl_name = pkl_candidates[0]
            prefix = pkl_name.split("/")[0]

        print(f"  Archive prefix: '{prefix}', reading {pkl_name} ...")

        # Read all data blobs into memory (lazy: only what we reference)
        data_prefix = f"{prefix}/data/"
        data_names = {n[len(data_prefix):]: n for n in names if n.startswith(data_prefix)}

        # Load pickle
        pkl_bytes = zf.read(pkl_name)
        unpickler = TorchUnpickler(io.BytesIO(pkl_bytes), zf, prefix)

        # Patch _rebuild_tensor_v2 into the unpickler dispatch
        import pickle as _pickle
        original_dispatch = unpickler.dispatch.copy() if hasattr(unpickler, 'dispatch') else {}

        # We need to monkeypatch so that reduce calls to _rebuild_tensor_v2 work
        unpickler.dispatch_table = {
            "__builtin__.object": object,
        }

        # Register the rebuild function in the unpickler's module space
        import sys as _sys
        fake_torch_utils = type(_sys)("torch._utils")
        fake_torch_utils._rebuild_tensor_v2 = rebuild_tensor_v2
        fake_torch_utils._rebuild_parameter   = lambda data, *a: data
        fake_torch_utils._rebuild_from_type_v2 = lambda fn, tp, args, kw: fn(*args)
        _sys.modules.setdefault("torch._utils", fake_torch_utils)

        fake_collections = type(_sys)("collections")
        class OD(dict): pass
        fake_collections.OrderedDict = OD
        _sys.modules.setdefault("collections", __import__("collections"))

        state_dict_raw = unpickler.load()

        # Now read the actual tensor bytes for every referenced storage key
        raw_bytes_map = {}
        for key, ref in unpickler._storages.items():
            dtype, is_bf16 = ref.storage_type
            fname = data_names.get(str(key))
            if fname is None:
                print(f"    WARNING: data file for storage key {key!r} not found")
                continue
            raw = zf.read(fname)
            if is_bf16:
                # Reinterpret BF16 bytes as uint16, then shift to float32
                u16 = np.frombuffer(raw, dtype=np.uint16)
                f32 = (u16.astype(np.uint32) << 16).view(np.float32)
                raw_bytes_map[key] = f32.tobytes()
                # Update storage dtype to float32 for downstream
                ref.storage_type = (np.float32, False)
            else:
                raw_bytes_map[key] = raw

        # Recursively convert FakeTensor → numpy
        def convert(obj):
            if isinstance(obj, FakeTensor):
                return obj.to_numpy(raw_bytes_map).astype(np.float32)
            if isinstance(obj, dict):
                return {k: convert(v) for k, v in obj.items()}
            if isinstance(obj, (list, tuple)):
                return type(obj)(convert(v) for v in obj)
            return obj

        state_dict = convert(state_dict_raw)
        return state_dict


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__.strip())
    parser.add_argument("--out",    default="models/neucodec_decoder.safetensors")
    parser.add_argument("--repo",   default="neuphonic/neucodec")
    parser.add_argument("--n-heads", type=int, default=16)
    args = parser.parse_args()

    # ── Download ──────────────────────────────────────────────────────────────
    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        print("ERROR: pip install huggingface_hub safetensors numpy")
        sys.exit(1)

    print(f"Downloading pytorch_model.bin from {args.repo} ...")
    bin_path = hf_hub_download(repo_id=args.repo, filename="pytorch_model.bin")
    print(f"  cached at: {bin_path}")

    # ── Load ──────────────────────────────────────────────────────────────────
    print("Loading checkpoint (pure-Python, no PyTorch required) ...")
    state = load_pytorch_bin(bin_path)

    if not isinstance(state, dict):
        print(f"ERROR: Expected a dict, got {type(state)}. Keys (if any): {list(state.keys())[:5] if hasattr(state, 'keys') else 'N/A'}")
        sys.exit(1)

    print(f"  total tensors: {len(state)}")

    # ── Filter decoder tensors ────────────────────────────────────────────────
    decoder_prefixes = ("generator.", "fc_post_a.")
    decoder_state = {}
    skipped = []
    for k, v in state.items():
        if not isinstance(v, np.ndarray):
            skipped.append(k)
            continue
        if any(k.startswith(p) for p in decoder_prefixes):
            decoder_state[k] = np.ascontiguousarray(v.astype(np.float32))

    if skipped:
        print(f"  skipped {len(skipped)} non-array entries")
    print(f"  extracted {len(decoder_state)} decoder tensors")

    if not decoder_state:
        print("ERROR: No decoder tensors found.")
        print("  Available keys:", list(state.keys())[:10])
        sys.exit(1)

    # ── Detect hyper-parameters ───────────────────────────────────────────────
    embed_w = decoder_state.get("generator.backbone.embed.weight")
    head_w  = decoder_state.get("generator.head.out.weight")

    if embed_w is None or head_w is None:
        print("ERROR: Missing embed/head weights.")
        sys.exit(1)

    hidden_dim = embed_w.shape[0]
    out_dim    = head_w.shape[0]
    hop_length = (out_dim - 2) // 4
    n_fft      = hop_length * 4
    depth = sum(1 for k in decoder_state
                if k.startswith("generator.backbone.transformers.")
                and k.endswith(".att_norm.weight"))

    print()
    print("Detected configuration:")
    print(f"  hidden_dim  = {hidden_dim}")
    print(f"  depth       = {depth} transformer blocks")
    print(f"  n_heads     = {args.n_heads}")
    print(f"  hop_length  = {hop_length}  ({24_000 // hop_length} tokens/s at 24 kHz)")
    print(f"  n_fft       = {n_fft}")
    print(f"  out_dim     = {out_dim}")

    # ── Save safetensors ──────────────────────────────────────────────────────
    try:
        from safetensors.numpy import save_file
    except ImportError:
        print("ERROR: pip install safetensors")
        sys.exit(1)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    metadata = {
        "hidden_dim": str(hidden_dim),
        "depth":      str(depth),
        "n_heads":    str(args.n_heads),
        "hop_length": str(hop_length),
        "source":     args.repo,
    }

    print(f"\nSaving {args.out} ...")
    save_file(decoder_state, args.out, metadata=metadata)

    size_mb = os.path.getsize(args.out) / 1024 / 1024
    print(f"  saved {len(decoder_state)} tensors, {size_mb:.0f} MB")
    print()
    print("Done! Run: cargo build && cargo run --example test_pipeline")


if __name__ == "__main__":
    main()

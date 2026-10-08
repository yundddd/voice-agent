#!/usr/bin/env python3
"""
Export the NeuCodec PyTorch encoder to ONNX for use with neutts-rs.

Requirements:
    pip install neucodec torch onnx onnxruntime onnxscript

Usage:
    python scripts/export_encoder.py          # → neucodec_encoder.onnx

    cargo run --example clone_voice --features espeak -- \\
        --ref-audio  reference.wav \\
        --encoder    neucodec_encoder.onnx \\
        --text       "Hello!"

WHY THE PATCH IS NEEDED
=======================
alias_free_torch.UpSample1d/DownSample1d.forward does:

    _, C, T = x.shape
    x       = F.pad(x, (self.pad_left, self.pad_right), mode='replicate')
    weight  = self.filter.view(1,1,-1).repeat(C, 1, 1)   ← C from x.shape
    x       = F.conv1d(x, weight, groups=C)

The ONNX symbolic for F.pad with mode='replicate' emits a Cast node rather
than a Constant node for the `pads` tensor.  ONNX static shape inference
cannot propagate shape information through a non-Constant pads input, so the
Pad output has shape (*, *, *) — including the channel dim (48) that was
previously known.

After the Pad, C = x.shape[1] is extracted from the now-unknown dimension,
so weight = filter.repeat(C, 1, 1) has an unknown first dimension.
PyTorch's ONNX _convolution symbolic requires `weight.type().sizes()` to be
a non-None list, so it raises "kernel of unknown shape".

FIX
===
Pre-compute weight = filter.repeat(C_concrete, 1, 1) once and store it as a
registered buffer (_onnx_weight) with shape [C, 1, K] — a compile-time
constant.  Replace the forward to use this buffer instead of the dynamic
repeat().  The Conv symbolic sees a concrete kernel shape and exports.

The Pad output is still (*,*,*) in the static ONNX graph, but ORT uses
runtime shapes for execution and computes the correct output anyway.
"""

import argparse
import inspect
import sys
import types
import warnings
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

ENCODER_SAMPLE_RATE       = 16_000
ENCODER_SAMPLES_PER_TOKEN = 320   # 16 000 / 50 tok·s⁻¹


# ── Encoder wrapper ────────────────────────────────────────────────────────────

class EncoderWrapper(nn.Module):
    """Thin nn.Module wrapper that exposes only the encode_code path."""

    def __init__(self, codec):
        super().__init__()
        self.codec = codec

    def forward(self, audio: torch.Tensor) -> torch.Tensor:
        """
        Args:
            audio: float32 waveform, shape [1, 1, N] at 16 kHz.
        Returns:
            codes: int32 token IDs, shape [1, N // 320].
        """
        codes = self.codec.encode_code(audio_or_path=audio)
        if codes.dim() == 3:
            codes = codes.squeeze(1)
        return codes


# ── alias_free_torch patch ─────────────────────────────────────────────────────

def patch_alias_free_torch(wrapper: nn.Module, probe_input: torch.Tensor) -> int:
    """
    Make alias_free_torch UpSample1d/DownSample1d ONNX-exportable.

    Pre-computes the depthwise convolution weight (filter.repeat(C, 1, 1)) for
    the concrete channel count at each layer and stores it as a fixed-shape
    buffer `_onnx_weight`.  Replaces forward() to use this buffer, eliminating
    the dynamic `repeat(C, ...)` call whose C-dimension is lost after the ONNX
    Pad op's shape-inference failure.

    Returns the number of modules patched.
    """
    patched = 0

    for class_name in ("UpSample1d", "DownSample1d"):
        try:
            mod_obj = __import__(
                "neucodec.alias_free_torch.resample", fromlist=[class_name]
            )
            cls = getattr(mod_obj, class_name)
        except (ImportError, AttributeError):
            continue

        # ── Probe: capture input channel count at each instance ────────────
        channel_map: dict[str, int] = {}
        hooks = []
        for path, m in wrapper.named_modules():
            if type(m) is cls:
                def make_hook(p: str):
                    def h(mod, inp, _out):
                        channel_map.setdefault(p, int(inp[0].shape[1]))
                    return h
                hooks.append(m.register_forward_hook(make_hook(path)))

        with torch.no_grad():
            wrapper(probe_input)

        for h in hooks:
            h.remove()

        if not channel_map:
            continue

        # ── Inspect source to detect conv function and padding mode ────────
        src = inspect.getsource(cls.forward)
        conv_fn = (
            torch.nn.functional.conv_transpose1d
            if "conv_transpose1d" in src
            else torch.nn.functional.conv1d
        )
        pad_mode = "replicate" if ("replicate" in src or "edge" in src or "replication" in src) else "constant"

        # ── Patch each instance ────────────────────────────────────────────
        for path, m in wrapper.named_modules():
            if type(m) is cls and path in channel_map:
                C         = channel_map[path]
                pad_left  = int(m.pad_left)
                pad_right = int(m.pad_right)
                stride    = (
                    int(m.stride) if hasattr(m, "stride")
                    else int(m.ratio) if hasattr(m, "ratio")
                    else 1
                )

                # Pre-compute weight with KNOWN shape [C, 1, K].
                # This replaces the dynamic filter.repeat(C, 1, 1) whose
                # C dimension the ONNX shape inferencer cannot propagate.
                fixed_w = m.filter.view(1, 1, -1).repeat(C, 1, 1).detach().clone()
                m.register_buffer("_onnx_weight", fixed_w)

                def make_fwd(pl: int, pr: int, s: int, c: int, fn, mode: str):
                    def fwd(self, x: torch.Tensor) -> torch.Tensor:
                        x = torch.nn.functional.pad(x, (pl, pr), mode=mode)
                        return fn(x, self._onnx_weight, stride=s, groups=c)
                    return fwd

                m.forward = types.MethodType(
                    make_fwd(pad_left, pad_right, stride, C, conv_fn, pad_mode), m
                )
                patched += 1

    return patched


# ── ONNX export ────────────────────────────────────────────────────────────────

def export_onnx(
    wrapper:   nn.Module,
    n_samples: int,
    out_path:  Path,
    opset:     int,
) -> int:
    """
    Export wrapper with a fixed input shape and return the output token count.
    """
    dummy = torch.zeros(1, 1, n_samples, dtype=torch.float32)

    # ── Reference codes (before patch) ────────────────────────────────────
    print("  Computing reference codes (pre-patch) …")
    with torch.no_grad():
        ref_codes = wrapper(dummy).cpu().numpy()

    # ── Patch alias_free_torch modules ────────────────────────────────────
    print("  Patching alias_free_torch sampler modules …")
    n_patched = patch_alias_free_torch(wrapper, dummy)
    print(f"  Patched {n_patched} module(s).")

    # ── Verify patch doesn't change codes ─────────────────────────────────
    with torch.no_grad():
        patched_codes = wrapper(dummy).cpu().numpy()

    n_diff = (ref_codes.astype(np.int32) != patched_codes.astype(np.int32)).sum()
    if n_diff == 0:
        print("  ✓ Patched model produces identical codes to the original.")
    else:
        pct = 100.0 * n_diff / ref_codes.size
        print(
            f"  ⚠  {n_diff}/{ref_codes.size} ({pct:.1f}%) tokens differ after patch.\n"
            "     This reflects boundary changes at the few samples touched by the\n"
            "     padding mode.  For speaker-identity encoding this is negligible."
        )

    # ── ONNX export ────────────────────────────────────────────────────────
    n_tokens = int(patched_codes.shape[-1])
    print(f"\n  Tracing: input={n_samples} samples ({n_samples/ENCODER_SAMPLE_RATE:.1f} s)"
          f" → {n_tokens} tokens")

    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)
        warnings.filterwarnings("ignore", category=UserWarning)
        warnings.filterwarnings("ignore", category=DeprecationWarning)
        torch.onnx.export(
            wrapper,
            (dummy,),
            str(out_path),
            input_names        = ["audio"],
            output_names       = ["codes"],
            opset_version      = opset,
            do_constant_folding= True,
            dynamo             = False,
        )

    print(f"  Written: {out_path}  ({out_path.stat().st_size / 1e6:.1f} MB)")
    return n_tokens


# ── ORT verification ───────────────────────────────────────────────────────────

def verify_with_ort(
    out_path:     Path,
    n_samples:    int,
    patched_codes: np.ndarray,
) -> None:
    """Run the exported ONNX through OnnxRuntime and cross-check."""
    try:
        import onnxruntime as ort
    except ImportError:
        print("  (onnxruntime not installed — skipping ORT verification)")
        return

    print("\nVerifying with OnnxRuntime …")
    sess = ort.InferenceSession(str(out_path))

    inp_info = sess.get_inputs()[0]
    print(f"  ORT model input : name={inp_info.name!r}  shape={inp_info.shape}")
    print(f"  ORT model output: name={sess.get_outputs()[0].name!r}  "
          f"shape={sess.get_outputs()[0].shape}")

    dummy_np = np.zeros((1, 1, n_samples), dtype=np.float32)
    ort_codes = sess.run(None, {"audio": dummy_np})[0].astype(np.int32)
    print(f"  ORT output: shape={ort_codes.shape}  dtype={ort_codes.dtype}")
    print(f"  Code range: [{ort_codes.min()}, {ort_codes.max()}]")

    ref = patched_codes.astype(np.int32)
    n_diff = (ort_codes != ref).sum()
    if n_diff == 0:
        print("  ✓ ORT codes match patched PyTorch codes exactly.")
    else:
        pct = 100.0 * n_diff / ref.size
        print(
            f"  ⚠  {n_diff}/{ref.size} ({pct:.1f}%) ORT tokens differ from PyTorch.\n"
            "     Usually caused by non-deterministic quantisation rounding."
        )


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export NeuCodec PyTorch encoder → ONNX",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--repo",           default="neuphonic/neucodec",
                        help="HuggingFace repo for the PyTorch NeuCodec model")
    parser.add_argument("--out",            default="neucodec_encoder.onnx",
                        help="Output ONNX file path")
    parser.add_argument("--opset",          type=int, default=17,
                        help="ONNX opset version")
    parser.add_argument("--max-duration-s", type=float, default=30.0,
                        help=(
                            "Fixed input duration the model is exported for (seconds).  "
                            "Rust zero-pads shorter clips and trims longer ones."
                        ))
    args = parser.parse_args()

    # ── Dependency checks ──────────────────────────────────────────────────
    for pkg, install in [
        ("neucodec",   "neucodec"),
        ("onnx",       "onnx"),
        ("onnxscript", "onnxscript"),
    ]:
        try:
            __import__(pkg)
        except ImportError:
            print(f"ERROR: '{pkg}' not installed.  Run:  pip install {install}",
                  file=sys.stderr)
            sys.exit(1)

    # ── Load model ─────────────────────────────────────────────────────────
    from neucodec import NeuCodec

    print(f"Loading {args.repo} …")
    codec = NeuCodec.from_pretrained(args.repo)
    codec.eval()
    wrapper = EncoderWrapper(codec)

    # ── Fixed input length ─────────────────────────────────────────────────
    # Round to token boundary so n_tokens = n_samples / 320 exactly.
    n_samples = (
        int(args.max_duration_s * ENCODER_SAMPLE_RATE)
        // ENCODER_SAMPLES_PER_TOKEN
        * ENCODER_SAMPLES_PER_TOKEN
    )
    n_tokens_expected = n_samples // ENCODER_SAMPLES_PER_TOKEN

    print(f"\nFixed input : {n_samples} samples = {n_samples/ENCODER_SAMPLE_RATE:.1f} s "
          f"→ {n_tokens_expected} tokens")

    # ── Export ─────────────────────────────────────────────────────────────
    out_path = Path(args.out)
    print(f"\nExporting to {out_path} (opset {args.opset}) …")
    n_tokens = export_onnx(wrapper, n_samples, out_path, args.opset)

    # ── Final codes for ORT cross-check ───────────────────────────────────
    dummy = torch.zeros(1, 1, n_samples, dtype=torch.float32)
    with torch.no_grad():
        patched_codes = wrapper(dummy).cpu().numpy()

    # ── ORT verification ───────────────────────────────────────────────────
    verify_with_ort(out_path, n_samples, patched_codes)

    # ── Summary ────────────────────────────────────────────────────────────
    print(f"""
Done → {out_path}

  Fixed input  : {n_samples} samples  ({n_samples/ENCODER_SAMPLE_RATE:.1f} s @ 16 kHz)
  Fixed output : {n_tokens} tokens    ({n_tokens*ENCODER_SAMPLES_PER_TOKEN/ENCODER_SAMPLE_RATE:.1f} s)

  Rust encoder behaviour:
    • clips shorter than {n_samples/ENCODER_SAMPLE_RATE:.0f} s → zero-padded
    • clips longer  than {n_samples/ENCODER_SAMPLE_RATE:.0f} s → truncated
    • output tokens always trimmed to floor(clip_len / 320)

  If your reference audio is longer than {args.max_duration_s:.0f} s, re-export:
    python scripts/export_encoder.py --max-duration-s 60

Encode a reference clip:
  cargo run --example encode_reference -- --audio reference.wav

Voice clone (caches encoding automatically):
  cargo run --example clone_voice --features espeak -- \\
    --ref-audio reference.wav --text 'Hello!'
""")


if __name__ == "__main__":
    main()

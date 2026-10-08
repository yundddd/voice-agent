#!/usr/bin/env python3
"""
Convert neuphonic/neucodec pytorch_model.bin → models/neucodec_decoder.safetensors

This is a ONE-TIME setup step.  After running this script, `cargo build` will
find the weight file and the decoder will work at runtime.

Requirements:
    pip install torch huggingface_hub safetensors

Usage:
    python scripts/convert_weights.py [--out models/neucodec_decoder.safetensors]
"""
import argparse
import os
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip())
    parser.add_argument(
        "--out",
        default="models/neucodec_decoder.safetensors",
        help="Output path for the decoder safetensors file",
    )
    parser.add_argument(
        "--repo",
        default="neuphonic/neucodec",
        help="HuggingFace repo to download from (default: neuphonic/neucodec)",
    )
    parser.add_argument(
        "--n-heads",
        type=int,
        default=16,
        help="Number of attention heads in the VocosBackbone (default: 16)",
    )
    args = parser.parse_args()

    # ── Check dependencies ────────────────────────────────────────────────────
    missing = []
    for pkg in ("torch", "huggingface_hub", "safetensors"):
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"ERROR: Missing packages: {', '.join(missing)}")
        print(f"       Install with:  pip install {' '.join(missing)}")
        sys.exit(1)

    import torch
    from huggingface_hub import hf_hub_download
    from safetensors.torch import save_file

    # ── Download ──────────────────────────────────────────────────────────────
    print(f"Downloading pytorch_model.bin from {args.repo} ...")
    bin_path = hf_hub_download(repo_id=args.repo, filename="pytorch_model.bin")
    print(f"  cached at: {bin_path}")

    # ── Load weights ──────────────────────────────────────────────────────────
    print("Loading weights (this may take a moment for large checkpoints) ...")
    state = torch.load(bin_path, map_location="cpu", weights_only=True)
    print(f"  total tensors in checkpoint: {len(state)}")

    # ── Extract decoder-only tensors ──────────────────────────────────────────
    decoder_prefixes = ("generator.", "fc_post_a.")
    decoder_state = {}
    for k, v in state.items():
        if any(k.startswith(p) for p in decoder_prefixes):
            decoder_state[k] = v.float().contiguous()  # ensure float32

    print(f"  extracted {len(decoder_state)} decoder tensors")
    if not decoder_state:
        print("ERROR: No decoder tensors found — check the repo / checkpoint structure.")
        sys.exit(1)

    # ── Detect and log hyperparameters ────────────────────────────────────────
    embed_w = decoder_state.get("generator.backbone.embed.weight")
    head_w  = decoder_state.get("generator.head.out.weight")

    if embed_w is None or head_w is None:
        print("ERROR: Expected keys 'generator.backbone.embed.weight' and "
              "'generator.head.out.weight' not found.")
        print("       Found keys starting with 'generator.':")
        for k in sorted(decoder_state)[:20]:
            print(f"         {k}")
        sys.exit(1)

    hidden_dim = embed_w.shape[0]
    out_dim    = head_w.shape[0]
    hop_length = (out_dim - 2) // 4
    n_fft      = hop_length * 4

    depth = sum(
        1 for k in decoder_state
        if k.startswith("generator.backbone.transformers.")
        and k.endswith(".att_norm.weight")
    )

    fsq_w = decoder_state.get("generator.quantizer.fsqs.0.project_out.weight")
    fsq_out_dim = fsq_w.shape[0] if fsq_w is not None else "?"
    fsq_in_dim  = fsq_w.shape[1] if fsq_w is not None else "?"

    tokens_per_sec = 24_000 // hop_length if hop_length > 0 else "?"

    print()
    print("Detected configuration:")
    print(f"  hidden_dim       = {hidden_dim}")
    print(f"  depth            = {depth} transformer blocks")
    print(f"  n_heads          = {args.n_heads}  (pass --n-heads N to override)")
    print(f"  hop_length       = {hop_length}  ({tokens_per_sec} tokens/s at 24 kHz)")
    print(f"  n_fft            = {n_fft}")
    print(f"  FSQ out→in       = {fsq_out_dim} → {fsq_in_dim}")
    print(f"  out_dim (head)   = {out_dim}")

    # ── Save safetensors ──────────────────────────────────────────────────────
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    metadata = {
        "hidden_dim": str(hidden_dim),
        "depth":      str(depth),
        "n_heads":    str(args.n_heads),
        "hop_length": str(hop_length),
        "source":     args.repo,
    }

    print(f"\nSaving to {args.out} ...")
    save_file(decoder_state, args.out, metadata=metadata)

    size_mb = os.path.getsize(args.out) / 1024 / 1024
    print(f"  saved {size_mb:.0f} MB")
    print()
    print("Done!  Now rebuild to pick up the new weights:")
    print()
    print("    cargo build")
    print()
    print("Then run the synthesis examples:")
    print()
    print("    cargo run --example test_pipeline")
    print("    cargo run --example basic --features espeak")


if __name__ == "__main__":
    main()

# models/ — NeuCodec weight staging directory

This directory holds the `neucodec_decoder.safetensors` weight file that the
NeuCodec decoder loads at runtime.

> **Nothing here is committed to Git** — the weight file is 300–700 MB.

---

## One-time setup

```sh
pip install torch huggingface_hub safetensors
python scripts/convert_weights.py
```

This downloads `neuphonic/neucodec/pytorch_model.bin` from HuggingFace,
extracts only the decoder weights (no Wav2Vec2Bert), and saves them here.

After that, `cargo build` just picks up the file — no code generation, no
panics.

---

## Expected file

| File | Size | Purpose |
|------|------|---------|
| `neucodec_decoder.safetensors` | 300–700 MB | Decoder weights loaded at runtime |

---

## Manual conversion

If you already have the PyTorch checkpoint somewhere:

```sh
python - <<'EOF'
import torch
from safetensors.torch import save_file
import os

bin_path = "/path/to/pytorch_model.bin"   # adjust
out_path = "models/neucodec_decoder.safetensors"

state = torch.load(bin_path, map_location="cpu", weights_only=True)

# Extract decoder-only weights (skip the 600 MB Wav2Vec2Bert encoder)
decoder = {k: v.float() for k, v in state.items()
           if k.startswith("generator.") or k.startswith("fc_post_a.")}

# Detect and embed hyperparameters as safetensors metadata
hidden_dim  = decoder["generator.backbone.embed.weight"].shape[0]
out_dim     = decoder["generator.head.out.weight"].shape[0]
hop_length  = (out_dim - 2) // 4
depth       = sum(1 for k in decoder if k.startswith("generator.backbone.transformers.")
                  and k.endswith(".att_norm.weight"))

os.makedirs("models", exist_ok=True)
save_file(decoder, out_path, metadata={
    "hidden_dim": str(hidden_dim),
    "depth":      str(depth),
    "n_heads":    "16",          # XCodec2/NeuCodec default
    "hop_length": str(hop_length),
})
print(f"Saved {len(decoder)} tensors → {out_path}")
EOF
```

---

## Build flags emitted by build.rs

| cfg flag | Set when |
|----------|----------|
| `neucodec_decoder_available` | `models/neucodec_decoder.safetensors` exists at build time |
| `neucodec_encoder_available` | `models/neucodec_encoder.safetensors` exists at build time |

The crate compiles and runs regardless — the flag is only used for
informational log messages.  The decoder returns an error at runtime if the
file is missing, with instructions to run `convert_weights.py`.

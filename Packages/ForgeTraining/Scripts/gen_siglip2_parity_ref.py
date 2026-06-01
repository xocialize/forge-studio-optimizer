"""Generate the SigLIP2 backbone parity fixture (#57).

Saves a fixed synthetic input + the PyTorch FP backbone's mean-pooled embedding
to the loader's cache dir as `parity.safetensors`. The Swift parity test
(`SigLIP2ParityTests`) loads the 8-bit-dequantized backbone, runs the same input,
and asserts the embedding tracks this FP reference (cosine ≥ 0.95) — the
numerical-correctness check #27 deferred (it only shape-checked against zeros).

Same numbers feed both backbones: NHWC [1,224,224,3] to the Swift port, the same
tensor permuted to NCHW for transformers. Deterministic (seeded), so re-running
reproduces the fixture bit-for-bit.

Run from Packages/ForgeTraining with the .venv active (transformers + torch).
Result lives off-repo in ~/Library/Application Support/Forge/Models/SigLIP2/.
"""
from __future__ import annotations

import os

import numpy as np
import torch
from safetensors.numpy import save_file
from transformers import AutoModel

BACKBONE = "google/siglip2-base-patch16-224"  # FP — the head's training backbone
CACHE = os.path.expanduser("~/Library/Application Support/Forge/Models/SigLIP2")


def main() -> int:
    rng = np.random.default_rng(0)
    # Synthetic input already in SigLIP's normalized range (~[-1, 1]), NHWC.
    x = rng.uniform(-1.0, 1.0, size=(1, 224, 224, 3)).astype(np.float32)

    bb = AutoModel.from_pretrained(BACKBONE).vision_model.eval()
    with torch.no_grad():
        nchw = torch.from_numpy(x).permute(0, 3, 1, 2).contiguous()  # [1,3,224,224]
        lhs = bb(pixel_values=nchw).last_hidden_state                # [1,196,768]
        emb = lhs.mean(dim=1).cpu().numpy().astype(np.float32)        # mean-pool [1,768]

    out = os.path.join(CACHE, "parity.safetensors")
    os.makedirs(CACHE, exist_ok=True)
    save_file({"input_nhwc": x, "ref_embedding": emb}, out)
    print(f"ref embedding {emb.shape} mean={emb.mean():.4f} std={emb.std():.4f} → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

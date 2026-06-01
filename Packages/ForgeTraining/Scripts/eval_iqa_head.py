"""Quick eval: does the trained IQA head separate clean from degraded? (#56)

Loads the SigLIP2 backbone (FP) + the trained head, scores each test image two
ways — full-frame→224 (downsizes, may hide artifacts) and patch-based (K native
224 crops, mean/min; sees native-scale artifacts). This is the gate's real test;
the Swift scorer will mirror the winning method.

Usage: eval_iqa_head.py --head <safetensors> label=path [label=path ...]
"""
from __future__ import annotations
import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from safetensors.numpy import load_file
from transformers import AutoModel, AutoImageProcessor


def build_head(path: str) -> nn.Sequential:
    w = load_file(path)
    h = nn.Sequential(nn.Linear(768, 256), nn.GELU(), nn.Linear(256, 1), nn.Sigmoid())
    sd = {"0.weight": w["fc1.weight"], "0.bias": w["fc1.bias"],
          "2.weight": w["fc2.weight"], "2.bias": w["fc2.bias"]}
    h.load_state_dict({k: torch.from_numpy(v) for k, v in sd.items()})
    return h.eval()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--head", required=True)
    ap.add_argument("--backbone", default="google/siglip2-base-patch16-224")
    ap.add_argument("--patches", type=int, default=8)
    ap.add_argument("--patch-size", type=int, default=224)
    ap.add_argument("images", nargs="+", help="label=path ...")
    a = ap.parse_args()

    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    proc = AutoImageProcessor.from_pretrained(a.backbone)
    bb = AutoModel.from_pretrained(a.backbone).vision_model.to(dev).eval()
    head = build_head(a.head).to(dev)
    rng = np.random.default_rng(0)

    @torch.no_grad()
    def score(pil_list):
        px = proc(images=pil_list, return_tensors="pt")["pixel_values"].to(dev)
        emb = bb(pixel_values=px).last_hidden_state.mean(dim=1)
        return head(emb).squeeze(1).cpu().numpy()

    print(f"{'label':22s} {'full→224':>9s} {'patch-mean':>11s} {'patch-min':>10s}")
    for item in a.images:
        label, path = item.split("=", 1)
        img = Image.open(path).convert("RGB")
        full_q = float(score([img])[0])
        w, h = img.size
        ps = min(a.patch_size, w, h)
        crops = []
        for _ in range(a.patches):
            x = int(rng.integers(0, max(1, w - ps))); y = int(rng.integers(0, max(1, h - ps)))
            crops.append(img.crop((x, y, x + ps, y + ps)))
        pq = score(crops)
        print(f"{label:22s} {full_q:9.3f} {pq.mean():11.3f} {pq.min():10.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Train the SigLIP2 NR-IQA head on pseudo-MOS tiles (#56).

Lightweight by design — the SigLIP2 backbone is FROZEN and already shipped
(mlx-community 8-bit, Apache-2.0, ADR-0005). We only fit the small head
(`SigLIP2_IQA`: 768→256→GELU→1→sigmoid, ~200k params) that ships.

Pipeline:
  1. EXTRACT — run the frozen SigLIP2 vision backbone on each manifest tile,
     mean-pool patch tokens → 768-d embedding. Cached to embeddings.npz.
  2. FIT — train the MLP head on (embedding → pseudo-MOS quality), MSE loss,
     report SRCC/PLCC on a held-out split.
  3. EMIT — save head.safetensors with keys matching the Swift `SigLIP2_IQA`
     @ModuleInfo flatten (fc1.weight/bias, fc2.weight/bias) for MLX loading.

NOTE (quantization gap): embeddings here come from the FP backbone via
transformers; inference uses the 8-bit MLX backbone. Mean-pooling is robust to
8-bit, but this MUST be confirmed by the `forge-quality-target --score`
re-validation before defaulting the gate on — do not assume.

Usage:
  train_iqa_head.py --dataset <iqa_dataset_dir> --out <dir>
      [--backbone google/siglip2-base-patch16-224] [--epochs 200] [--val-frac 0.15]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def extract_embeddings(dataset: Path, backbone: str, cache: Path) -> tuple[np.ndarray, np.ndarray]:
    if cache.exists():
        d = np.load(cache)
        print(f"[extract] cache hit: {cache} ({d['emb'].shape[0]} tiles)")
        return d["emb"], d["q"]
    import torch
    from PIL import Image
    from transformers import AutoModel, AutoImageProcessor

    rows = [json.loads(l) for l in (dataset / "manifest.jsonl").read_text().splitlines()]
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"[extract] {len(rows)} tiles via {backbone} on {dev} (frozen)")
    proc = AutoImageProcessor.from_pretrained(backbone)
    model = AutoModel.from_pretrained(backbone).vision_model.to(dev).eval()

    embs, qs = [], []
    B = 32
    with torch.no_grad():
        for i in range(0, len(rows), B):
            batch = rows[i:i + B]
            imgs = [Image.open(dataset / r["file"]).convert("RGB") for r in batch]
            px = proc(images=imgs, return_tensors="pt")["pixel_values"].to(dev)
            out = model(pixel_values=px).last_hidden_state    # [B, patches, 768]
            embs.append(out.mean(dim=1).float().cpu().numpy())  # mean-pool → [B, 768]
            qs.extend(r["quality"] for r in batch)
            print(f"  {min(i + B, len(rows))}/{len(rows)}", end="\r", flush=True)
    emb = np.concatenate(embs, 0).astype(np.float32)
    q = np.asarray(qs, np.float32)
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.savez(cache, emb=emb, q=q)
    print(f"\n[extract] saved {emb.shape} → {cache}")
    return emb, q


def srcc_plcc(pred: np.ndarray, true: np.ndarray) -> tuple[float, float]:
    def rank(a):
        order = a.argsort(); r = np.empty_like(order, dtype=np.float64); r[order] = np.arange(len(a)); return r
    rp, rt = rank(pred), rank(true)
    srcc = np.corrcoef(rp, rt)[0, 1]
    plcc = np.corrcoef(pred, true)[0, 1]
    return float(srcc), float(plcc)


def fit_head(emb: np.ndarray, q: np.ndarray, out: Path, epochs: int, val_frac: float, seed: int):
    import torch
    import torch.nn as nn
    from safetensors.numpy import save_file

    torch.manual_seed(seed)
    n = len(q); idx = np.random.default_rng(seed).permutation(n)
    nval = max(1, int(n * val_frac))
    vi, ti = idx[:nval], idx[nval:]
    X = torch.from_numpy(emb); Y = torch.from_numpy(q).unsqueeze(1)
    Xt, Yt, Xv, Yv = X[ti], Y[ti], X[vi], Y[vi]

    head = nn.Sequential(nn.Linear(emb.shape[1], 256), nn.GELU(), nn.Linear(256, 1), nn.Sigmoid())
    opt = torch.optim.Adam(head.parameters(), lr=1e-3, weight_decay=1e-4)
    lossf = nn.MSELoss()
    best, best_state = 1e9, None
    for ep in range(epochs):
        head.train(); opt.zero_grad()
        loss = lossf(head(Xt), Yt); loss.backward(); opt.step()
        head.eval()
        with torch.no_grad():
            vloss = lossf(head(Xv), Yv).item()
        if vloss < best:
            best = vloss; best_state = {k: v.clone() for k, v in head.state_dict().items()}
        if (ep + 1) % 50 == 0:
            print(f"  ep {ep+1:4d}  train {loss.item():.4f}  val {vloss:.4f}")
    head.load_state_dict(best_state)
    head.eval()
    with torch.no_grad():
        pv = head(Xv).squeeze(1).numpy()
    srcc, plcc = srcc_plcc(pv, q[vi])
    print(f"[fit] best val MSE {best:.4f}  SRCC {srcc:.3f}  PLCC {plcc:.3f}  (n_val={nval})")

    # Map nn.Sequential → SigLIP2_IQA keys. Linear.weight is [out,in] in both
    # PyTorch and MLX-Swift, so no transpose needed.
    sd = head.state_dict()
    weights = {
        "fc1.weight": sd["0.weight"].numpy(), "fc1.bias": sd["0.bias"].numpy(),
        "fc2.weight": sd["2.weight"].numpy(), "fc2.bias": sd["2.bias"].numpy(),
    }
    out.mkdir(parents=True, exist_ok=True)
    save_file(weights, str(out / "siglip2_iqa_head.safetensors"))
    (out / "metrics.json").write_text(json.dumps(
        {"val_mse": best, "srcc": srcc, "plcc": plcc, "n_train": len(ti), "n_val": nval}, indent=2))
    print(f"[emit] head → {out/'siglip2_iqa_head.safetensors'}  (keys: fc1/fc2 weight+bias)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--backbone", default="google/siglip2-base-patch16-224")
    ap.add_argument("--epochs", type=int, default=300)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=1234)
    a = ap.parse_args()
    ds = Path(a.dataset); out = Path(a.out)
    emb, q = extract_embeddings(ds, a.backbone, out / "embeddings.npz")
    fit_head(emb, q, out, a.epochs, a.val_frac, a.seed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

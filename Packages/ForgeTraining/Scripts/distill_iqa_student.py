#!/usr/bin/env python3
"""
#23 / Phase E Plan-B — distill QualiCLIP+ (teacher) → MobileNet-V3 student NR-IQA.

WHY: SigLIP2 (ADR-0005) is Plan A and ships (gate SRCC 0.902). This is INSURANCE against
SigLIP2's ~400 MB lazy-download UX — a 5–10 MB bundleable NR-IQA head distilled from a
strong teacher (research-2026-05-26-three-surveys §Survey 1; LICENSES.md Phase E Plan-B).

LICENSING (read before shipping):
  - Teacher QualiCLIP+ is CC-BY-NC-4.0 → NON-COMMERCIAL. Running it as a research
    experiment (this script) is permitted. SHIPPING the distilled student commercially is
    a "derived-from-NC-teacher" question that needs legal review FIRST — task #30. The
    trained student weights are MVS's own artifact (MobileNet-V3 architecture is MIT).

SCOPE of THIS script (the pipeline-validation slice):
  - Validates the distillation MECHANICS on a LOCAL image corpus (no registration-gated
    public datasets): teacher pseudo-labels -> student trains -> student≈teacher SRCC on a
    held-out split. A high student-vs-teacher SRCC means the student successfully absorbed
    the teacher.
  - The HEADLINE target (SRCC ≥0.85 vs human MOS on KonIQ-10k, ≥0.83 on SPAQ) needs those
    datasets, which are GDrive/registration-gated — a separate fetch + eval step.

USAGE (off-device only):
  ./.venv/bin/python Scripts/distill_iqa_student.py \
      --images data/iqa_ds2/tiles --limit 3000 --epochs 20 --out data/iqa_student
"""
from __future__ import annotations
import argparse, random, time, warnings
from pathlib import Path

warnings.filterwarnings("ignore")
import numpy as np
import torch
import torch.nn as nn
from PIL import Image
import torchvision.transforms as T
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights
from scipy.stats import spearmanr, pearsonr

CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)
EXTS = {".png", ".jpg", ".jpeg", ".bmp"}


def device() -> str:
    return "mps" if torch.backends.mps.is_available() else "cpu"


def list_images(roots: list[str], limit: int, seed: int) -> list[Path]:
    files: list[Path] = []
    for r in roots:
        files += [p for p in Path(r).rglob("*") if p.suffix.lower() in EXTS]
    random.Random(seed).shuffle(files)
    return files[:limit] if limit > 0 else files


# ---- teacher (QualiCLIP+, CC-BY-NC — off-device research only) -------------------------

def load_teacher(dev: str):
    return torch.hub.load("miccunifi/QualiCLIP", "QualiCLIP", trust_repo=True).to(dev).eval()


@torch.no_grad()
def teacher_pseudo_labels(model, paths: list[Path], dev: str, batch: int = 16) -> np.ndarray:
    pre = T.Compose([T.Resize(224), T.CenterCrop(224), T.ToTensor(), T.Normalize(CLIP_MEAN, CLIP_STD)])
    scores: list[np.ndarray] = []
    t0 = time.time()
    for i in range(0, len(paths), batch):
        ims = [pre(Image.open(p).convert("RGB")) for p in paths[i:i + batch]]
        s = model(torch.stack(ims).to(dev)).reshape(-1).float().cpu().numpy()
        scores.append(s)
        if i % (batch * 20) == 0:
            print(f"  [teacher] {i + len(ims)}/{len(paths)}  ({time.time() - t0:.0f}s)", flush=True)
    return np.concatenate(scores)


# ---- student (MobileNet-V3-small + 2-layer MLP regressor, LAR-IQA-style) ----------------

class Student(nn.Module):
    def __init__(self):
        super().__init__()
        bb = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.IMAGENET1K_V1)
        self.features, self.avgpool = bb.features, bb.avgpool
        self.head = nn.Sequential(nn.Linear(576, 128), nn.Hardswish(), nn.Dropout(0.2), nn.Linear(128, 1))

    def forward(self, x):
        x = self.avgpool(self.features(x))
        return self.head(torch.flatten(x, 1)).reshape(-1)


class IQADataset(torch.utils.data.Dataset):
    def __init__(self, paths, targets, train: bool):
        self.paths, self.targets = paths, targets
        aug = [T.RandomHorizontalFlip()] if train else []
        self.tf = T.Compose([T.Resize(256), T.CenterCrop(224), *aug, T.ToTensor(),
                             T.Normalize(IMAGENET_MEAN, IMAGENET_STD)])

    def __len__(self): return len(self.paths)

    def __getitem__(self, i):
        # float32 target — MPS rejects float64 (numpy's default).
        return self.tf(Image.open(self.paths[i]).convert("RGB")), torch.tensor(float(self.targets[i]), dtype=torch.float32)


def srcc_plcc(pred, true):
    return float(spearmanr(pred, true).correlation), float(pearsonr(pred, true)[0])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", default=["data/iqa_ds2/tiles"], help="corpus root(s)")
    ap.add_argument("--limit", type=int, default=3000)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--out", type=Path, default=Path("data/iqa_student"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    dev = device()
    torch.manual_seed(a.seed)

    paths = list_images(a.images, a.limit, a.seed)
    if len(paths) < 50:
        print(f"ERROR: only {len(paths)} images under {a.images}", flush=True); return 1
    print(f"[distill] {len(paths)} images on {dev}", flush=True)

    # 1) teacher pseudo-labels (cache so re-runs skip the slow CLIP pass).
    cache = a.out / f"teacher_{len(paths)}_{a.seed}.npz"
    if cache.exists():
        d = np.load(cache, allow_pickle=True)
        paths = [Path(p) for p in d["paths"]]; q = d["q"]
        print(f"[teacher] loaded {len(q)} cached pseudo-labels", flush=True)
    else:
        print("[teacher] QualiCLIP+ (CC-BY-NC, research-only) → pseudo-labels …", flush=True)
        q = teacher_pseudo_labels(load_teacher(dev), paths, dev, a.batch // 2)
        np.savez(cache, paths=[str(p) for p in paths], q=q)
    print(f"[teacher] score spread: min {q.min():.3f}  mean {q.mean():.3f}  max {q.max():.3f}  std {q.std():.3f}", flush=True)

    # standardize targets (rank-based SRCC is scale-invariant; helps MSE conditioning).
    qz = (q - q.mean()) / (q.std() + 1e-6)

    # 2) split + train the student to regress the teacher.
    n_val = max(16, int(len(paths) * a.val_frac))
    tr = IQADataset(paths[n_val:], qz[n_val:], train=True)
    va = IQADataset(paths[:n_val], qz[:n_val], train=False)
    dl_tr = torch.utils.data.DataLoader(tr, batch_size=a.batch, shuffle=True, num_workers=4)
    dl_va = torch.utils.data.DataLoader(va, batch_size=a.batch, num_workers=4)

    model = Student().to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
    lossf = nn.MSELoss()
    best = (-2.0, 0.0)
    for ep in range(a.epochs):
        model.train()
        for x, y in dl_tr:
            x, y = x.to(dev), y.to(dev).float()
            opt.zero_grad(); loss = lossf(model(x), y); loss.backward(); opt.step()
        model.eval()
        preds, trues = [], []
        with torch.no_grad():
            for x, y in dl_va:
                preds.append(model(x.to(dev)).cpu().numpy()); trues.append(y.numpy())
        srcc, plcc = srcc_plcc(np.concatenate(preds), np.concatenate(trues))
        flag = ""
        if srcc > best[0]:
            best = (srcc, plcc); torch.save(model.state_dict(), a.out / "student.pt"); flag = " *"
        print(f"  epoch {ep + 1:>2}/{a.epochs}  val SRCC {srcc:.3f}  PLCC {plcc:.3f}{flag}", flush=True)

    n_params = sum(p.numel() for p in Student().parameters())
    fp16_mb = n_params * 2 / 1e6
    print(f"\n[distill] best student↔teacher  SRCC {best[0]:.3f}  PLCC {best[1]:.3f}", flush=True)
    print(f"[distill] student: {n_params / 1e6:.2f}M params  (~{fp16_mb:.1f} MB FP16) → {a.out / 'student.pt'}", flush=True)
    print("[distill] PIPELINE validated. Headline SRCC-vs-MOS (KonIQ/SPAQ) + #30 legal = next.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

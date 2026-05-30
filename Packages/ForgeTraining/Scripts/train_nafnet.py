#!/usr/bin/env python3
"""Phase B.3 — train NAFNet on the multi-degradation corpus (restart-friendly).

Built to survive an Apple-Silicon laptop that sleeps / moves mid-run (the same
hazard that reaped the C.4 benchmark). Robustness contract:

  * **Atomic checkpoints** — every checkpoint is written to ``<name>.tmp`` then
    ``os.replace``-d into place, so a crash/sleep during a write never corrupts
    the file.
  * **Auto-resume** — on start, if ``ckpt_latest.pt`` exists it resumes model +
    optimizer + scheduler + step/epoch + RNG state (torch/numpy/python) +
    best-metric. Re-running the exact same command continues where it left off.
  * **Graceful interrupt** — SIGINT/SIGTERM (Ctrl-C, ``kill``, the OS putting the
    machine to sleep then the run being killed) flips a flag; the loop saves a
    checkpoint at the next step boundary and exits 0. So even a hard stop loses
    at most one step.
  * **Frequent checkpoints** — every ``--ckpt-every`` steps AND at each epoch
    end AND on signal. Default 500 steps ≈ a few minutes of work at risk.
  * **Deterministic** — seeded; resume restores RNG so the run is reproducible.

Train in PyTorch (MPS), then B.4 converts the state_dict to MLX. The checkpoint
also drops a plain ``nafnet_best.pt`` (weights only) for the converter.

Usage:
    python Scripts/train_nafnet.py \
        --pairs  <corpus>/pairs \
        --out    runs/nafnet-b3 \
        --steps  300000 --batch 16

Resume = re-run the identical command (it finds runs/nafnet-b3/ckpt_latest.pt).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import sys
import time
from pathlib import Path

import numpy as np

try:
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader, Dataset
    from PIL import Image
except ImportError as e:  # pragma: no cover - dev-only deps
    sys.stderr.write(
        f"train_nafnet: missing dev dependency ({e}). "
        "Install the parity extra: pip install -r requirements-parity.txt\n"
    )
    raise

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Python"))
from models.nafnet_torch import NAFNet, count_params  # noqa: E402


# --------------------------------------------------------------------------- #
# Graceful-interrupt flag
# --------------------------------------------------------------------------- #
_STOP = {"flag": False, "why": ""}


def _install_signal_handlers() -> None:
    def handler(signum, _frame):
        _STOP["flag"] = True
        _STOP["why"] = signal.Signals(signum).name
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, handler)


# --------------------------------------------------------------------------- #
# Dataset
# --------------------------------------------------------------------------- #
class PairDataset(Dataset):
    """HQ/LQ PNG tile pairs from the B.2 corpus generator.

    Pairs are ``{idx:06d}_hq.png`` / ``{idx:06d}_lq.png``. Deterministic
    train/val split by index hash so resume sees the same split.
    """

    def __init__(self, pairs_dir: Path, split: str, val_frac: float = 0.02) -> None:
        self.pairs_dir = Path(pairs_dir)
        hq = sorted(self.pairs_dir.glob("*_hq.png"))
        if not hq:
            raise FileNotFoundError(f"no *_hq.png pairs under {self.pairs_dir}")
        stems = [p.name[: -len("_hq.png")] for p in hq]
        # deterministic split: hash stem -> [0,1)
        def _bucket(stem: str) -> float:
            import hashlib
            h = hashlib.sha256(stem.encode()).digest()
            return int.from_bytes(h[:8], "big") / 2 ** 64
        if split == "train":
            self.stems = [s for s in stems if _bucket(s) >= val_frac]
        elif split == "val":
            self.stems = [s for s in stems if _bucket(s) < val_frac]
        else:
            raise ValueError(split)
        if not self.stems:
            raise RuntimeError(f"empty {split} split (val_frac={val_frac})")

    def __len__(self) -> int:
        return len(self.stems)

    def __getitem__(self, i: int):
        stem = self.stems[i]
        lq = Image.open(self.pairs_dir / f"{stem}_lq.png").convert("RGB")
        hq = Image.open(self.pairs_dir / f"{stem}_hq.png").convert("RGB")
        to_t = lambda im: torch.from_numpy(
            np.asarray(im, dtype=np.float32).transpose(2, 0, 1) / 255.0
        )
        return to_t(lq), to_t(hq)


# --------------------------------------------------------------------------- #
# Checkpoint I/O (atomic)
# --------------------------------------------------------------------------- #
def _atomic_torch_save(obj: dict, path: Path) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(obj, tmp)
    os.replace(tmp, path)  # atomic on POSIX


def _rng_state() -> dict:
    return {
        "torch": torch.get_rng_state(),
        "numpy": np.random.get_state(),
        "python": random.getstate(),
    }


def _set_rng_state(s: dict) -> None:
    torch.set_rng_state(s["torch"])
    np.random.set_state(s["numpy"])
    random.setstate(s["python"])


def _psnr(pred: torch.Tensor, target: torch.Tensor) -> float:
    mse = torch.mean((pred.clamp(0, 1) - target) ** 2).item()
    if mse <= 1e-12:
        return 99.0
    return 10.0 * np.log10(1.0 / mse)


# --------------------------------------------------------------------------- #
# Train
# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pairs", required=True, type=Path, help="corpus pairs/ dir")
    ap.add_argument("--out", required=True, type=Path, help="run dir (checkpoints/logs)")
    ap.add_argument("--steps", type=int, default=300_000, help="total optim steps")
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--ckpt-every", type=int, default=500, help="steps between checkpoints")
    ap.add_argument("--val-every", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--width", type=int, default=24)
    ap.add_argument("--device", type=str, default=None, help="mps|cpu (auto if unset)")
    args = ap.parse_args(argv)

    args.out.mkdir(parents=True, exist_ok=True)
    log_path = args.out / "train.log"

    def log(msg: str) -> None:
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
        print(line, flush=True)
        with open(log_path, "a") as fh:
            fh.write(line + "\n")

    _install_signal_handlers()

    if args.device:
        device = torch.device(args.device)
    elif torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
        log("WARNING: MPS unavailable — training on CPU will be very slow")

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)

    model = NAFNet(width=args.width).to(device)
    log(f"NAFNet width={args.width}: {count_params(model)/1e6:.2f}M params, device={device}")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.0, betas=(0.9, 0.9))
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.steps, eta_min=args.lr * 1e-2)
    loss_fn = nn.L1Loss()

    train_ds = PairDataset(args.pairs, "train")
    val_ds = PairDataset(args.pairs, "val")
    log(f"data: {len(train_ds)} train / {len(val_ds)} val pairs")
    val_loader = DataLoader(val_ds, batch_size=args.batch, num_workers=args.workers)

    # ---- resume ----------------------------------------------------------- #
    ckpt_latest = args.out / "ckpt_latest.pt"
    ckpt_best = args.out / "ckpt_best.pt"
    start_step = 0
    best_psnr = -1.0
    if ckpt_latest.exists():
        ck = torch.load(ckpt_latest, map_location=device)
        model.load_state_dict(ck["model"])
        opt.load_state_dict(ck["opt"])
        sched.load_state_dict(ck["sched"])
        start_step = ck["step"]
        best_psnr = ck.get("best_psnr", -1.0)
        try:
            _set_rng_state(ck["rng"])
        except Exception as e:  # noqa: BLE001
            log(f"RNG restore skipped ({e})")
        log(f"RESUMED from {ckpt_latest} @ step {start_step}, best_psnr={best_psnr:.3f}")
    else:
        log("fresh start (no ckpt_latest.pt)")

    def save_ckpt(step: int, best: float, also_best: bool = False) -> None:
        obj = {
            "model": model.state_dict(),
            "opt": opt.state_dict(),
            "sched": sched.state_dict(),
            "step": step,
            "best_psnr": best,
            "rng": _rng_state(),
            "args": vars(args) | {"out": str(args.out), "pairs": str(args.pairs)},
        }
        _atomic_torch_save(obj, ckpt_latest)
        if also_best:
            _atomic_torch_save(obj, ckpt_best)
            # weights-only artifact for the B.4 converter
            _atomic_torch_save({"model": model.state_dict(), "width": args.width},
                               args.out / "nafnet_best.pt")

    def validate() -> float:
        model.eval()
        tot, n = 0.0, 0
        with torch.no_grad():
            for lq, hq in val_loader:
                pred = model(lq.to(device))
                tot += _psnr(pred.cpu(), hq)
                n += 1
                if _STOP["flag"]:
                    break
        model.train()
        return tot / max(n, 1)

    # ---- train loop ------------------------------------------------------- #
    model.train()
    step = start_step
    log(f"training {start_step} -> {args.steps} (ckpt every {args.ckpt_every}, val every {args.val_every})")
    t0 = time.time()
    running = 0.0
    rcount = 0
    while step < args.steps:
        loader = DataLoader(
            train_ds, batch_size=args.batch, shuffle=True,
            num_workers=args.workers, drop_last=True, persistent_workers=False,
        )
        for lq, hq in loader:
            lq, hq = lq.to(device), hq.to(device)
            opt.zero_grad(set_to_none=True)
            pred = model(lq)
            loss = loss_fn(pred, hq)
            loss.backward()
            opt.step()
            sched.step()
            step += 1
            running += loss.item()
            rcount += 1

            if step % 50 == 0:
                ips = (step - start_step) / max(time.time() - t0, 1e-6)
                log(f"step {step}/{args.steps} loss={running/max(rcount,1):.4f} "
                    f"lr={sched.get_last_lr()[0]:.2e} {ips:.1f} it/s")
                running, rcount = 0.0, 0

            if step % args.val_every == 0:
                ps = validate()
                better = ps > best_psnr
                if better:
                    best_psnr = ps
                log(f"  val PSNR={ps:.3f} dB {'(new best)' if better else f'(best {best_psnr:.3f})'}")
                save_ckpt(step, best_psnr, also_best=better)

            if step % args.ckpt_every == 0:
                save_ckpt(step, best_psnr)

            if _STOP["flag"] or step >= args.steps:
                save_ckpt(step, best_psnr)
                log(f"checkpoint saved @ step {step}"
                    + (f" — stopping on {_STOP['why']}" if _STOP["flag"] else " — target reached"))
                return 0

    save_ckpt(step, best_psnr)
    log(f"done @ step {step}, best PSNR={best_psnr:.3f} dB")
    # acceptance hint per ADR-0003 / plan §B.3
    if best_psnr < 35.0:
        log("NOTE: best PSNR < 35 dB — ADR-0003 revisit trigger (consider width=32 upsize)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

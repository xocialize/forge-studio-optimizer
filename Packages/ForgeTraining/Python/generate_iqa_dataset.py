"""Generate a labeled NR-IQA dataset for the SigLIP2 quality head (#56).

License-clean by construction (ADR-0010 precedent): we degrade our OWN clean
source frames with OUR codecs (the same `degradations.py` used for the NAFNet
corpus, #11) and label each degraded tile with a **full-reference perceptual
metric** vs its clean original — the "pseudo-MOS" technique. No third-party,
non-commercial IQA dataset is touched (KADID/KonIQ/SPAQ/PaQ-2-PiQ are all
research/NC; see Docs/Benchmarks/iqa-dataset-licensing.md).

Per source image:
  1. crop one random `tile_size` tile (artifacts at native scale),
  2. emit the CLEAN tile (quality = 1.0, the pristine anchor),
  3. emit `--variants` degraded tiles at sampled (kind, param) spanning the
     severity range,
  4. label every tile with quality in [0,1] from a full-reference metric
     (DISTS via `piq`, perceptual; PSNR fallback).

Output: PNG tiles + a JSONL manifest (one sample per line:
  {file, kind, param, metric, distance, quality}).

Domain note: point `--clean-source` at the (proprietary, local) high-bitrate
signage masters for a domain-matched gate — frames stay off-repo, only the
trained head ships (same handling as NAFNet, ADR-0010).
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from Python import degradations as deg  # noqa: E402
from Python.generate_multidegradation_corpus import discover_sources  # noqa: E402

# Severity spread per kind (clean-ish → heavy). Extended low/heavy after the v1
# head missed real low-bitrate files (#56 eval): mpeg2 down to 0.15 Mbps, hevc to
# max CRF — the bitrate-starved regime real signage actually hits.
PARAM_RANGES = {
    "noise": (3.0, 60.0),    # sigma
    "hevc":  (20, 51),       # CRF (51 = max, very heavy)
    "av1":   (24, 60),       # CRF
    "mpeg2": (0.15, 6.0),    # bitrate Mbps (0.15 = severe blocking)
}
KINDS = ("noise", "hevc", "av1", "mpeg2")

# Resolution diversity: degrade at varied long-sides so the head sees low-res
# content too (the v1 head missed 320×240 dvd-mpeg2 — out-of-distribution res).
# `None` = keep native. Short side stays ≥ 224 so a tile crops cleanly.
MULTI_RES_LONG_SIDES = (None, 1920, 1280, 960, 720, 540, 426)


@dataclass
class Labeler:
    """Full-reference quality in [0,1] (1 = identical to clean)."""
    metric: str

    def __post_init__(self):
        self._dists = None
        if self.metric == "dists":
            import torch  # noqa: F401
            import piq
            self._torch = torch
            self._dists = piq.DISTS()  # perceptual, lower = closer

    def quality(self, clean: np.ndarray, degraded: np.ndarray) -> tuple[float, float]:
        """Return (distance, quality∈[0,1])."""
        if self.metric == "psnr":
            p = deg.psnr(clean, degraded)
            if p == float("inf"):
                return 0.0, 1.0
            q = (p - 20.0) / (45.0 - 20.0)          # 20 dB→0, 45 dB→1
            return p, float(np.clip(q, 0.0, 1.0))
        # DISTS: tensors in [0,1], shape (1,3,H,W).
        t = self._torch
        def to_t(a):
            return t.from_numpy(a.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
        with t.no_grad():
            d = float(self._dists(to_t(clean), to_t(degraded)).item())
        return d, float(np.clip(1.0 - d, 0.0, 1.0))


def _even(v: int) -> int:
    """Largest even int ≤ v (video codecs require even dimensions)."""
    return v - (v & 1)


def maybe_downscale(img: np.ndarray, size: int, rng: random.Random) -> np.ndarray:
    """Pick a random target long-side (resolution diversity); keep short side ≥
    tile size so a tile still crops. `None` → native. Always returns EVEN dims —
    odd dims make the hevc/av1/mpeg2 degradations throw, which silently dropped
    every codec variant on downscaled (low-res) sources (the regime we most need)."""
    h, w = img.shape[:2]
    target = rng.choice(MULTI_RES_LONG_SIDES)
    if target is not None and max(h, w) > target:
        scale = target / max(h, w)
        nw, nh = int(round(w * scale)), int(round(h * scale))
        if min(nw, nh) < size:                               # don't go below tile size
            s2 = size / min(w, h)
            nw, nh = max(size, int(round(w * s2))), max(size, int(round(h * s2)))
        img = np.asarray(Image.fromarray(img).resize((nw, nh), Image.BICUBIC))
        h, w = img.shape[:2]
    eh, ew = max(size, _even(h)), max(size, _even(w))         # crop to even (≥ tile)
    return img[:eh, :ew]


def random_tile(img: np.ndarray, size: int, rng: random.Random) -> np.ndarray:
    h, w = img.shape[:2]
    if h < size or w < size:                         # upscale small sources to fit
        scale = size / min(h, w)
        img = np.asarray(Image.fromarray(img).resize(
            (max(size, int(w * scale + 0.5)), max(size, int(h * scale + 0.5))), Image.BICUBIC))
        h, w = img.shape[:2]
    y = rng.randint(0, h - size)
    x = rng.randint(0, w - size)
    return img[y:y + size, x:x + size].copy()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clean-source", required=True, help="dir of clean source images")
    ap.add_argument("--out", required=True, help="output dir (tiles + manifest.jsonl)")
    ap.add_argument("--tile-size", type=int, default=384)
    ap.add_argument("--variants", type=int, default=5, help="degraded tiles per source")
    ap.add_argument("--max-sources", type=int, default=0, help="0 = all")
    ap.add_argument("--metric", choices=["dists", "psnr"], default="dists")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--frame-level", action="store_true",
                    help="degrade the FULL (downscaled) frame then crop — matches real "
                         "frame/bitrate degradation; v1 crop-then-degrade missed it")
    ap.add_argument("--resume", action="store_true",
                    help="skip source indices already present in the manifest")
    a = ap.parse_args()

    out = Path(a.out); (out / "tiles").mkdir(parents=True, exist_ok=True)
    sources = discover_sources(Path(a.clean_source))
    if a.max_sources:
        sources = sources[:a.max_sources]
    ffmpeg = deg.locate_ffmpeg()
    labeler = Labeler(a.metric)
    rng = random.Random(a.seed)
    size = a.tile_size

    # Resume: collect source indices already emitted (filename prefix `{si:06d}_`).
    mpath = out / "manifest.jsonl"
    done: set[int] = set()
    if a.resume and mpath.exists():
        for line in mpath.read_text().splitlines():
            try: done.add(int(json.loads(line)["file"].split("/")[1][:6]))
            except Exception: pass
        print(f"resume: {len(done)} source indices already done", flush=True)
    manifest = mpath.open("a" if a.resume else "w")
    n = sum(1 for _ in (mpath.open() if a.resume and mpath.exists() else iter(())))

    def emit(si, arr, kind, param, dist, q):
        nonlocal n
        name = f"tiles/{si:06d}_{kind}_{n:07d}.png"
        Image.fromarray(arr, "RGB").save(out / name, "PNG", compress_level=1)
        manifest.write(json.dumps({"file": name, "kind": kind, "param": param,
                                   "metric": a.metric, "distance": round(dist, 5),
                                   "quality": round(q, 5)}) + "\n")
        manifest.flush(); n += 1

    for si, src in enumerate(sources):
        if si in done:
            continue
        img = maybe_downscale(np.asarray(Image.open(src).convert("RGB")), size, rng)
        h, w = img.shape[:2]
        if h < size or w < size:                     # tiny source → upscale to fit
            img = random_tile(img, size, rng); h, w = img.shape[:2]

        def crop(arr, y, x):
            return arr[y:y + size, x:x + size]

        # Clean anchor (random location).
        y0, x0 = rng.randint(0, h - size), rng.randint(0, w - size)
        emit(si, crop(img, y0, x0), "clean", 0.0, 0.0, 1.0)

        for _ in range(a.variants):
            kind = rng.choice(KINDS)
            lo, hi = PARAM_RANGES[kind]
            param = rng.uniform(lo, hi)
            try:
                # frame-level: degrade the whole frame, then crop (realistic).
                # crop-level (legacy): crop first, degrade the tile.
                if a.frame_level:
                    full = deg.apply_degradation(img, kind=kind, param=param,
                                                 rng=np.random.default_rng(rng.getrandbits(63)),
                                                 ffmpeg_bin=ffmpeg)
                    y, x = rng.randint(0, h - size), rng.randint(0, w - size)
                    clean_t, deg_t = crop(img, y, x), crop(full, y, x)
                else:
                    y, x = rng.randint(0, h - size), rng.randint(0, w - size)
                    clean_t = crop(img, y, x)
                    deg_t = deg.apply_degradation(clean_t, kind=kind, param=param,
                                                  rng=np.random.default_rng(rng.getrandbits(63)),
                                                  ffmpeg_bin=ffmpeg)
            except Exception:                         # transient ffmpeg failure → skip
                continue
            dist, q = labeler.quality(clean_t, deg_t)
            emit(si, deg_t, kind, round(param, 3), dist, q)
        if (si + 1) % 50 == 0:
            print(f"  {si + 1}/{len(sources)} sources, {n} tiles", flush=True)

    manifest.close()
    print(f"done: {n} labeled tiles from {len(sources)} sources → {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

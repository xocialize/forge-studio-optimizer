#!/usr/bin/env python3
"""Generate a paired HQ/LQ multi-degradation tile corpus for NAFNet training.

Phase B.2 / Task #11 deliverable. The output of this script feeds Phase B.3
(``train_nafnet.py``). See ``../README.md`` for usage and design rationale.

Pipeline per pair:
    1. Pick a random source image (uniform).
    2. Crop a random ``--tile-size`` x ``--tile-size`` tile.
    3. Sample a degradation kind uniformly from the enabled set
       (``noise``, ``hevc``, ``av1``, ``mpeg2``).
    4. Sample its parameter from the coding-plan range.
    5. Apply the degradation.
    6. Write ``{idx:06d}_hq.png``, ``{idx:06d}_lq.png``, ``{idx:06d}_meta.json``.
    7. Periodically rewrite ``manifest.json`` atomically (tempfile + replace).

Worker pool: ``concurrent.futures.ProcessPoolExecutor`` keyed by ``--seed``
so each worker derives an independent, deterministic RNG from its pair index.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

import numpy as np
from PIL import Image
from tqdm import tqdm

# Allow running this file directly (`python generate_multidegradation_corpus.py`)
# without installing the package: prepend the parent so `from Python import ...`
# resolves.
_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parent.parent))  # Packages/ForgeTraining/

from Python import degradations as deg  # noqa: E402


# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

# Coding plan §B.2 — degradation parameter ranges.
PARAM_RANGES = {
    "noise": (5.0, 50.0),     # sigma
    "hevc":  (22, 35),        # CRF (inclusive int)
    "av1":   (25, 40),        # CRF (inclusive int)
    "mpeg2": (2.0, 8.0),      # bitrate Mbps
}

ALL_KINDS = ("noise", "hevc", "av1", "mpeg2")

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"}

# Rewrite the manifest every N completed pairs. Keeps Ctrl-C resilience
# without thrashing the disk for a 500k run.
MANIFEST_FLUSH_INTERVAL = 200


# ----------------------------------------------------------------------------
# Data classes
# ----------------------------------------------------------------------------

@dataclass(frozen=True)
class PairJob:
    """One unit of work for a worker."""
    idx: int
    seed: int
    tile_size: int
    source_paths: tuple[str, ...]
    enabled_kinds: tuple[str, ...]
    output_pairs_dir: str
    ffmpeg_bin: str


@dataclass(frozen=True)
class PairResult:
    idx: int
    degradation: str
    param: float
    source_path: str
    tile_xy: tuple[int, int]


# ----------------------------------------------------------------------------
# Source discovery
# ----------------------------------------------------------------------------

def discover_sources(root: Path) -> list[Path]:
    """Recursively gather image files under ``root``.

    Returns a deterministically sorted list so the same dir always yields
    the same source ordering.
    """
    if not root.is_dir():
        raise NotADirectoryError(f"--hq-source not a directory: {root}")
    sources = [
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    ]
    if not sources:
        raise FileNotFoundError(f"no images under {root}")
    sources.sort()
    return sources


def source_sha(paths: Iterable[Path]) -> str:
    """SHA-256 of the sorted relative filename list. Cheap, stable provenance.

    Does NOT hash file contents — that would be too slow for a 500k corpus
    on a directory of thousands of 2K images. The relative-name fingerprint
    is enough to detect "did the source set change?" between runs.
    """
    h = hashlib.sha256()
    for p in sorted(paths):
        h.update(str(p.name).encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


# ----------------------------------------------------------------------------
# Per-pair worker
# ----------------------------------------------------------------------------

def _load_rgb(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.uint8)


def _sample_param(rng: random.Random, kind: str) -> float:
    lo, hi = PARAM_RANGES[kind]
    if kind in ("hevc", "av1"):
        return float(rng.randint(int(lo), int(hi)))
    return float(rng.uniform(lo, hi))


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    """Atomic write via tempfile + os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="wb",
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as tmp:
        tmp.write(data)
        tmp_path = tmp.name
    os.replace(tmp_path, path)


def _atomic_write_text(path: Path, text: str) -> None:
    _atomic_write_bytes(path, text.encode("utf-8"))


def _atomic_write_png(path: Path, img: np.ndarray) -> None:
    """Write a PNG atomically by writing to a sibling temp file first."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="wb",
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as tmp:
        tmp_path = tmp.name
    try:
        Image.fromarray(img, mode="RGB").save(tmp_path, format="PNG", compress_level=1)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


def _derive_seed(master_seed: int, idx: int) -> int:
    """Mix master seed + pair index into a stable 64-bit value.

    ``random.Random`` only accepts ``int|float|str|bytes|bytearray``, so we
    can't pass a tuple. SHA-256 keeps avalanche properties across nearby
    indices and is deterministic.
    """
    h = hashlib.sha256(f"{master_seed}:{idx}".encode("utf-8")).digest()
    return int.from_bytes(h[:8], "big", signed=False)


def _process_pair(job: PairJob) -> PairResult:
    """Generate a single pair. Runs inside a worker process."""
    # Deterministic per-pair RNGs derived from (master_seed, pair_idx).
    derived = _derive_seed(job.seed, job.idx)
    rng_py = random.Random(derived)
    # numpy.SeedSequence supports tuple-like entropy directly, but we use
    # the same derived int so both RNGs share a clear provenance.
    rng_np = np.random.default_rng(derived)

    # Pick a source (deterministically per index).
    src_path = Path(rng_py.choice(job.source_paths))
    img = _load_rgb(src_path)
    h, w, _ = img.shape

    if h < job.tile_size or w < job.tile_size:
        # If the source is too small, upscale by nearest so the tile fits.
        # This is rare for DIV2K/Flickr2K but a safety net for arbitrary dirs.
        scale = max(job.tile_size / h, job.tile_size / w)
        new_h = max(int(np.ceil(h * scale)), job.tile_size)
        new_w = max(int(np.ceil(w * scale)), job.tile_size)
        img = np.asarray(
            Image.fromarray(img, mode="RGB").resize((new_w, new_h), Image.BICUBIC),
            dtype=np.uint8,
        )
        h, w, _ = img.shape

    # Random tile, even-aligned (codecs require even dims; we keep tile_size
    # even by construction since coding-plan default is 256).
    x = rng_py.randint(0, w - job.tile_size)
    y = rng_py.randint(0, h - job.tile_size)
    tile_hq = img[y:y + job.tile_size, x:x + job.tile_size].copy()

    # Pick degradation kind + parameter, then apply it resiliently. The codec
    # round-trips shell out to ffmpeg ~num_pairs times across many parallel
    # workers, and this ffmpeg build occasionally fails a single encode/decode
    # under load (ISOBMFF mux race, transient bad output, etc.). A single bad
    # pair must NOT abort a multi-hour run: retry with a fresh draw, then fall
    # back to pure-numpy noise (which never touches ffmpeg) as a last resort.
    kind = rng_py.choice(job.enabled_kinds)
    param = _sample_param(rng_py, kind)
    tile_lq = None
    for _attempt in range(4):
        try:
            tile_lq = deg.apply_degradation(
                tile_hq, kind=kind, param=param, rng=rng_np, ffmpeg_bin=job.ffmpeg_bin,
            )
            break
        except Exception:  # noqa: BLE001 — transient ffmpeg codec failure; re-draw
            kind = rng_py.choice(job.enabled_kinds)
            param = _sample_param(rng_py, kind)
    if tile_lq is None:
        kind, param = "noise", _sample_param(rng_py, "noise")
        tile_lq = deg.apply_degradation(
            tile_hq, kind=kind, param=param, rng=rng_np, ffmpeg_bin=job.ffmpeg_bin,
        )

    out_dir = Path(job.output_pairs_dir)
    stem = f"{job.idx:06d}"

    _atomic_write_png(out_dir / f"{stem}_hq.png", tile_hq)
    _atomic_write_png(out_dir / f"{stem}_lq.png", tile_lq)

    meta = {
        "idx": job.idx,
        "degradation": kind,
        "param": param,
        "source_path": str(src_path),
        "tile_xy": [x, y],
        "tile_size": job.tile_size,
    }
    _atomic_write_text(
        out_dir / f"{stem}_meta.json",
        json.dumps(meta, indent=2, sort_keys=True) + "\n",
    )

    return PairResult(
        idx=job.idx,
        degradation=kind,
        param=param,
        source_path=str(src_path),
        tile_xy=(x, y),
    )


# ----------------------------------------------------------------------------
# Manifest
# ----------------------------------------------------------------------------

def _empty_breakdown() -> dict[str, int]:
    return {k: 0 for k in ALL_KINDS}


def _write_manifest(
    output_root: Path,
    *,
    seed: int,
    tile_size: int,
    source_dir: Path,
    src_sha: str,
    target_pairs: int,
    completed: int,
    breakdown: dict[str, int],
    skipped: list[str],
    ffmpeg_bin: str,
    finalized: bool,
) -> None:
    payload = {
        "version": 1,
        "generator": "ForgeTraining.generate_multidegradation_corpus",
        "seed": seed,
        "tile_size": tile_size,
        "source_dir": str(source_dir),
        "source_sha": src_sha,
        "target_pairs": target_pairs,
        "num_pairs": completed,
        "breakdown": breakdown,
        "skipped_degradations": sorted(skipped),
        "ffmpeg": ffmpeg_bin,
        "finalized": finalized,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    _atomic_write_text(
        output_root / "manifest.json",
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
    )


# ----------------------------------------------------------------------------
# Resume support
# ----------------------------------------------------------------------------

def _existing_complete_indices(pairs_dir: Path) -> set[int]:
    """Indices for which HQ + LQ + meta all exist on disk."""
    if not pairs_dir.is_dir():
        return set()
    have_hq: dict[int, bool] = {}
    have_lq: dict[int, bool] = {}
    have_meta: dict[int, bool] = {}
    for p in pairs_dir.iterdir():
        name = p.name
        if not name.endswith((".png", ".json")):
            continue
        # Skip in-flight temp files (.<name>.tmp).
        if name.startswith("."):
            continue
        try:
            idx = int(name[:6])
        except ValueError:
            continue
        if name.endswith("_hq.png"):
            have_hq[idx] = True
        elif name.endswith("_lq.png"):
            have_lq[idx] = True
        elif name.endswith("_meta.json"):
            have_meta[idx] = True
    return {i for i in have_hq if have_lq.get(i) and have_meta.get(i)}


def _rebuild_breakdown(pairs_dir: Path, indices: Iterable[int]) -> dict[str, int]:
    """Re-derive per-degradation counts from existing meta JSONs (for --resume)."""
    breakdown = _empty_breakdown()
    for idx in indices:
        meta_path = pairs_dir / f"{idx:06d}_meta.json"
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
            kind = meta.get("degradation")
            if kind in breakdown:
                breakdown[kind] += 1
        except (OSError, json.JSONDecodeError):
            continue
    return breakdown


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="generate_multidegradation_corpus",
        description=(
            "Generate paired HQ/LQ tile corpus for NAFNet training. "
            "Phase B.2 / Task #11 — offline-only, never linked into Forge.app."
        ),
    )
    p.add_argument("--hq-source", required=True, type=Path,
                   help="Directory of clean source images (recursed).")
    p.add_argument("--output", required=True, type=Path,
                   help="Output root: tiles in <output>/pairs/, manifest at top.")
    p.add_argument("--num-pairs", type=int, default=500_000,
                   help="Target pair count (default: 500000).")
    p.add_argument("--tile-size", type=int, default=256,
                   help="Tile edge in pixels (default: 256, must be even).")
    p.add_argument("--seed", type=int, default=42,
                   help="Master seed (default: 42).")
    p.add_argument("--workers", type=int, default=None,
                   help="Worker process count (default: os.cpu_count() - 2).")
    p.add_argument("--skip-degradation", action="append", default=[],
                   choices=list(ALL_KINDS),
                   help="Strip a degradation family. Repeatable.")
    p.add_argument("--resume", action="store_true",
                   help="Skip already-written pairs; append to manifest.")
    p.add_argument("--ffmpeg", type=str, default=None,
                   help="Override ffmpeg binary path.")
    return p.parse_args(argv)


def _resolve_workers(requested: Optional[int]) -> int:
    if requested is not None:
        return max(1, requested)
    cpu = os.cpu_count() or 4
    return max(1, cpu - 2)


def run(args: argparse.Namespace) -> int:
    if args.tile_size % 2:
        print(f"ERROR: --tile-size must be even, got {args.tile_size}", file=sys.stderr)
        return 2
    if args.num_pairs <= 0:
        print(f"ERROR: --num-pairs must be > 0, got {args.num_pairs}", file=sys.stderr)
        return 2

    enabled_kinds = tuple(k for k in ALL_KINDS if k not in set(args.skip_degradation))
    if not enabled_kinds:
        print("ERROR: all degradations skipped — nothing to generate.", file=sys.stderr)
        return 2

    ffmpeg_bin = args.ffmpeg or deg.locate_ffmpeg()

    source_dir: Path = args.hq_source.resolve()
    sources = discover_sources(source_dir)
    src_sha = source_sha(sources)

    output_root: Path = args.output.resolve()
    pairs_dir = output_root / "pairs"
    pairs_dir.mkdir(parents=True, exist_ok=True)

    # Resume bookkeeping.
    already: set[int] = set()
    breakdown = _empty_breakdown()
    if args.resume:
        already = _existing_complete_indices(pairs_dir)
        breakdown = _rebuild_breakdown(pairs_dir, already)
        print(
            f"[resume] {len(already)} existing pairs detected; "
            f"breakdown so far: {breakdown}",
            flush=True,
        )

    todo: list[int] = [i for i in range(args.num_pairs) if i not in already]
    if not todo:
        print("Nothing to do — corpus already at target size.")
        _write_manifest(
            output_root,
            seed=args.seed,
            tile_size=args.tile_size,
            source_dir=source_dir,
            src_sha=src_sha,
            target_pairs=args.num_pairs,
            completed=len(already),
            breakdown=breakdown,
            skipped=list(args.skip_degradation),
            ffmpeg_bin=ffmpeg_bin,
            finalized=True,
        )
        return 0

    workers = _resolve_workers(args.workers)
    print(
        f"==> source_dir={source_dir}\n"
        f"    output_root={output_root}\n"
        f"    target_pairs={args.num_pairs}  (todo={len(todo)})\n"
        f"    tile_size={args.tile_size}  seed={args.seed}  workers={workers}\n"
        f"    enabled={enabled_kinds}  skipped={sorted(set(args.skip_degradation))}\n"
        f"    ffmpeg={ffmpeg_bin}\n"
        f"    source_sha={src_sha[:12]}  sources={len(sources)}",
        flush=True,
    )

    source_paths_tuple = tuple(str(p) for p in sources)
    jobs = [
        PairJob(
            idx=idx,
            seed=args.seed,
            tile_size=args.tile_size,
            source_paths=source_paths_tuple,
            enabled_kinds=enabled_kinds,
            output_pairs_dir=str(pairs_dir),
            ffmpeg_bin=ffmpeg_bin,
        )
        for idx in todo
    ]

    completed = len(already)
    completed_since_flush = 0
    start = time.time()

    # Initial manifest before any work — so a Ctrl-C in worker spin-up still
    # leaves a valid (empty) manifest behind.
    _write_manifest(
        output_root,
        seed=args.seed,
        tile_size=args.tile_size,
        source_dir=source_dir,
        src_sha=src_sha,
        target_pairs=args.num_pairs,
        completed=completed,
        breakdown=breakdown,
        skipped=list(args.skip_degradation),
        ffmpeg_bin=ffmpeg_bin,
        finalized=False,
    )

    try:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(_process_pair, j) for j in jobs]
            failures = 0
            with tqdm(total=len(futures), desc="pairs", unit="pair") as bar:
                for fut in as_completed(futures):
                    try:
                        result = fut.result()
                    except Exception as exc:  # noqa: BLE001 — never let one pair kill the run
                        failures += 1
                        bar.update(1)
                        if failures <= 20:
                            print(f"  [skip] pair failed ({failures}): {exc}", file=sys.stderr)
                        continue
                    breakdown[result.degradation] += 1
                    completed += 1
                    completed_since_flush += 1
                    bar.update(1)
                    if completed_since_flush >= MANIFEST_FLUSH_INTERVAL:
                        _write_manifest(
                            output_root,
                            seed=args.seed,
                            tile_size=args.tile_size,
                            source_dir=source_dir,
                            src_sha=src_sha,
                            target_pairs=args.num_pairs,
                            completed=completed,
                            breakdown=breakdown,
                            skipped=list(args.skip_degradation),
                            ffmpeg_bin=ffmpeg_bin,
                            finalized=False,
                        )
                        completed_since_flush = 0
    finally:
        elapsed = time.time() - start
        _write_manifest(
            output_root,
            seed=args.seed,
            tile_size=args.tile_size,
            source_dir=source_dir,
            src_sha=src_sha,
            target_pairs=args.num_pairs,
            completed=completed,
            breakdown=breakdown,
            skipped=list(args.skip_degradation),
            ffmpeg_bin=ffmpeg_bin,
            finalized=(completed >= args.num_pairs),
        )
        print(
            f"==> wrote {completed}/{args.num_pairs} pairs in {elapsed:.1f}s "
            f"({(completed - len(already)) / max(elapsed, 1e-6):.1f} pairs/s)\n"
            f"    breakdown={breakdown}",
            flush=True,
        )

    return 0 if completed >= args.num_pairs else 1


def main(argv: Optional[list[str]] = None) -> int:
    return run(_parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())

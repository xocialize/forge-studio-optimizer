"""Integration smoke test: 20 pairs from 5 source images.

Mirrors the acceptance criterion in the Phase B.2 task spec:

    python generate_multidegradation_corpus.py \\
        --hq-source <dir of 5 test images> \\
        --output /tmp/test_corpus \\
        --num-pairs 20

Verifies:
    - The CLI returns 0.
    - 20 HQ + 20 LQ + 20 meta files land in pairs/.
    - manifest.json is finalized, totals add to 20, every breakdown entry
      is non-negative, sum across kinds == 20.
    - HQ vs. LQ are *different* for every pair (PSNR is finite — i.e. the
      LQ is actually a degraded version, not a copy).
    - Every degradation kind that ran has its parameter inside the
      coding-plan range.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent.parent))  # Packages/ForgeTraining/

from Python import degradations as deg  # noqa: E402
from Python import generate_multidegradation_corpus as gen  # noqa: E402


def _make_smoke_sources(root: Path, n: int = 5, size: int = 512) -> None:
    """5 synthetic source images, large enough for 256x256 tiles."""
    root.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        rng = np.random.default_rng(2000 + i)
        yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
        r = ((xx + i * 40) / size) * 255.0
        g = ((yy + i * 23) / size) * 255.0
        b = (((xx + yy + i * 19) % size) / size) * 255.0
        img = np.stack([r, g, b], axis=-1)
        img += rng.normal(0, 6, img.shape).astype(np.float32)
        img = np.clip(img, 0, 255).astype(np.uint8)
        img[30:120, 30:120] = [255, 0, 0]
        img[150:250, 150:250] = [0, 255, 0]
        img[280:400, 60:200] = [0, 0, 255]
        img[400:480, 350:480] = [255, 255, 0]
        Image.fromarray(img, mode="RGB").save(root / f"src_{i:03d}.png", format="PNG")


def test_smoke_20_pairs_from_5_images(tmp_path: pytest.TempPathFactory) -> None:
    src = tmp_path / "src"
    out = tmp_path / "corpus"
    _make_smoke_sources(src, n=5, size=512)

    rc = gen.main([
        "--hq-source", str(src),
        "--output", str(out),
        "--num-pairs", "20",
        "--tile-size", "256",
        "--seed", "42",
        "--workers", "2",
    ])
    assert rc == 0

    pairs_dir = out / "pairs"
    hq = sorted(pairs_dir.glob("*_hq.png"))
    lq = sorted(pairs_dir.glob("*_lq.png"))
    meta = sorted(pairs_dir.glob("*_meta.json"))
    assert len(hq) == 20
    assert len(lq) == 20
    assert len(meta) == 20

    # Tiles are the expected 256x256 RGB.
    for p in hq + lq:
        with Image.open(p) as im:
            assert im.size == (256, 256), f"{p.name}: {im.size}"
            assert im.mode == "RGB"

    # Manifest is finalized and totals are consistent.
    with open(out / "manifest.json") as f:
        m = json.load(f)
    assert m["finalized"] is True
    assert m["num_pairs"] == 20
    assert sum(m["breakdown"].values()) == 20
    for kind, count in m["breakdown"].items():
        assert count >= 0, f"negative count for {kind}"

    # Every pair: HQ != LQ, and the recorded parameter is in-range.
    for hq_path in hq:
        idx = hq_path.name[:6]
        lq_path = pairs_dir / f"{idx}_lq.png"
        meta_path = pairs_dir / f"{idx}_meta.json"

        a = np.asarray(Image.open(hq_path).convert("RGB"), dtype=np.uint8)
        b = np.asarray(Image.open(lq_path).convert("RGB"), dtype=np.uint8)
        # PSNR finite => images differ. We don't pin a band here (per-kind
        # bands are already tested in test_degradations.py).
        p = deg.psnr(a, b)
        assert np.isfinite(p), f"{idx}: HQ and LQ are identical"

        info = json.loads(meta_path.read_text())
        kind = info["degradation"]
        param = info["param"]
        lo, hi = gen.PARAM_RANGES[kind]
        assert lo <= param <= hi, (
            f"{idx}: {kind} param={param} outside coding-plan range [{lo}, {hi}]"
        )
        assert info["tile_size"] == 256
        assert info["source_path"].endswith(".png")
        x, y = info["tile_xy"]
        # Tile must fit inside the source image.
        with Image.open(info["source_path"]) as im:
            sw, sh = im.size
        assert 0 <= x <= sw - 256
        assert 0 <= y <= sh - 256

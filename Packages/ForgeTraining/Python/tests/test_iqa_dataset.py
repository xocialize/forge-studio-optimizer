"""Tests for the NR-IQA dataset generator (#56)."""
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from Python.generate_iqa_dataset import Labeler, random_tile  # noqa: E402
from Python import degradations as deg  # noqa: E402


def _tile(size=384, seed=0):
    rng = np.random.default_rng(seed)
    # Structured content (gradient + texture) so a metric has something to grade.
    yy, xx = np.mgrid[0:size, 0:size]
    base = ((xx + yy) % 256).astype(np.uint8)
    tex = rng.integers(0, 40, (size, size), dtype=np.uint8)
    return np.stack([base, (base + tex) % 256, np.flipud(base)], axis=-1).astype(np.uint8)


def test_psnr_label_clean_is_one_and_monotonic():
    lab = Labeler("psnr")
    clean = _tile()
    _, q_clean = lab.quality(clean, clean)
    assert q_clean == 1.0
    # Heavier Gaussian noise → lower quality.
    qs = []
    for sigma in (5.0, 20.0, 50.0):
        d = deg.gaussian_noise(clean, sigma=sigma, rng=np.random.default_rng(1))
        _, q = lab.quality(clean, d)
        qs.append(q)
    assert qs[0] > qs[1] > qs[2]
    assert all(0.0 <= q <= 1.0 for q in qs)


def test_dists_label_clean_is_one_and_monotonic():
    lab = Labeler("dists")
    clean = _tile()
    _, q_clean = lab.quality(clean, clean)
    assert q_clean > 0.99
    d_light = deg.gaussian_noise(clean, sigma=5.0, rng=np.random.default_rng(1))
    d_heavy = deg.gaussian_noise(clean, sigma=50.0, rng=np.random.default_rng(1))
    _, q_light = lab.quality(clean, d_light)
    _, q_heavy = lab.quality(clean, d_heavy)
    assert q_clean > q_light > q_heavy


def test_random_tile_size():
    t = random_tile(_tile(512), 384, __import__("random").Random(0))
    assert t.shape == (384, 384, 3)


def test_end_to_end_manifest(tmp_path):
    src = tmp_path / "clean"; src.mkdir()
    Image.fromarray(_tile(400), "RGB").save(src / "a.png")
    Image.fromarray(_tile(400, seed=1), "RGB").save(src / "b.png")
    out = tmp_path / "ds"
    rc = subprocess.run([sys.executable,
                         str(Path(__file__).resolve().parents[1] / "generate_iqa_dataset.py"),
                         "--clean-source", str(src), "--out", str(out),
                         "--tile-size", "256", "--variants", "3", "--metric", "psnr"],
                        capture_output=True, text=True)
    assert rc.returncode == 0, rc.stderr
    rows = [json.loads(l) for l in (out / "manifest.jsonl").read_text().splitlines()]
    assert len(rows) >= 2 * (1 + 1)                       # 2 sources × (clean + ≥1 degraded)
    cleans = [r for r in rows if r["kind"] == "clean"]
    assert len(cleans) == 2 and all(r["quality"] == 1.0 for r in cleans)
    assert all((out / r["file"]).exists() for r in rows)
    assert all(0.0 <= r["quality"] <= 1.0 for r in rows)

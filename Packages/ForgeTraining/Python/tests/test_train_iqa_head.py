"""Tests for the IQA head trainer (#56) — fit/emit logic, no backbone needed."""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from Scripts.train_iqa_head import srcc_plcc, fit_head  # noqa: E402


def test_srcc_plcc_perfect_and_inverse():
    a = np.array([0.1, 0.2, 0.3, 0.4, 0.9])
    s, p = srcc_plcc(a, a.copy())
    assert s > 0.999 and p > 0.999
    s_inv, _ = srcc_plcc(a, a[::-1].copy())
    assert s_inv < -0.999


def test_fit_head_learns_and_emits_correct_shapes(tmp_path):
    # Synthetic: quality is a smooth function of the embedding → head should fit it.
    rng = np.random.default_rng(0)
    n, dim = 400, 768
    emb = rng.standard_normal((n, dim)).astype(np.float32)
    w = rng.standard_normal(dim).astype(np.float32)
    z = emb @ w / np.sqrt(dim)
    q = (1.0 / (1.0 + np.exp(-z))).astype(np.float32)          # in (0,1)

    fit_head(emb, q, tmp_path, epochs=400, val_frac=0.2, seed=1)

    from safetensors.numpy import load_file
    w_out = load_file(str(tmp_path / "siglip2_iqa_head.safetensors"))
    assert set(w_out) == {"fc1.weight", "fc1.bias", "fc2.weight", "fc2.bias"}
    assert w_out["fc1.weight"].shape == (256, 768)
    assert w_out["fc1.bias"].shape == (256,)
    assert w_out["fc2.weight"].shape == (1, 256)
    assert w_out["fc2.bias"].shape == (1,)

    m = json.loads((tmp_path / "metrics.json").read_text())
    # A learnable monotone relationship → strong rank correlation on val.
    assert m["srcc"] > 0.7
    assert 0.0 <= m["val_mse"] < 0.05
